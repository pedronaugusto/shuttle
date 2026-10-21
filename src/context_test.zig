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
fn make(c: *Context, entry: Context.Entry, arg: ?*anyopaque) !void {
    for (&made) |*m| if (m.context == null) {
        m.stack = try Stack.init(small);
        c.* = try Context.init(&m.stack, entry, arg);
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
        var arg_seen: ?*anyopaque = null;
        var first: ?*anyopaque = null;
        fn run(arg: ?*anyopaque, message: ?*anyopaque) callconv(.c) noreturn {
            arg_seen = arg;
            first = message;
            var n: usize = @intFromPtr(message); // safe: the test sends counts as messages
            while (true) {
                n = @intFromPtr(Context.switchTo(&task, &driver, @ptrFromInt(n * 2))); // safe: as above
            }
        }
    };
    var marker: u8 = 0;
    try make(&Probe.task, Probe.run, &marker);
    defer end(&Probe.task);
    var n: usize = 1;
    for (0..1000) |_| {
        const back = @intFromPtr(Context.switchTo(&Probe.driver, &Probe.task, @ptrFromInt(n))); // safe: counts as messages
        try std.testing.expectEqual(n * 2, back);
        n += 1;
    }
    try std.testing.expectEqual(@as(?*anyopaque, &marker), Probe.arg_seen);
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(Probe.first)); // safe: a count
}

test "a context enters its function with the stack a call leaves, so a local aligned to the stack's alignment is aligned" {
    if (!supported) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = .{};
        var task: Context = undefined;
        var address: usize = 1;
        fn run(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
            var local: u128 align(16) = 0;
            std.mem.doNotOptimizeAway(&local);
            address = @intFromPtr(&local); // safe: an address, kept as a number to test its alignment
            _ = Context.switchTo(&task, &driver, null);
            unreachable; // unreachable: the test ends the context without switching back
        }
    };
    try make(&Probe.task, Probe.run, null);
    defer end(&Probe.task);
    _ = Context.switchTo(&Probe.driver, &Probe.task, null);
    try std.testing.expectEqual(@as(usize, 0), Probe.address % 16);
}

test "contexts switch among themselves, not only with the thread's own" {
    if (!supported) return error.SkipZigTest;
    const Ring = struct {
        var driver: Context = .{};
        var tasks: [3]Context = undefined;
        var visits: [3]usize = @splat(0);
        fn run(arg: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
            const i = @intFromPtr(arg); // safe: the index the test passed
            while (true) {
                visits[i] += 1;
                const next = if (visits[i] == 100 and i == 2) &driver else &tasks[(i + 1) % 3];
                _ = Context.switchTo(&tasks[i], next, null);
            }
        }
    };
    for (&Ring.tasks, 0..) |*t, i| try make(t, Ring.run, @ptrFromInt(i)); // safe: an index as the argument
    defer for (&Ring.tasks) |*t| end(t);
    _ = Context.switchTo(&Ring.driver, &Ring.tasks[0], null);
    try std.testing.expectEqualSlices(usize, &.{ 100, 100, 100 }, &Ring.visits);
}

test "a context's trace ends at its first frame, inside its stack, whether it is running or suspended" {
    if (!supported or builtin.omit_frame_pointer) return error.SkipZigTest;
    const Probe = struct {
        var driver: Context = .{};
        var task: Context = undefined;
        var running: [64]usize = undefined;
        var running_len: usize = 0;
        fn run(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
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
            _ = Context.switchTo(&task, &driver, null);
        }
    };
    try make(&Probe.task, Probe.run, null);
    defer end(&Probe.task);
    _ = Context.switchTo(&Probe.driver, &Probe.task, null);
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
        fn run(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
            const trace = std.debug.captureCurrentStackTrace(.{}, &buffer);
            len = trace.return_addresses.len;
            _ = Context.switchTo(&task, &driver, null);
            unreachable; // unreachable: the test ends the context without switching back
        }
    };
    try make(&Probe.task, Probe.run, null);
    defer end(&Probe.task);
    _ = Context.switchTo(&Probe.driver, &Probe.task, null);
    try std.testing.expect(Probe.len < Probe.buffer.len);
}

test "a context suspended on one thread resumes on another, and back" {
    if (!supported or builtin.single_threaded) return error.SkipZigTest;
    const Probe = struct {
        var task: Context = undefined;
        /// The context of whichever thread last switched to the task.
        var resumer: *Context = undefined;
        var threads: [2]?std.Thread.Id = .{ null, null };
        fn run(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
            var round: usize = 0;
            while (true) : (round += 1) {
                // Read the thread through a call: a value the compiler kept
                // from before the switch would be the other thread's.
                threads[round % 2] = currentThread();
                _ = Context.switchTo(&task, resumer, null);
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
            _ = Context.switchTo(&own, &task, null);
        }
    };
    try make(&Probe.task, Probe.run, null);
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
        fn run(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
            bounds = teb.get();
            reached = deep(200);
            _ = Context.switchTo(&task, &driver, null);
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
    Probe.task = try Context.init(&stack, Probe.run, null);
    const outer = teb.get();
    _ = Context.switchTo(&Probe.driver, &Probe.task, null);
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
