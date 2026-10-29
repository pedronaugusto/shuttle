//! The faults a test runner cannot host, in a program with shuttle's panic
//! and segfault handlers in its root: a coroutine's panic handed to the
//! code that ran it, and a stack overflow named and stopped by the guard.
//!
//! Run with no argument, it checks the panics it can survive in process,
//! then spawns itself once per fatal case and passes only when each child
//! died as it had to, having said what it had to. Run with a case name, it
//! is that child.
const builtin = @import("builtin");
const std = @import("std");
const shuttle = @import("shuttle");

pub const panic = shuttle.panic;

/// On in every mode: std turns it on only where safety is.
pub const std_options: std.Options = .{ .enable_segfault_handler = true };

pub const debug = struct {
    pub const handleSegfault = shuttle.handleSegfault;
};

const Gen = shuttle.Generator(u32, error{});

fn newStack() shuttle.Stack {
    return shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) }) catch @panic("no stack");
}

fn end(g: *Gen) void {
    var s = g.deinit();
    s.deinit();
}

const Case = struct { name: []const u8, run: *const fn () void, says: []const []const u8 };

const fatal = [_]Case{
    .{ .name = "uncaught", .run = uncaught, .says = &.{ "shuttle: a coroutine panicked: boom 7", "coroutine stack trace:", "the code that ran it panicked with it:", "panic: boom 7" } },
    .{ .name = "nested", .run = nestedUncaught, .says = &.{ "shuttle: a coroutine panicked: deep", "the coroutine that ran it panicked with it:", "the code that ran it panicked with it:" } },
    .{ .name = "overflow-coroutine", .run = overflowCoroutine, .says = &.{"shuttle: stack overflow in a coroutine"} },
    .{ .name = "overflow-context", .run = overflowContext, .says = &.{"shuttle: stack overflow"} },
    .{ .name = "overflow-pooled", .run = overflowPooled, .says = &.{"shuttle: stack overflow in a coroutine"} },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2) {
        for (fatal) |case| if (std.mem.eql(u8, args[1], case.name)) {
            case.run();
            std.debug.print("survived {s}\n", .{case.name});
            std.process.exit(0);
        };
        return error.UnknownCase;
    }
    try caught();
    try nestedCaught();
    try safetyCaught();
    try movedCaught();
    const self = try std.process.executablePathAlloc(init.io, arena);
    for (fatal) |case| try expectDeath(init.io, arena, self, case);
}

// Panics the code that ran the coroutine survives.

fn boom(y: *Gen.Yielder, n: u32) error{Canceled}!void {
    try y.yield(n);
    std.debug.panic("boom {d}", .{n});
}

fn caught() !void {
    var g = try Gen.init(newStack(), boom, .{@as(u32, 7)});
    defer end(&g);
    if (try g.co.tryNext({}) != .yielded) return error.NoYield;
    _ = g.co.tryNext({}) catch |e| switch (e) {
        error.Panicked => {
            const p = g.co.panicked() orelse return error.NoPanic;
            if (!std.mem.eql(u8, p.message(), "boom 7")) return error.WrongMessage;
            if (p.cause != null) return error.WrongCause;
            // The trace is the coroutine's own: from the panicking body to its first frame.
            if (!builtin.omit_frame_pointer and p.returnAddresses().len < 2) return error.NoTrace;
            if (!g.co.done()) return error.NotDone;
            return;
        },
    };
    return error.NoPanic;
}

const Middle = shuttle.Generator(u32, error{});

fn middle(y: *Middle.Yielder) error{Canceled}!void {
    var inner = Gen.init(newStack(), boom, .{@as(u32, 9)}) catch @panic("no stack");
    // Not ended: a panic leaves this frame without running it.
    while (inner.next() catch unreachable) |v| try y.yield(v); // unreachable: the inner body fails only when canceled
}

fn nestedCaught() !void {
    var g = try Middle.init(newStack(), middle, .{});
    defer end(&g);
    if (try g.co.tryNext({}) != .yielded) return error.NoYield;
    _ = g.co.tryNext({}) catch {
        const p = g.co.panicked() orelse return error.NoPanic;
        const inner = p.cause orelse return error.NoCause;
        if (!std.mem.eql(u8, p.message(), "boom 9") or !std.mem.eql(u8, inner.message(), "boom 9")) return error.WrongMessage;
        return;
    };
    return error.NoPanic;
}

fn outOfBounds(y: *Gen.Yielder, index: usize) error{Canceled}!void {
    const items = [_]u32{ 1, 2, 3 };
    var i = index;
    std.mem.doNotOptimizeAway(&i);
    try y.yield(items[i]);
}

fn safetyCaught() !void {
    if (builtin.optimize == .fast or builtin.optimize == .small) return;
    var g = try Gen.init(newStack(), outOfBounds, .{@as(usize, 5)});
    defer end(&g);
    _ = g.co.tryNext({}) catch {
        const p = g.co.panicked().?;
        if (std.mem.find(u8, p.message(), "index out of bounds") == null) return error.WrongMessage;
        return;
    };
    return error.NoPanic;
}

// A coroutine whose code moved threads, as a runtime moves a task suspended
// inside an `Io` call: its body parks its context and returns to the
// thread's, and another thread resumes it. Its panic is still its own.

/// Where the running thread's own context is: the context parked code goes
/// back to.
var home: *shuttle.Context = undefined;
/// The coroutine's body, parked.
var parked: shuttle.Context = .{};
var moved_outcome: enum { none, panicked, returned } = .none;

fn movedBoom(_: *Gen.Yielder) error{Canceled}!void {
    // Suspended as a task in an `Io` call is: saved, and back to the thread.
    _ = shuttle.switchTo(&parked, home, shuttle.Context.Nothing, null);
    std.debug.panic("moved", .{});
}

var task_context: shuttle.Context = undefined;
var task_end: shuttle.Context = .{};

fn movedTask(g: *Gen, _: ?shuttle.Context.Nothing) callconv(.c) noreturn {
    moved_outcome = if (g.co.tryNext({})) |_| .returned else |_| .panicked;
    _ = shuttle.switchTo(&task_end, home, shuttle.Context.Nothing, null);
    unreachable; // unreachable: nothing switches back to an ended task
}

fn resumeParked() void {
    var own: shuttle.Context = .{};
    home = &own;
    _ = shuttle.switchTo(&own, &parked, shuttle.Context.Nothing, null);
}

fn movedCaught() !void {
    var g = try Gen.init(newStack(), movedBoom, .{});
    defer end(&g);
    var moved_stack = newStack();
    defer moved_stack.deinit();
    task_context = try shuttle.Context.init(&moved_stack, *Gen, shuttle.Context.Nothing, movedTask, &g);
    var own: shuttle.Context = .{};
    home = &own;
    _ = shuttle.switchTo(&own, &task_context, shuttle.Context.Nothing, null);
    // The body is parked: no coroutine runs on this thread.
    const thread = try std.Thread.spawn(.{}, resumeParked, .{});
    thread.join();
    if (moved_outcome != .panicked) return error.NoPanic;
    const p = g.co.panicked() orelse return error.NoPanic;
    if (!std.mem.eql(u8, p.message(), "moved")) return error.WrongMessage;
    task_context.deinit(&moved_stack);
}

// Fatal cases, each in a child.

fn uncaught() void {
    var g = Gen.init(newStack(), boom, .{@as(u32, 7)}) catch @panic("no stack");
    _ = g.next() catch unreachable; // unreachable: the body fails only when canceled
    _ = g.next() catch unreachable; // unreachable: as above
}

fn deep(y: *Gen.Yielder, _: u32) error{Canceled}!void {
    _ = y;
    @panic("deep");
}

fn nestedBody(y: *Middle.Yielder) error{Canceled}!void {
    var inner = Gen.init(newStack(), deep, .{@as(u32, 0)}) catch @panic("no stack");
    while (inner.next() catch unreachable) |v| try y.yield(v); // unreachable: the inner body fails only when canceled
}

fn nestedUncaught() void {
    var g = Middle.init(newStack(), nestedBody, .{}) catch @panic("no stack");
    _ = g.next() catch unreachable; // unreachable: the body fails only when canceled
}

/// Recurses with a kilobyte of locals a frame, far past any small stack. A
/// frame smaller than the guard lands in it, where Zig emits no stack probes
/// (aarch64, and x86_64 in ReleaseFast).
noinline fn recurse(depth: u64) u64 {
    var block: [1024]u8 = undefined;
    @memset(@as(*volatile [1024]u8, &block), @truncate(depth));
    if (depth == 0) return block[17];
    const r = recurse(depth - 1);
    std.mem.doNotOptimizeAway(&block);
    return r +% block[depth % 1024];
}

fn overflowing(y: *Gen.Yielder, depth: u64) error{Canceled}!void {
    try y.yield(@truncate(recurse(depth)));
}

fn overflowCoroutine() void {
    var g = Gen.init(newStack(), overflowing, .{@as(u64, 1 << 20)}) catch @panic("no stack");
    _ = g.next() catch unreachable; // unreachable: the body fails only when canceled
}

/// On a pool's stack with a neighbour below: on Linux 6.13 and later the
/// guard between them is a guard region inside one mapping.
fn overflowPooled() void {
    var pool = shuttle.Pool.init(std.heap.page_allocator, .{ .classes = &.{.{ .size = .fromRaw(64 * 1024), .count = 2 }} }) catch @panic("no pool");
    _ = (pool.take(.fromRaw(64 * 1024)) catch @panic("no stack")) orelse @panic("no stack");
    const upper = (pool.take(.fromRaw(64 * 1024)) catch @panic("no stack")) orelse @panic("no stack");
    var g = Gen.init(upper, overflowing, .{@as(u64, 1 << 20)}) catch @panic("no stack");
    _ = g.next() catch unreachable; // unreachable: the body fails only when canceled
}

var driver: shuttle.Context = .{};
var task: shuttle.Context = undefined;
var task_stack: shuttle.Stack = undefined;

fn overflowEntry(_: ?shuttle.Context.Nothing, _: ?shuttle.Context.Nothing) callconv(.c) noreturn {
    std.mem.doNotOptimizeAway(recurse(1 << 20));
    _ = shuttle.switchTo(&task, &driver, shuttle.Context.Nothing, null);
    unreachable; // unreachable: never switched back to
}

fn overflowContext() void {
    task_stack = newStack();
    task = shuttle.Context.init(&task_stack, ?shuttle.Context.Nothing, shuttle.Context.Nothing, overflowEntry, null) catch @panic("no stack");
    _ = shuttle.switchTo(&driver, &task, shuttle.Context.Nothing, null);
}

// The children.

fn expectDeath(io: std.Io, arena: std.mem.Allocator, self: []const u8, case: Case) !void {
    const run = try std.process.run(arena, io, .{ .argv = &.{ self, case.name } });
    const died = switch (run.term) {
        .exited => |code| code != 0,
        .signal, .stopped, .unknown => true,
    };
    if (!died) {
        std.debug.print("{s}: the child {f}, where it had to die; it wrote:\n{s}\n", .{ case.name, run.term, run.stderr });
        return error.Survived;
    }
    // Windows names a stack overflow itself, as an exception std reports.
    const windows_overflow = builtin.os.tag == .windows and std.mem.startsWith(u8, case.name, "overflow");
    if (windows_overflow) return;
    for (case.says) |said| if (std.mem.find(u8, run.stderr, said) == null) {
        std.debug.print("{s}: the child did not say \"{s}\"; it wrote:\n{s}\n", .{ case.name, said, run.stderr });
        return error.NotSaid;
    };
}
