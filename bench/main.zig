//! shuttle's benchmarks: what a switch costs, and what making a context
//! costs, on its own stack and on a pool's. `bay bench` runs them in
//! ReleaseFast and writes one JSON line per row to stdout; `bay test` runs
//! each row once with `--smoke`. Timings are taken by hand, never in CI.
//! `zig-out/bench/shuttle-bench <row prefix>` runs the rows whose name
//! starts with the prefix.
const std = @import("std");
const shuttle = @import("shuttle");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const WorkloadError = error{ OutOfMemory, SystemResources, Overflow, StackTooSmall, InvalidClasses, TooManyStacks, PoolEmpty };
const Row = shakedown.bench.Row(Bench, WorkloadError);

const Counter = shuttle.Coroutine(u64, u64, error{Canceled}!u64);
const Numbers = shuttle.Generator(u64, error{});

const Bench = struct {
    gpa: std.mem.Allocator,
    pool: shuttle.Pool = undefined,
    driver: shuttle.Context = .{},
    task: shuttle.Context = undefined,
    stack: shuttle.Stack = undefined,
    counter: *Counter = undefined,
    numbers: Numbers = undefined,
    sink: u64 = 0,

    // The switch, both ways.

    fn bounce(arg: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
        const b: *Bench = @ptrCast(@alignCast(arg.?)); // safe: setup passes the bench
        while (true) _ = shuttle.switchTo(&b.task, &b.driver, null);
    }

    fn switchSetup(b: *Bench) WorkloadError!void {
        b.stack = try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) });
        b.task = try shuttle.Context.init(&b.stack, bounce, b);
    }

    fn switchTeardown(b: *Bench) WorkloadError!void {
        b.task.deinit(&b.stack);
        b.stack.deinit();
    }

    fn switchRoundTrip(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| _ = shuttle.switchTo(&b.driver, &b.task, null);
    }

    // The handoff, both ways.

    fn handoffBody(arg: ?*anyopaque) noreturn {
        const b: *Bench = @ptrCast(@alignCast(arg.?)); // safe: setup passes the bench
        while (true) shuttle.handoff.switchTo(&b.task, &b.driver, .{ .run = noteFrom, .data = b });
    }

    fn noteFrom(data: ?*anyopaque, _: *shuttle.Context) void {
        const b: *Bench = @ptrCast(@alignCast(data.?)); // safe: the body passes the bench
        b.sink +%= 1;
    }

    fn handoffSetup(b: *Bench) WorkloadError!void {
        b.stack = try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) });
        b.task = try shuttle.Context.init(&b.stack, shuttle.handoff.entry(handoffBody), b);
    }

    fn handoffRoundTrip(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| shuttle.handoff.switchTo(&b.driver, &b.task, null);
    }

    // Coroutines and generators.

    fn count(y: *Counter.Yielder, first: u64) error{Canceled}!u64 {
        var total = first;
        while (true) total +%= try y.yield(total);
    }

    fn counterSetup(b: *Bench) WorkloadError!void {
        b.counter = try Counter.init(try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) }), count, .{});
    }

    fn counterTeardown(b: *Bench) WorkloadError!void {
        var s = b.counter.deinit();
        s.deinit();
    }

    fn counterNext(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |i| b.sink +%= b.counter.next(i).yielded;
    }

    fn naturals(y: *Numbers.Yielder) error{Canceled}!void {
        var i: u64 = 0;
        while (true) : (i +%= 1) try y.yield(i);
    }

    fn numbersSetup(b: *Bench) WorkloadError!void {
        b.numbers = try Numbers.init(try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) }), naturals, .{});
    }

    fn numbersTeardown(b: *Bench) WorkloadError!void {
        var s = b.numbers.deinit();
        s.deinit();
    }

    fn numbersNext(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| b.sink +%= (b.numbers.next() catch unreachable).?; // unreachable: the body fails only when canceled
    }

    // Making contexts.

    fn poolSetup(b: *Bench) WorkloadError!void {
        b.pool = try shuttle.Pool.init(b.gpa, .{ .classes = &.{.{ .size = .fromRaw(64 * 1024), .count = 64 }} });
    }

    fn poolTeardown(b: *Bench) WorkloadError!void {
        b.pool.deinit(b.gpa);
    }

    fn never(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
        unreachable; // unreachable: the contexts made here are never run
    }

    /// A stack of its own (mapped and guarded), a context on it, and both
    /// ended.
    fn createOwn(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var s = try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) });
            var c = try shuttle.Context.init(&s, never, b);
            c.deinit(&s);
            s.deinit();
        }
    }

    /// A pool's stack, a context on it, and the stack given back.
    fn createPooled(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var s = try b.pool.take(.fromRaw(64 * 1024)) orelse return error.PoolEmpty;
            var c = try shuttle.Context.init(&s, never, b);
            c.deinit(&s);
            b.pool.give(s);
        }
    }

    fn once(y: *Counter.Yielder, first: u64) error{Canceled}!u64 {
        _ = y;
        return first + 1;
    }

    /// A coroutine on a pool's stack, run to its return and ended.
    fn coroutinePooled(b: *Bench, units: u64) WorkloadError!void {
        for (0..units) |i| {
            const co = try Counter.init(try b.pool.take(.fromRaw(64 * 1024)) orelse return error.PoolEmpty, once, .{});
            b.sink +%= co.next(i).returned catch unreachable; // unreachable: the body fails only when canceled
            b.pool.give(co.deinit());
        }
    }
};

const rows = [_]Row{
    .{ .name = "switch/round-trip", .unit = "round trip", .run = Bench.switchRoundTrip, .fixture = .{ .lifetime = .row, .setup = Bench.switchSetup, .teardown = Bench.switchTeardown } },
    .{ .name = "handoff/round-trip", .unit = "round trip", .run = Bench.handoffRoundTrip, .fixture = .{ .lifetime = .row, .setup = Bench.handoffSetup, .teardown = Bench.switchTeardown } },
    .{ .name = "coroutine/next", .unit = "next and yield", .run = Bench.counterNext, .fixture = .{ .lifetime = .row, .setup = Bench.counterSetup, .teardown = Bench.counterTeardown } },
    .{ .name = "generator/next", .unit = "value", .run = Bench.numbersNext, .fixture = .{ .lifetime = .row, .setup = Bench.numbersSetup, .teardown = Bench.numbersTeardown } },
    .{ .name = "create/own-stack", .unit = "context", .run = Bench.createOwn },
    .{ .name = "create/pooled-stack", .unit = "context", .run = Bench.createPooled, .fixture = .{ .lifetime = .row, .setup = Bench.poolSetup, .teardown = Bench.poolTeardown } },
    .{ .name = "create/pooled-coroutine-run", .unit = "coroutine", .run = Bench.coroutinePooled, .fixture = .{ .lifetime = .row, .setup = Bench.poolSetup, .teardown = Bench.poolTeardown } },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try shakedown.bench.Options.fromArguments(args[1..]);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var b: Bench = .{ .gpa = init.gpa };
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &b, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, options);
    try stdout.interface.flush();
    std.mem.doNotOptimizeAway(b.sink);
}
