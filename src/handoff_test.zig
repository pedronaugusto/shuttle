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

    fn body(arg: ?*anyopaque) noreturn {
        const job: *Job = @ptrCast(@alignCast(arg.?)); // safe: the test passes its job
        while (true) {
            job.steps += 1;
            const thread = currentThread();
            if (job.last_thread) |last| {
                if (last == thread) job.stayed += 1;
            }
            job.last_thread = thread;
            if (job.steps == steps) {
                handoff.switchTo(&job.context, &job.worker.context, .{ .run = finished });
                unreachable; // unreachable: a finished job is never resumed
            }
            handoff.switchTo(&job.context, &job.worker.context, .{ .run = park, .data = job.worker });
        }
    }

    noinline fn currentThread() std.Thread.Id {
        return std.Thread.getCurrentId();
    }

    /// On the worker the job left: the job goes to the next worker.
    fn park(data: ?*anyopaque, from: *Context) void {
        const w: *Worker = @ptrCast(@alignCast(data.?)); // safe: the job passes its worker
        all[(w.index + 1) % workers].push(@fieldParentPtr("context", from));
    }

    fn finished(_: ?*anyopaque, _: *Context) void {
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
        Jobs.stacks[i] = pool.take(.fromRaw(64 * 1024)).?;
        job.* = .{ .context = try Context.init(&Jobs.stacks[i], handoff.entry(Jobs.body), job) };
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
    for (&taken) |*s| s.* = pool.take(.fromRaw(16 * 1024)).?;
    // The small class is empty now: a small request takes a large stack.
    const big = pool.take(.fromRaw(16 * 1024)).?;
    try std.testing.expect(big.size().compare(.fromRaw(256 * 1024)) != .lt);
    try std.testing.expect(pool.take(.fromRaw(1024 * 1024)) == null);
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
    const again = pool.take(.fromRaw(16 * 1024)).?;
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
        s.* = pool.take(.fromRaw(16 * 1024)).?;
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), pool.inUse());
        const n = pool.number(s.*);
        try std.testing.expect(n < pool.count() and !seen[n]);
        seen[n] = true;
    }
    for (taken) |s| pool.give(s);
    try std.testing.expectEqual(@as(u32, 0), pool.inUse());
    // Only the small class, though the large one has stacks free.
    var small: [3]@import("Stack.zig") = undefined;
    for (&small) |*s| s.* = pool.takeExactly(.fromRaw(16 * 1024)).?;
    try std.testing.expect(pool.takeExactly(.fromRaw(16 * 1024)) == null);
    try std.testing.expect(pool.takeExactly(.fromRaw(1024 * 1024)) == null);
    for (small) |s| pool.give(s);
}

test "threads take and give a pool's stacks at once, each stack held by one at a time" {
    if (!supported or builtin.single_threaded) return error.SkipZigTest;
    const Churn = struct {
        fn run(pool: *Pool, owners: []std.atomic.Value(u32), me: u32) void {
            for (0..2000) |round| {
                const size: @import("Stack.zig").Bytes = .fromRaw(if (round % 3 == 0) 128 * 1024 else 16 * 1024);
                const s = (if (round % 2 == 0) pool.take(size) else pool.takeExactly(size)) orelse continue;
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
