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

fn pinger(_: ?*anyopaque, message: ?*anyopaque) callconv(.c) noreturn {
    var n = @intFromPtr(message); // safe: the example sends counts
    while (true) n = @intFromPtr(shuttle.switchTo(&ping, &main_context, @ptrFromInt(n + 1))); // safe: as above
}

fn context() !void {
    ping = try shuttle.Context.init(try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) }), pinger, null);
    const back = shuttle.switchTo(&main_context, &ping, @ptrFromInt(41)); // safe: a count
    std.debug.assert(@intFromPtr(back) == 42); // safe: a count
    var s = ping.deinit();
    s.deinit();
}
// --- README:context ---

// --- README:jobs ---
const Job = struct {
    context: shuttle.Context,
    /// Whoever switched to the job, to switch back to.
    worker: *shuttle.Context = undefined,
    done: bool = false,
};

fn work(arg: ?*anyopaque) noreturn {
    const job: *Job = @ptrCast(@alignCast(arg.?)); // safe: the job passes itself
    // ... the job's work, parking with handoff.switchTo as it waits ...
    shuttle.handoff.switchTo(&job.context, job.worker, .{ .run = finished });
    unreachable; // unreachable: a finished job is never switched to again
}

/// Runs on the worker once the job's registers are saved: from here on
/// another thread could take the job, or its stack could be given back.
fn finished(_: ?*anyopaque, from: *shuttle.Context) void {
    const job: *Job = @fieldParentPtr("context", from);
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
    var job: Job = undefined;
    job = .{ .context = try .init(pool.take(.fromRaw(16 * 1024)).?, shuttle.handoff.entry(work), &job), .worker = &worker };
    shuttle.handoff.switchTo(&worker, &job.context, null);
    std.debug.assert(job.done);
    pool.give(job.context.deinit());
}
// --- README:jobs ---
