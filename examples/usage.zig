const std = @import("std");
const shuttle = @import("shuttle");

pub fn main() !void {
    if (!shuttle.supported) return;
    try coroutine();
    try generator();
    try context();
    try jobs();
}

// --- README:usage ---
/// Sums what it is given, handing back the running total, until it is
/// given zero.
const Sum = shuttle.Coroutine(u32, u64, error{Canceled}!u64);

fn sum(y: *Sum.Yielder, first: u32) error{Canceled}!u64 {
    var total: u64 = first;
    while (true) {
        const n = try y.yield(total); // back to whoever runs it, with total
        if (n == 0) return total;
        total += n;
    }
}

fn coroutine() !void {
    const stack = try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) });
    const co = try Sum.init(stack, sum, .{});
    std.debug.assert(co.next(5).yielded == 5); // the first input is sum's parameter
    std.debug.assert(co.next(7).yielded == 12); // later ones are what yield returns
    std.debug.assert(try co.next(0).returned == 12);
    var s = co.deinit(); // the stack back; a suspended coroutine is canceled first
    s.deinit();
}
// --- README:usage ---

// --- README:generator ---
const Squares = shuttle.Generator(u64, error{});

fn squares(y: *Squares.Yielder, limit: u64) error{Canceled}!void {
    var i: u64 = 0;
    while (i * i < limit) : (i += 1) try y.yield(i * i);
}

fn generator() !void {
    var g = try Squares.init(try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) }), squares, .{@as(u64, 50)});
    var total: u64 = 0;
    while (try g.next()) |square| total += square;
    std.debug.assert(total == 0 + 1 + 4 + 9 + 16 + 25 + 36 + 49);
    var s = g.deinit();
    s.deinit();
}
// --- README:generator ---

// --- README:context ---
var main_context: shuttle.Context = .{}; // a thread's own context needs no stack
var ping: shuttle.Context = undefined;

fn pinger(_: ?shuttle.Context.Nothing, message: ?*u64) callconv(.c) noreturn {
    var n = message.?;
    while (true) {
        n.* += 1;
        n = shuttle.switchTo(&ping, &main_context, *u64, n).?;
    }
}

fn context() !void {
    var stack = try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) });
    defer stack.deinit();
    ping = try shuttle.Context.init(&stack, ?shuttle.Context.Nothing, *u64, pinger, null); // the stack stays yours
    defer ping.deinit(&stack);
    var n: u64 = 41;
    _ = shuttle.switchTo(&main_context, &ping, *u64, &n);
    std.debug.assert(n == 42);
}
// --- README:context ---

// --- README:jobs ---
const Job = struct {
    context: shuttle.Context,
    stack: shuttle.Stack,
    /// Whoever switched to the job, to switch back to.
    worker: *shuttle.Context = undefined,
    done: bool = false,
    /// What the worker does once the job is off its stack.
    ending: shuttle.handoff.After = .{ .run = finished },
};

fn work(job: *Job) noreturn {
    // ... the job's work, parking with handoff.switchTo as it waits ...
    shuttle.handoff.switchTo(&job.context, job.worker, &job.ending);
    unreachable; // unreachable: a finished job is never switched to again
}

/// Runs on the worker once the job's registers are saved: from here on
/// another thread could take the job, or its stack could be given back.
fn finished(after: *shuttle.handoff.After, _: *shuttle.Context) void {
    const job: *Job = @fieldParentPtr("ending", after);
    job.done = true;
}

fn jobs() !void {
    const gpa = std.heap.page_allocator;
    var pool = try shuttle.Pool.init(gpa, .{ .classes = &.{
        .{ .size = .fromRaw(64 * 1024), .count = 128 },
        .{ .size = .fromRaw(1024 * 1024), .count = 8 },
    } });
    defer pool.deinit(gpa);
    var worker: shuttle.Context = .{};
    var job: Job = .{ .context = undefined, .stack = (try pool.take(.fromRaw(16 * 1024))).?, .worker = &worker };
    job.context = try shuttle.handoff.init(&job.stack, *Job, work, &job);
    shuttle.handoff.switchTo(&worker, &job.context, null);
    std.debug.assert(job.done);
    job.context.deinit(&job.stack);
    pool.give(job.stack);
}
// --- README:jobs ---
