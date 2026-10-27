//! A switch the other side finishes: what a job system needs to move a
//! context between threads safely.
//!
//! A context that parks itself (on a wait list, on a run queue another
//! thread pops from) must not be visible there before its registers are
//! saved: a thread that took it and switched to it first would resume it
//! from half-written state. So the parking is done by the context switched
//! to, once the switch is complete: `switchTo(from, to, after)` saves `from`,
//! and before `to` continues, `after.run(after, from)` runs on `to`'s
//! side, where publishing `from` is safe. Giving back the stack of a context
//! that is finished is the same: it cannot be done on that stack.
//!
//! Every switch to a context that takes part must be this module's
//! `switchTo`, and every context made for it must be made by its `init`: a
//! resumed context finishes the switch that resumed it whichever way it was
//! resumed. The scheduler (queues, wait lists, worker threads) is the
//! caller's.
const Context = @import("Context.zig");
const Stack = @import("Stack.zig");

/// What runs on the side switched to, once the side that switched is
/// saved. `from` is that context: it may be published, resumed by another
/// thread, or (when finished) ended and its stack given back. It is kept
/// in the record of the work it does, which `run` finds by
/// `@fieldParentPtr`.
pub const After = struct {
    run: *const fn (after: *After, from: *Context) void,
};

/// What a switch of this module sends: who switched, and what to run.
const Note = struct { from: *Context, after: ?*After };

/// Saves the running context into `from` and runs `to`, which runs
/// `after` first. Returns when a switch of this module resumes `from`,
/// once that switch's own `after` has run.
/// Inline, as `Context.switchTo` is: a call returned to from another
/// context costs the return predictor a miss.
pub inline fn switchTo(from: *Context, to: *Context, after: ?*After) void {
    var note: Note = .{ .from = from, .after = after };
    finish(Context.switchTo(from, to, *Note, &note));
}

/// Runs what the switch that resumed this context asked for. The note is
/// copied first: once `after` publishes the context that sent it, that
/// context's stack, where the note lives, may run again.
fn finish(message: ?*Note) void {
    const note = message.?.*;
    if (note.after) |a| a.run(a, note.from);
}

/// A context that takes part, on `stack`: it finishes the switch that
/// started it, then runs `body(arg)`, which never returns. A body that is
/// done switches away for good, typically with an `after` that ends it.
/// `Arg` is a pointer, or an optional one.
pub fn init(stack: *Stack, comptime Arg: type, comptime body: fn (arg: Arg) noreturn, arg: Arg) error{StackTooSmall}!Context {
    const entry = struct {
        fn start(a: Arg, message: ?*Note) callconv(.c) noreturn {
            finish(message);
            body(a);
        }
    }.start;
    return Context.init(stack, Arg, *Note, entry, arg);
}
