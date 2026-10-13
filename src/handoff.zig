//! A switch the other side finishes: what a job system needs to move a
//! context between threads safely.
//!
//! A context that parks itself (on a wait list, on a run queue another
//! thread pops from) must not be visible there before its registers are
//! saved: a thread that took it and switched to it first would resume it
//! from half-written state. So the parking is done by the context switched
//! to, once the switch is complete: `switchTo(from, to, after)` saves `from`,
//! and before `to` continues, `after.run(after.data, from)` runs on `to`'s
//! side, where publishing `from` is safe. Giving back the stack of a context
//! that is finished is the same: it cannot be done on that stack.
//!
//! Every switch to a context that takes part must be this module's
//! `switchTo`, and every context made for it must start at an `entry`: a
//! resumed context finishes the switch that resumed it whichever way it was
//! resumed. The scheduler (queues, wait lists, worker threads) is the
//! caller's.
const Context = @import("Context.zig");

/// What runs on the side switched to, once the side that switched is
/// saved. `from` is that context: it may be published, resumed by another
/// thread, or (when finished) ended and its stack given back.
pub const After = struct {
    run: *const fn (data: ?*anyopaque, from: *Context) void,
    data: ?*anyopaque = null,
};

/// What a switch of this module sends: who switched, and what to run.
const Note = struct { from: *Context, after: ?After };

/// Saves the running context into `from` and runs `to`, which runs
/// `after` first. Returns when a switch of this module resumes `from`,
/// once that switch's own `after` has run.
pub fn switchTo(from: *Context, to: *Context, after: ?After) void {
    var note: Note = .{ .from = from, .after = after };
    finish(Context.switchTo(from, to, &note));
}

/// Runs what the switch that resumed this context asked for. The note is
/// copied first: once `after` publishes the context that sent it, that
/// context's stack, where the note lives, may run again.
fn finish(message: ?*anyopaque) void {
    const note: Note = @as(*const Note, @ptrCast(@alignCast(message.?))).*; // safe: every switch of this module sends a Note
    if (note.after) |a| a.run(a.data, note.from);
}

/// The entry of a context that takes part: it finishes the switch that
/// started it, then runs `body(arg)`, which never returns. A body that is
/// done switches away for good, typically with an `after` that ends it.
pub fn entry(comptime body: fn (arg: ?*anyopaque) noreturn) Context.Entry {
    return struct {
        fn start(arg: ?*anyopaque, message: ?*anyopaque) callconv(.c) noreturn {
            finish(message);
            body(arg);
        }
    }.start;
}
