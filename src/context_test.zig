//! Contexts: entry and messages, the first frame's alignment, traces that
//! end at a context's first frame, moving between threads, and on Windows a
//! stack that grows through its guard page.
const builtin = @import("builtin");
const std = @import("std");
const Context = @import("Context.zig");
const Stack = @import("Stack.zig");
const supported = @import("arch.zig").supported;
const teb = @import("teb.zig");
const walking = @import("trace.zig");

const small: Stack.Options = .{ .size = .fromRaw(64 * 1024) };

/// The stacks of the contexts `make` made, each beside its context.
var made: [4]struct { context: ?*const Context = null, stack: Stack = undefined } = @splat(.{});

/// A context at `c` on a small stack of its own, which `end` releases.
fn make(c: *Context, comptime Arg: type, comptime Message: type, entry: Context.Entry(Arg, Message), arg: Arg) !void {
    for (&made) |*m| if (m.context == null) {
        m.stack = try Stack.init(small);
        c.* = try Context.init(&m.stack, Arg, Message, entry, arg);
        m.context = c;
        return;
    };
    unreachable; // unreachable: no test makes more contexts at once than the table holds
}

fn stackOf(c: *const Context) *Stack {
    for (&made) |*m| if (m.context == c) return &m.stack;
    unreachable; // unreachable: only contexts `make` made are asked about
}

fn end(c: *Context) void {
    const s = stackOf(c);
    c.deinit(s);
    s.deinit();
    for (&made) |*m| if (m.context == c) {
        m.context = null;
    };
}

test "a context is what a switch saves: its registers, what its code runs inside, and on Windows its stack bounds, and under ThreadSanitizer its fiber" {
    const native = @import("arch.zig").native;
    var size: usize = @sizeOf(native.Registers) + @sizeOf(?*anyopaque);
    if (builtin.os.tag == .windows) size += @sizeOf(teb.Bounds);
    if (builtin.sanitize_thread) size += @sizeOf(usize);
    try std.testing.expectEqual(std.mem.alignForward(usize, size, @alignOf(Context)), @sizeOf(Context));
}

test "a context starts at its entry with its argument and the first message, and messages go both ways" {
    if (!supported) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = .{};
        var task: Context = undefined;
        var arg_seen: ?*u8 = null;
        var first: usize = 0;
        fn run(arg: *u8, message: ?*usize) callconv(.c) noreturn {
            arg_seen = arg;
            var n = message.?;
            first = n.*;
            while (true) {
                n.* *= 2;
                n = Context.switchTo(&task, &driver, *usize, n).?;
            }
        }
    };
    var marker: u8 = 0;
    try make(&Probe.task, *u8, *usize, Probe.run, &marker);
    defer end(&Probe.task);
    for (1..1001) |i| {
        var n: usize = i;
        const back = Context.switchTo(&Probe.driver, &Probe.task, *usize, &n).?;
        try std.testing.expectEqual(&n, back);
        try std.testing.expectEqual(i * 2, n);
    }
    try std.testing.expectEqual(@as(?*u8, &marker), Probe.arg_seen);
    try std.testing.expectEqual(@as(usize, 1), Probe.first);
}

test "a context enters its function with the stack a call leaves, so a local aligned to the stack's alignment is aligned" {
    if (!supported) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = .{};
        var task: Context = undefined;
        var address: usize = 1;
        fn run(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
            var local: u128 align(16) = 0;
            std.mem.doNotOptimizeAway(&local);
            address = @intFromPtr(&local); // safe: an address, kept as a number to test its alignment
            _ = Context.switchTo(&task, &driver, Context.Nothing, null);
            unreachable; // unreachable: the test ends the context without switching back
        }
    };
    try make(&Probe.task, ?Context.Nothing, Context.Nothing, Probe.run, null);
    defer end(&Probe.task);
    _ = Context.switchTo(&Probe.driver, &Probe.task, Context.Nothing, null);
    try std.testing.expectEqual(@as(usize, 0), Probe.address % 16);
}

test "contexts switch among themselves, not only with the thread's own" {
    if (!supported) return error.SkipZigTest;
    const Ring = struct {
        var driver: Context = .{};
        var tasks: [3]Context = undefined;
        var visits: [3]usize = @splat(0);
        const indices: [3]usize = .{ 0, 1, 2 };
        fn run(index: *const usize, _: ?Context.Nothing) callconv(.c) noreturn {
            const i = index.*;
            while (true) {
                visits[i] += 1;
                const next = if (visits[i] == 100 and i == 2) &driver else &tasks[(i + 1) % 3];
                _ = Context.switchTo(&tasks[i], next, Context.Nothing, null);
            }
        }
    };
    for (&Ring.tasks, &Ring.indices) |*t, *i| try make(t, *const usize, Context.Nothing, Ring.run, i);
    defer for (&Ring.tasks) |*t| end(t);
    _ = Context.switchTo(&Ring.driver, &Ring.tasks[0], Context.Nothing, null);
    try std.testing.expectEqualSlices(usize, &.{ 100, 100, 100 }, &Ring.visits);
}

test "a context's trace ends at its first frame, inside its stack, whether it is running or suspended" {
    if (!supported or builtin.omit_frame_pointer) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = .{};
        var task: Context = undefined;
        var running: [64]usize = undefined;
        var running_len: usize = 0;
        fn run(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
            deeper(3);
            unreachable; // unreachable: the test ends the context without switching back
        }
        noinline fn deeper(n: usize) void {
            if (n > 0) {
                deeper(n - 1);
                std.mem.doNotOptimizeAway(n);
                return;
            }
            running_len = task.trace(stackOf(&task), &running).len;
            _ = Context.switchTo(&task, &driver, Context.Nothing, null);
        }
    };
    try make(&Probe.task, ?Context.Nothing, Context.Nothing, Probe.run, null);
    defer end(&Probe.task);
    _ = Context.switchTo(&Probe.driver, &Probe.task, Context.Nothing, null);
    // deeper four times and run, and the walk stopped short of its room.
    // Below run, the trampoline's frame where it calls the entry; on Windows
    // it branches in with no return address, which ends the walk at run.
    try std.testing.expect(Probe.running_len >= 5 and Probe.running_len < Probe.running.len);
    if (!walking.suspended_available) return;
    var suspended: [64]usize = undefined;
    const len = Probe.task.trace(stackOf(&Probe.task), &suspended).len;
    // From the switch: the same frames, the one that called trace aside.
    try std.testing.expectEqualSlices(usize, Probe.running[1..Probe.running_len], suspended[0..len]);
    // From a call site the caller kept (the one in `run`, which only one
    // frame returns to, after the call that called trace and the three
    // calls deeper): the frames from there on.
    var from: [64]usize = undefined;
    const first = Probe.running[4];
    try std.testing.expectEqualSlices(usize, Probe.running[4..Probe.running_len], Probe.task.traceFrom(stackOf(&Probe.task), first, &from));
}

test "std's own stack walk on a context's stack ends at the context's first frame" {
    if (!supported) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = .{};
        var task: Context = undefined;
        var len: usize = 0;
        var buffer: [64]usize = undefined;
        fn run(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
            const trace = std.debug.captureCurrentStackTrace(.{}, &buffer);
            len = trace.return_addresses.len;
            _ = Context.switchTo(&task, &driver, Context.Nothing, null);
            unreachable; // unreachable: the test ends the context without switching back
        }
    };
    try make(&Probe.task, ?Context.Nothing, Context.Nothing, Probe.run, null);
    defer end(&Probe.task);
    _ = Context.switchTo(&Probe.driver, &Probe.task, Context.Nothing, null);
    try std.testing.expect(Probe.len < Probe.buffer.len);
}

test "a context suspended on one thread resumes on another, and back" {
    if (!supported or builtin.single_threaded) return error.SkipZigTest;
    const Probe = struct {
        var task: Context = undefined;
        /// The context of whichever thread last switched to the task.
        var resumer: *Context = undefined;
        var threads: [2]?std.Thread.Id = .{ null, null };
        fn run(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
            var round: usize = 0;
            while (true) : (round += 1) {
                // Read the thread through a call: a value the compiler kept
                // from before the switch would be the other thread's.
                threads[round % 2] = currentThread();
                _ = Context.switchTo(&task, resumer, Context.Nothing, null);
            }
        }
        noinline fn currentThread() std.Thread.Id {
            return std.Thread.getCurrentId();
        }
        fn drive() void {
            var own: Context = .{};
            resumer = &own;
            // `own` ends with this frame: the task has switched back
            // through it by then, and the next thread names its own.
            defer resumer = undefined;
            _ = Context.switchTo(&own, &task, Context.Nothing, null);
        }
    };
    try make(&Probe.task, ?Context.Nothing, Context.Nothing, Probe.run, null);
    defer end(&Probe.task);
    for (0..4) |_| {
        const t = try std.Thread.spawn(.{}, Probe.drive, .{});
        t.join();
    }
    try std.testing.expect(Probe.threads[0] != null and Probe.threads[1] != null);
    try std.testing.expect(Probe.threads[0].? != Probe.threads[1].?);
}

test "Windows: a context's stack bounds are its own while it runs, and it grows through its guard page" {
    if (!supported or builtin.os.tag != .windows) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = .{};
        var task: Context = undefined;
        var bounds: teb.Bounds = undefined;
        var reached: usize = 0;
        fn run(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
            bounds = teb.get();
            reached = deep(200);
            _ = Context.switchTo(&task, &driver, Context.Nothing, null);
            unreachable; // unreachable: the test ends the context without switching back
        }
        /// About a page a frame, touched from the top down as the system
        /// commits it.
        noinline fn deep(n: usize) usize {
            var page: [4000]u8 = undefined;
            @memset(@as(*volatile [4000]u8, &page), @truncate(n));
            if (n == 0) return @intFromPtr(&page); // safe: an address, compared with the bounds
            const r = deep(n - 1);
            std.mem.doNotOptimizeAway(&page);
            return r;
        }
    };
    var stack = try Stack.init(.{ .size = .fromRaw(1024 * 1024) });
    const committed = stack.limit;
    Probe.task = try Context.init(&stack, ?Context.Nothing, Context.Nothing, Probe.run, null);
    const outer = teb.get();
    _ = Context.switchTo(&Probe.driver, &Probe.task, Context.Nothing, null);
    // Back on the thread's own stack, with its own bounds.
    try std.testing.expectEqual(outer, teb.get());
    try std.testing.expectEqual(stack.end, Probe.bounds.base);
    try std.testing.expectEqual(stack.base, Probe.bounds.deallocation);
    // 800 KiB deep, where two pages were committed: grown, and the
    // context's committed limit followed it down.
    try std.testing.expect(Probe.reached < committed - 512 * 1024);
    Probe.task.deinit(&stack);
    try std.testing.expect(stack.limit <= Probe.reached);
    stack.deinit();
}

test "Windows: a switch from any depth to a stack below its own leaves it under the bounds the system grows it by" {
    if (!supported or builtin.os.tag != .windows) return error.SkipZigTest;
    // Every place a switch can stand in a page, on a fresh stack: one of
    // them has the switch's first touch of a new page land in the guard
    // page, which the system grows only inside the thread's bounds. Those
    // describe the stack switched to, if anything does, once the switch
    // has begun: a stack below the one switched from is the case where no
    // bounds of either contain the touch.
    inline for (0..256) |i| try switchAtDepth(i * 16);
}

/// A switch away from a context `pad` bytes below its first frame, to a
/// context on a stack below its own, then both ended: the thread is back
/// under its own bounds.
fn switchAtDepth(comptime pad: usize) !void {
    const Probe = struct {
        var driver: Context = .{};
        var low: Context = undefined;
        var high: Context = undefined;
        fn lower(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
            _ = Context.switchTo(&low, &high, Context.Nothing, null);
            _ = Context.switchTo(&low, &driver, Context.Nothing, null);
            unreachable; // unreachable: the test ends the context without switching back
        }
        fn higher(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
            descend();
            unreachable; // unreachable: as above
        }
        /// Past the pages a stack starts with committed, through its
        /// guard page as the system grows it.
        noinline fn descend() void {
            var pages: [3 * 4096]u8 = undefined;
            @memset(@as(*volatile [3 * 4096]u8, &pages), 0);
            below();
            std.mem.doNotOptimizeAway(&pages);
        }
        /// A frame of less than a page, touched as it is laid out, so the
        /// switch starts at a committed edge `pad` bytes further down.
        noinline fn below() void {
            var room: [pad + 16]u8 = undefined;
            @memset(@as(*volatile [pad + 16]u8, &room), 0);
            _ = Context.switchTo(&high, &low, Context.Nothing, null);
            std.mem.doNotOptimizeAway(&room);
        }
    };
    var one = try Stack.init(small);
    defer one.deinit();
    var other = try Stack.init(small);
    defer other.deinit();
    const low_stack, const high_stack = if (one.base < other.base) .{ &one, &other } else .{ &other, &one };
    Probe.low = try Context.init(low_stack, ?Context.Nothing, Context.Nothing, Probe.lower, null);
    defer Probe.low.deinit(low_stack);
    Probe.high = try Context.init(high_stack, ?Context.Nothing, Context.Nothing, Probe.higher, null);
    defer Probe.high.deinit(high_stack);
    const outer = teb.get();
    _ = Context.switchTo(&Probe.driver, &Probe.low, Context.Nothing, null);
    try std.testing.expectEqual(outer, teb.get());
}
