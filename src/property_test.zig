//! Properties over random programs, each held to a model: a pool's stacks
//! against a count of what each class holds, and coroutines run, canceled
//! and replaced in any order against the sums they must yield. Run seeded
//! in every test run, and by the fuzzer under `bay properties --fuzz`.
const std = @import("std");
const shake = @import("shakedown");
const Pool = @import("Pool.zig");
const Stack = @import("Stack.zig");
const Coroutine = @import("coroutine.zig").Coroutine;
const supported = @import("arch.zig").supported;

const sizes = [_]usize{ 16 * 1024, 64 * 1024, 256 * 1024 };
const counts = [_]u32{ 5, 3, 2 };

fn poolProgram(_: void, c: *shake.Case) !void {
    var pool = try Pool.init(c.gpa, .{ .classes = &.{
        .{ .size = .fromRaw(sizes[2]), .count = counts[2] },
        .{ .size = .fromRaw(sizes[0]), .count = counts[0] },
        .{ .size = .fromRaw(sizes[1]), .count = counts[1] },
    } });
    defer pool.deinit(c.gpa);
    var held: [10]Stack = undefined;
    var len: usize = 0;
    var in_use: [3]u32 = @splat(0);
    defer for (held[0..len]) |s| pool.give(s);
    while (c.source.more(40)) {
        if (len > 0 and shake.gen.boolean(c.source)) {
            const i = shake.gen.intRange(c.source, usize, 0, len - 1);
            in_use[classOf(held[i])] -= 1;
            pool.give(held[i]);
            held[i] = held[len - 1];
            len -= 1;
            continue;
        }
        const want = shake.gen.intRange(c.source, usize, 1, 300 * 1024);
        // The model: the smallest class that fits and has a stack free.
        const expected: ?usize = for (sizes, 0..) |size, class| {
            if (size >= want and in_use[class] < counts[class]) break class;
        } else null;
        const got = try pool.take(.fromRaw(want));
        if (expected == null) {
            if (got != null) return error.TookFromAFullPool;
            continue;
        }
        const s = got orelse return error.RefusedAFreeStack;
        if (classOf(s) != expected.?) return error.WrongClass;
        if (s.size().compare(.fromRaw(want)) == .lt) return error.TooSmall;
        for (held[0..len]) |other| if (!(s.end <= other.base or other.end <= s.base)) return error.Overlap;
        // The stack is usable top to bottom once committed (on Windows the
        // system grows a stack only for its own thread), and its guard is below it.
        var reached = s;
        const low = lowestWritable(s);
        try reached.reach(low);
        const bytes: [*]volatile u8 = @ptrFromInt(low); // safe: the stack's own bytes, committed
        bytes[0] = 0xa5;
        bytes[reached.end - low - 1] = 0x5a;
        if (!s.guards(s.bottom - 1)) return error.NoGuard;
        in_use[expected.?] += 1;
        held[len] = reached;
        len += 1;
    }
}

/// The lowest byte a thread other than the stack's own can make usable: on
/// Windows the page below what is committed is the stack's guard page.
pub fn lowestWritable(s: Stack) usize {
    return if (@import("builtin").os.tag == .windows) s.bottom + std.heap.pageSize() else s.bottom;
}

fn classOf(s: Stack) usize {
    const size = s.size().raw();
    return for (sizes, 0..) |each, class| {
        if (size == each) break class;
    } else size; // a size no class has: the model's checks fail on it
}

test "a pool hands out the smallest class that fits and has a stack free, and nothing overlaps" {
    if (!supported) return error.SkipZigTest;
    try shake.check(std.testing.allocator, {}, poolProgram, .{ .cases = 200 });
}

const Summer = Coroutine(u32, u64, error{Canceled}!u64);

/// Yields the running sum of its inputs; given zero, returns it.
fn sum(y: *Summer.Yielder, first: u32, base: u64) error{Canceled}!u64 {
    var total: u64 = base + first;
    if (first == 0) return total;
    while (true) {
        const n = try y.yield(total);
        if (n == 0) return total;
        total += n;
    }
}

fn coroutineProgram(_: void, c: *shake.Case) !void {
    var pool = try Pool.init(c.gpa, .{ .classes = &.{.{ .size = .fromRaw(32 * 1024), .count = 4 }} });
    defer pool.deinit(c.gpa);
    const Slot = struct { co: *Summer, total: u64 };
    var slots: [4]?Slot = @splat(null);
    defer for (&slots) |*slot| if (slot.*) |s| pool.give(s.co.deinit());
    while (c.source.more(60)) {
        const i = shake.gen.intRange(c.source, usize, 0, slots.len - 1);
        const slot = &slots[i];
        if (slot.* == null) {
            const base = shake.gen.intRange(c.source, u64, 0, 1000);
            slot.* = .{ .co = try Summer.init((try pool.take(.fromRaw(8 * 1024))).?, sum, .{base}), .total = base };
            continue;
        }
        const s = &slot.*.?;
        switch (shake.gen.intRange(c.source, u8, 0, 9)) {
            // End it, finished or not: a suspended one is canceled.
            0 => {
                pool.give(s.co.deinit());
                slot.* = null;
            },
            // Give it zero: it returns its sum, and its stack goes back.
            1 => {
                const returned = switch (s.co.next(0)) {
                    .returned => |v| try v,
                    .yielded => return error.YieldedOnZero,
                };
                if (returned != s.total) return error.WrongReturn;
                pool.give(s.co.deinit());
                slot.* = null;
            },
            else => {
                const n = shake.gen.intRange(c.source, u32, 1, 1000);
                s.total += n;
                const yielded = switch (s.co.next(n)) {
                    .yielded => |v| v,
                    .returned => return error.ReturnedEarly,
                };
                if (yielded != s.total) return error.WrongYield;
            },
        }
    }
}

test "coroutines run, canceled and replaced in any order yield and return what their inputs add up to" {
    if (!supported) return error.SkipZigTest;
    try shake.check(std.testing.allocator, {}, coroutineProgram, .{ .cases = 200 });
}
