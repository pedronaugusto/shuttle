//! Coroutines and generators: values both ways, cancellation through the
//! body's defers, nesting, pooled stacks and moving between threads. Panics
//! are proven by `src/testing/faults.zig`, which installs the handler.
const builtin = @import("builtin");
const std = @import("std");
const Stack = @import("Stack.zig");
const Pool = @import("Pool.zig");
const Coroutine = @import("coroutine.zig").Coroutine;
const State = @import("coroutine.zig").State;
const Generator = @import("generator.zig").Generator;
const supported = @import("arch.zig").supported;

fn stack() !Stack {
    return Stack.init(.{ .size = .fromRaw(64 * 1024) });
}

const Summer = Coroutine(u32, u64, error{Canceled}!u64);

/// Yields the running sum of its inputs until it is given zero, then
/// returns the sum times `scale`.
fn sum(y: *Summer.Yielder, first: u32, scale: u64) error{Canceled}!u64 {
    var total: u64 = first;
    while (true) {
        const n = try y.yield(total);
        if (n == 0) return total * scale;
        total += n;
    }
}

test "a coroutine takes its first input as a parameter and each later one from yield, and hands back what it yields and returns" {
    if (!supported) return error.SkipZigTest;
    const co = try Summer.init(try stack(), sum, .{@as(u64, 10)});
    try std.testing.expectEqual(State.fresh, co.state());
    try std.testing.expectEqual(@as(u64, 5), co.next(5).yielded);
    try std.testing.expectEqual(State.suspended, co.state());
    try std.testing.expectEqual(@as(u64, 12), co.next(7).yielded);
    try std.testing.expectEqual(@as(u64, 120), try co.next(0).returned);
    try std.testing.expect(co.done());
    var s = co.deinit();
    s.deinit();
}

test "a generator yields until its body returns, then stays done" {
    if (!supported) return error.SkipZigTest;
    const Fib = Generator(u64, error{});
    const body = struct {
        fn run(y: *Fib.Yielder, count: usize) error{Canceled}!void {
            var a: u64 = 0;
            var b: u64 = 1;
            for (0..count) |_| {
                try y.yield(a);
                const c = a + b;
                a = b;
                b = c;
            }
        }
    }.run;
    var g = try Fib.init(try stack(), body, .{@as(usize, 10)});
    var got: [10]u64 = undefined;
    var n: usize = 0;
    while (try g.next()) |v| : (n += 1) got[n] = v;
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 1, 2, 3, 5, 8, 13, 21, 34 }, &got);
    try std.testing.expectEqual(@as(?u64, null), try g.next());
    var s = g.deinit();
    s.deinit();
}

test "a generator's error comes out of next" {
    if (!supported) return error.SkipZigTest;
    const G = Generator(u8, error{Bad});
    const body = struct {
        fn run(y: *G.Yielder) error{ Bad, Canceled }!void {
            try y.yield(1);
            return error.Bad;
        }
    }.run;
    var g = try G.init(try stack(), body, .{});
    try std.testing.expectEqual(@as(?u8, 1), try g.next());
    try std.testing.expectError(error.Bad, g.next());
    try std.testing.expectEqual(@as(?u8, null), try g.next());
    var s = g.deinit();
    s.deinit();
}

test "ending a suspended coroutine cancels it: its yield fails, its defers run, and it yields no more" {
    if (!supported) return error.SkipZigTest;
    const G = Generator(u32, error{});
    const Probe = struct {
        var cleaned = false;
        var second_yield: ?anyerror = null;
        fn run(y: *G.Yielder) error{Canceled}!void {
            defer cleaned = true;
            var i: u32 = 0;
            while (true) : (i += 1) {
                y.yield(i) catch |e| {
                    // A body that keeps going after a cancel is refused at once.
                    second_yield = if (y.yield(99)) |_| null else |again| again;
                    return e;
                };
            }
        }
    };
    var g = try G.init(try stack(), Probe.run, .{});
    try std.testing.expectEqual(@as(?u32, 0), try g.next());
    try std.testing.expectEqual(@as(?u32, 1), try g.next());
    try std.testing.expect(!Probe.cleaned);
    var s = g.deinit();
    s.deinit();
    try std.testing.expect(Probe.cleaned);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Probe.second_yield);
}

test "ending a coroutine that never ran runs nothing" {
    if (!supported) return error.SkipZigTest;
    const G = Generator(u32, error{});
    const Probe = struct {
        var ran = false;
        fn run(_: *G.Yielder) error{Canceled}!void {
            ran = true;
        }
    };
    var g = try G.init(try stack(), Probe.run, .{});
    var s = g.deinit();
    s.deinit();
    try std.testing.expect(!Probe.ran);
}

test "a coroutine runs coroutines of its own" {
    if (!supported) return error.SkipZigTest;
    const Inner = Generator(u32, error{});
    const Outer = Generator(u32, error{});
    const body = struct {
        fn inner(y: *Inner.Yielder, base: u32) error{Canceled}!void {
            for (0..3) |i| try y.yield(base + @as(u32, @intCast(i)));
        }
        fn outer(y: *Outer.Yielder) error{Canceled}!void {
            for (0..2) |round| {
                var g = Inner.init(stack() catch @panic("no stack"), inner, .{@as(u32, @intCast(round)) * 10}) catch @panic("no stack");
                defer {
                    var s = g.deinit();
                    s.deinit();
                }
                while (g.next() catch unreachable) |v| try y.yield(v); // unreachable: the inner body fails only when canceled
            }
        }
    };
    var g = try Outer.init(try stack(), body.outer, .{});
    var got: [6]u32 = undefined;
    var n: usize = 0;
    while (try g.next()) |v| : (n += 1) got[n] = v;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 10, 11, 12 }, got[0..n]);
    var s = g.deinit();
    s.deinit();
}

test "coroutines on a pool's stacks give them back for the next ones" {
    if (!supported) return error.SkipZigTest;
    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{.{ .size = .fromRaw(32 * 1024), .count = 4 }} });
    defer pool.deinit(std.testing.allocator);
    var total: u64 = 0;
    for (0..100) |round| {
        const co = try Summer.init(pool.take(.fromRaw(16 * 1024)).?, sum, .{@as(u64, 1)});
        _ = co.next(@intCast(round));
        const r = co.next(0);
        total += try r.returned;
        pool.give(co.deinit());
    }
    try std.testing.expectEqual(@as(u64, 99 * 100 / 2), total);
}

test "a coroutine suspended on one thread is run on with the next, its values intact" {
    if (!supported or builtin.single_threaded) return error.SkipZigTest;
    const co = try Summer.init(try stack(), sum, .{@as(u64, 2)});
    const Drive = struct {
        fn step(c: *Summer, n: u32, out: *u64) void {
            out.* = c.next(n).yielded;
        }
    };
    var seen: [4]u64 = undefined;
    for (&seen, 1..) |*out, n| {
        const t = try std.Thread.spawn(.{}, Drive.step, .{ co, @as(u32, @intCast(n)), out });
        t.join();
    }
    try std.testing.expectEqualSlices(u64, &.{ 1, 3, 6, 10 }, &seen);
    try std.testing.expectEqual(@as(u64, 20), try co.next(0).returned);
    var s = co.deinit();
    s.deinit();
}
