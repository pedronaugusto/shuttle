//! A job system's core on a pool and the handoff: worker threads resume
//! contexts from their queues, and a context parks itself on the next
//! worker's queue through the switch away from it, so that worker, on
//! another thread, takes it at once.
const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Context = @import("Context.zig");
const Stack = @import("Stack.zig");
const Pool = @import("Pool.zig");
const handoff = @import("handoff.zig");
const supported = @import("arch.zig").supported;

const Jobs = struct {
    const workers = 4;
    const count = 16;
    const steps = 500;

    const Job = struct {
        context: Context,
        /// What the worker it leaves does with it: park it on the next worker,
        /// or count it done.
        parking: handoff.After = .{ .run = park },
        ending: handoff.After = .{ .run = finished },
        steps: usize = 0,
        /// The worker that resumed the job last, written by it before the switch.
        worker: *Worker = undefined,
        /// Each step's thread must differ from the step before it's.
        last_thread: ?std.Thread.Id = null,
        stayed: usize = 0,
    };

    const Queue = struct {
        items: [count]*Job = undefined,
        head: usize = 0,
        len: usize = 0,
    };

    const Worker = struct {
        context: Context = .{},
        queue: aegis.Guarded(Queue) = .init(.{}),
        index: usize,

        fn push(w: *Worker, job: *Job) void {
            var held = w.queue.acquire();
            defer held.deinit();
            const q = held.value();
            q.items[(q.head + q.len) % count] = job;
            q.len += 1;
        }

        fn pop(w: *Worker) ?*Job {
            var held = w.queue.acquire();
            defer held.deinit();
            const q = held.value();
            if (q.len == 0) return null;
            const job = q.items[q.head];
            q.head = (q.head + 1) % count;
            q.len -= 1;
            return job;
        }

        fn run(w: *Worker) void {
            while (done.load(.acquire) < count) {
                const job = w.pop() orelse {
                    // glint-ignore: Z026 -- a yield that fails only spins once more
                    std.Thread.yield() catch {};
                    continue;
                };
                job.worker = w;
                handoff.switchTo(&w.context, &job.context, null);
            }
        }
    };

    var all: [workers]Worker = undefined;
    var done: std.atomic.Value(usize) = .init(0);
    var jobs: [count]Job = undefined;
    var stacks: [count]Stack = undefined;

    fn body(job: *Job) noreturn {
        while (true) {
            job.steps += 1;
            const thread = currentThread();
            if (job.last_thread) |last| {
                if (last == thread) job.stayed += 1;
            }
            job.last_thread = thread;
            if (job.steps == steps) {
                handoff.switchTo(&job.context, &job.worker.context, &job.ending);
                unreachable; // unreachable: a finished job is never resumed
            }
            handoff.switchTo(&job.context, &job.worker.context, &job.parking);
        }
    }

    noinline fn currentThread() std.Thread.Id {
        return std.Thread.getCurrentId();
    }

    /// On the worker the job left: the job goes to the next worker.
    fn park(after: *handoff.After, _: *Context) void {
        const job: *Job = @alignCast(@fieldParentPtr("parking", after)); // safe: the field belongs to this record
        all[(job.worker.index + 1) % workers].push(job);
    }

    fn finished(_: *handoff.After, _: *Context) void {
        _ = done.fetchAdd(1, .release);
    }
};

test "worker threads run contexts that park themselves on another worker's queue by the switch away from them" {
    if (!supported or builtin.single_threaded) return error.SkipZigTest;
    Jobs.done = .init(0);
    for (&Jobs.all, 0..) |*w, i| w.* = .{ .index = i };
    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{.{ .size = .fromRaw(64 * 1024), .count = Jobs.count }} });
    defer pool.deinit(std.testing.allocator);
    for (&Jobs.jobs, 0..) |*job, i| {
        Jobs.stacks[i] = (try pool.take(.fromRaw(64 * 1024))).?;
        job.* = .{ .context = try handoff.init(&Jobs.stacks[i], *Jobs.Job, Jobs.body, job) };
        Jobs.all[i % Jobs.workers].push(job);
    }
    defer for (&Jobs.jobs, &Jobs.stacks) |*job, *stack| {
        job.context.deinit(stack);
        pool.give(stack.*);
    };
    var threads: [Jobs.workers]std.Thread = undefined;
    for (&threads, &Jobs.all) |*t, *w| t.* = try std.Thread.spawn(.{}, Jobs.Worker.run, .{w});
    for (threads) |t| t.join();
    for (Jobs.jobs) |job| {
        try std.testing.expectEqual(@as(usize, Jobs.steps), job.steps);
        // Every step on the worker after the last one's: another thread each time.
        try std.testing.expectEqual(@as(usize, 0), job.stayed);
    }
}

test "a pool hands out the smallest class that fits, keeps guards between its stacks, and takes stacks back" {
    if (!supported) return error.SkipZigTest;
    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{
        .{ .size = .fromRaw(256 * 1024), .count = 2 },
        .{ .size = .fromRaw(32 * 1024), .count = 70 },
    } });
    defer pool.deinit(std.testing.allocator);
    var taken: [70]@import("Stack.zig") = undefined;
    for (&taken) |*s| s.* = (try pool.take(.fromRaw(16 * 1024))).?;
    // The small class is empty now: a small request takes a large stack.
    const big = (try pool.take(.fromRaw(16 * 1024))).?;
    try std.testing.expect(big.size().compare(.fromRaw(256 * 1024)) != .lt);
    try std.testing.expect(try pool.take(.fromRaw(1024 * 1024)) == null);
    for (taken) |s| {
        try std.testing.expect(s.size().compare(.fromRaw(32 * 1024)) != .lt and s.size().compare(.fromRaw(256 * 1024)) == .lt);
        try std.testing.expect(s.top % 16 == 0 and s.guards(s.bottom - 1) and !s.guards(s.bottom));
        // Usable to the last byte, once committed where the system grows stacks only for their own thread.
        var reached = s;
        const low = @import("property_test.zig").lowestWritable(s);
        try reached.reach(low);
        const bytes: [*]volatile u8 = @ptrFromInt(low); // safe: the stack's own bytes, committed
        bytes[0] = 1;
        bytes[reached.end - low - 1] = 1;
    }
    // No two stacks overlap.
    for (taken, 0..) |a, i| for (taken[i + 1 ..]) |b| try std.testing.expect(a.end <= b.base or b.end <= a.base);
    pool.give(big);
    for (taken) |s| pool.give(s);
    // The last given back is the first handed out again.
    const again = (try pool.take(.fromRaw(16 * 1024))).?;
    try std.testing.expectEqual(taken[taken.len - 1].bottom, again.bottom);
    pool.give(again);
}

test "a pool numbers its stacks once across its classes, counts those in use, and can keep to one class" {
    if (!supported) return error.SkipZigTest;
    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{
        .{ .size = .fromRaw(256 * 1024), .count = 2 },
        .{ .size = .fromRaw(32 * 1024), .count = 3 },
    } });
    defer pool.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 5), pool.count());
    var taken: [5]@import("Stack.zig") = undefined;
    var seen: [5]bool = @splat(false);
    for (&taken, 0..) |*s, i| {
        s.* = (try pool.take(.fromRaw(16 * 1024))).?;
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), pool.inUse());
        const n = pool.number(s.*);
        try std.testing.expect(n < pool.count() and !seen[n]);
        seen[n] = true;
    }
    for (taken) |s| pool.give(s);
    try std.testing.expectEqual(@as(u32, 0), pool.inUse());
    // Only the small class, though the large one has stacks free.
    var small: [3]@import("Stack.zig") = undefined;
    for (&small) |*s| s.* = (try pool.takeExactly(.fromRaw(16 * 1024))).?;
    try std.testing.expect(try pool.takeExactly(.fromRaw(16 * 1024)) == null);
    try std.testing.expect(try pool.takeExactly(.fromRaw(1024 * 1024)) == null);
    for (small) |s| pool.give(s);
}

test "threads take and give a pool's stacks at once, each stack held by one at a time" {
    if (!supported or builtin.single_threaded) return error.SkipZigTest;
    const Churn = struct {
        fn run(pool: *Pool, owners: []std.atomic.Value(u32), me: u32) void {
            for (0..2000) |round| {
                const size: @import("Stack.zig").Bytes = .fromRaw(if (round % 3 == 0) 128 * 1024 else 16 * 1024);
                const s = (if (round % 2 == 0) pool.take(size) else pool.takeExactly(size)) catch @panic("a stack refused") orelse continue;
                const n = pool.number(s);
                // Nobody else holds it.
                if (owners[n].swap(me, .acq_rel) != 0) @panic("a stack handed out twice");
                owners[n].store(0, .release);
                pool.give(s);
            }
        }
    };
    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{
        .{ .size = .fromRaw(32 * 1024), .count = 6 },
        .{ .size = .fromRaw(256 * 1024), .count = 3 },
    } });
    defer pool.deinit(std.testing.allocator);
    var owners: [9]std.atomic.Value(u32) = @splat(.init(0));
    var threads: [4]std.Thread = undefined;
    for (&threads, 1..) |*t, me| t.* = try std.Thread.spawn(.{}, Churn.run, .{ &pool, &owners, @as(u32, @intCast(me)) });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), pool.inUse());
}

test "a pool makes a stack usable only when it is first handed out, and keeps it so" {
    if (!supported) return error.SkipZigTest;
    // Thousands of stacks cost one reservation at init.
    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{.{ .size = .fromRaw(256 * 1024), .count = 16384 }} });
    defer pool.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), pool.reached());
    const first = (try pool.take(.fromRaw(16 * 1024))).?;
    try std.testing.expectEqual(@as(u32, 1), pool.reached());
    var reached = first;
    const low = @import("property_test.zig").lowestWritable(first);
    try reached.reach(low);
    const bytes: [*]volatile u8 = @ptrFromInt(low); // safe: the stack's own bytes, committed
    bytes[0] = 7;
    bytes[reached.end - low - 1] = 7;
    pool.give(reached);
    // Given back, it is the one handed out again, as it was: none new is made.
    const again = (try pool.take(.fromRaw(16 * 1024))).?;
    try std.testing.expectEqual(first.bottom, again.bottom);
    try std.testing.expectEqual(@as(u32, 1), pool.reached());
    try std.testing.expect(again.guards(again.bottom - 1));
    // Two at once: a second is made, beside the first.
    const second = (try pool.take(.fromRaw(16 * 1024))).?;
    try std.testing.expectEqual(@as(u32, 2), pool.reached());
    try std.testing.expect(second.end <= again.base or again.end <= second.base);
    pool.give(second);
    pool.give(again);
}

test "a stack the system refuses to make usable is an error at its take, and is tried again later" {
    if (!supported) return error.SkipZigTest;
    // The refusal is made real by taking the stack's address space away
    // from the reservation, which a commit then fails on. Windows releases
    // a reservation only whole.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{.{ .size = .fromRaw(64 * 1024), .count = 2 }} });
    defer pool.deinit(std.testing.allocator);
    const held = (try pool.take(.fromRaw(16 * 1024))).?;
    // The next stack never handed out is the second.
    const next = pool.stackOf(1);
    const range = @import("memory.zig").pages(next.base, next.end);
    std.posix.munmap(range);
    try std.testing.expectError(error.SystemResources, pool.take(.fromRaw(16 * 1024)));
    try std.testing.expectError(error.SystemResources, pool.takeExactly(.fromRaw(16 * 1024)));
    try std.testing.expectEqual(@as(u32, 1), pool.inUse());
    // The address space back, as the reservation had it: the stack is made.
    _ = try std.posix.mmap(range.ptr, range.len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
    const made = (try pool.take(.fromRaw(16 * 1024))).?;
    try std.testing.expectEqual(next.bottom, made.bottom);
    try std.testing.expect(made.guards(made.bottom - 1));
    const usable = made.usable();
    @as(*volatile u8, &usable[usable.len - 1]).* = 7;
    try std.testing.expect(try pool.take(.fromRaw(16 * 1024)) == null);
    pool.give(made);
    pool.give(held);
}

test "a stack gives bytes of a size and an alignment known only at run time from its top, each below the last" {
    var stack = try Stack.init(.{ .size = .fromRaw(64 * 1024) });
    defer stack.deinit();
    const sizes = [_]usize{ 24, 1, 200, 4096 };
    const alignments = [_]std.mem.Alignment{ .@"8", .@"1", .@"64", .fromByteUnits(4096) };
    var above = stack.top;
    for (sizes, alignments) |len, alignment| {
        const bytes = try stack.carveBytes(len, alignment);
        const at = @intFromPtr(bytes);
        try std.testing.expect(alignment.check(at) and at % 16 == 0);
        try std.testing.expect(at + len <= above and at == stack.top);
        @memset(bytes[0..len], 0xa5);
        above = at;
    }
    const typed = try stack.carve(extern struct { a: u64, b: u32 });
    try std.testing.expect(@intFromPtr(typed) + @sizeOf(@TypeOf(typed.*)) <= above);
    try std.testing.expectError(error.StackTooSmall, stack.carveBytes(64 * 1024, .@"16"));
}

test "a stack's usable bytes run from its bottom to its end, what was carved included, and are its own" {
    var stack = try Stack.init(.{ .size = .fromRaw(64 * 1024) });
    defer stack.deinit();
    const carved = try stack.carve(u64);
    const usable = stack.usable();
    try std.testing.expectEqual(stack.size().raw(), usable.len);
    try std.testing.expectEqual(stack.bottom, @intFromPtr(usable.ptr));
    // The carved value is in them, at its offset from the bottom.
    carved.* = 0x1122_3344_5566_7788;
    const at = @intFromPtr(carved) - stack.bottom;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(carved), usable[at..][0..8]);
    // Filling the committed top fills the stack's own memory.
    try stack.reach(stack.top - 4096);
    @memset(usable[stack.top - 4096 - stack.bottom .. stack.top - stack.bottom], 0x5a);
    try std.testing.expect(std.mem.allEqual(u8, usable[stack.top - 4096 - stack.bottom .. stack.top - stack.bottom], 0x5a));
}
