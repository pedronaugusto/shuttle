//! A coroutine: a function on a stack of its own that yields values to the
//! code that runs it and is given values back, until it returns.
//!
//! `Coroutine(Input, Yield, Return)` runs a body `fn (*Yielder, Input,
//! args...) Return`. `next(input)` runs it until it yields or returns: the
//! first input is the body's parameter, each later one what `yield` returns.
//! The coroutine's state and the body's arguments live at the top of its
//! stack, so making one allocates nothing.
//!
//! A panic in the body is handed to the code that ran it, when the program
//! installs `shuttle.panic`: `next` panics there with it, and `tryNext`
//! returns `error.Panicked`. Ending a suspended coroutine cancels it: its
//! `yield` returns `error.Canceled`, so the body's `try` unwinds it through
//! its defers, as an error does.
const std = @import("std");
const Context = @import("Context.zig");
const Stack = @import("Stack.zig");
const Panic = @import("Panic.zig");
const trace = @import("trace.zig");

pub const State = enum(u8) {
    /// Made, never run.
    fresh,
    running,
    /// Yielded, waiting for its next input.
    suspended,
    returned,
    /// Panicked: it runs no more, and its stack was not unwound.
    panicked,
};

/// What every coroutine has, whatever it carries: what the panic handler
/// and the segfault handler read.
pub const Core = struct {
    context: Context,
    /// The stack the coroutine runs on, below its state.
    stack: Stack,
    /// Whoever runs the coroutine, saved while it runs.
    caller: Context = .{},
    state: State = .fresh,
    /// Set by `deinit` on a suspended coroutine: `yield` fails from then on.
    canceling: bool = false,
    panic: Panic = .{},

    /// Runs the coroutine until it yields, returns or panics.
    fn enter(c: *Core) error{Panicked}!void {
        const previous = active;
        active = c;
        c.state = .running;
        _ = Context.switchTo(&c.caller, &c.context, null);
        active = previous;
        if (c.state == .panicked) return error.Panicked;
    }

    /// Back to whoever runs the coroutine, in `state`.
    fn leave(c: *Core, state: State) void {
        c.state = state;
        _ = Context.switchTo(&c.context, &c.caller, null);
    }

    /// The panic handler's way out of a panicking coroutine, which never
    /// runs again.
    pub fn abandon(c: *Core) noreturn {
        c.leave(.panicked);
        unreachable; // unreachable: nothing switches back to a panicked coroutine
    }
};

/// The coroutine running on this thread, if any. Read only on this
/// thread's own code: `enter` sets it before the switch and puts it back
/// after, on the same thread.
threadlocal var active: ?*Core = null;

/// The coroutine this thread runs, when the code asking runs on its stack.
pub fn current() ?*Core {
    const c = running() orelse return null;
    if (!c.stack.contains(trace.stackPointer())) return null;
    return c;
}

/// The coroutine this thread runs, wherever the code asking runs: a signal
/// handler on its own stack included.
pub fn running() ?*Core {
    const c = active orelse return null;
    return if (c.state == .running) c else null;
}

pub fn Coroutine(comptime Input: type, comptime Yield: type, comptime Return: type) type {
    return struct {
        const Self = @This();

        core: Core,
        value: Value,
        /// The stack's top before the coroutine took its share of it.
        top: usize,
        /// The body's arguments, at the top of the stack.
        args: *anyopaque,

        const Value = union { input: Input, yielded: Yield, returned: Return };

        pub const Result = union(enum) { yielded: Yield, returned: Return };

        /// The body's handle on its coroutine.
        pub const Yielder = opaque {
            /// Hands `value` to the code running the coroutine and waits for
            /// the next input. `error.Canceled` when the coroutine is being
            /// ended: the body should return, and from then on every
            /// `yield` fails at once.
            pub fn yield(y: *Yielder, value: Yield) error{Canceled}!Input {
                const self: *Self = @ptrCast(@alignCast(y)); // safe: a Yielder is its coroutine
                if (self.core.canceling) return error.Canceled;
                self.value = .{ .yielded = value };
                self.core.leave(.suspended);
                if (self.core.canceling) return error.Canceled;
                return self.value.input;
            }
        };

        pub const InitError = error{StackTooSmall};

        /// A coroutine that runs `body(yielder, input, args...)` on
        /// `stack` from its first `next`. Its state and `args` take the top
        /// of the stack. `deinit` gives the stack back.
        pub fn init(stack: Stack, comptime body: anytype, args: anytype) InitError!*Self {
            const Args = @TypeOf(args);
            comptime check(@TypeOf(body), Args);
            var s = stack;
            const top = s.top;
            const self: *Self = @ptrCast(@alignCast(try s.carve(@sizeOf(Self), .of(Self)))); // safe: carved for it, aligned
            const held: *Args = @ptrCast(@alignCast(try s.carve(@sizeOf(Args), .of(Args)))); // safe: as above
            held.* = args;
            const entry = struct {
                fn start(arg: ?*anyopaque, _: ?*anyopaque) callconv(.c) noreturn {
                    const co: *Self = @ptrCast(@alignCast(arg.?)); // safe: `init` passes its coroutine
                    const a: *Args = @ptrCast(@alignCast(co.args)); // safe: `init` placed the arguments there
                    const y: *Yielder = @ptrCast(co); // safe: a Yielder is its coroutine
                    // Read before the result is written over it.
                    const input = co.value.input;
                    const result = @call(.auto, body, .{ y, input } ++ a.*);
                    co.value = .{ .returned = result };
                    co.core.leave(.returned);
                    unreachable; // unreachable: nothing switches back to a returned coroutine
                }
            }.start;
            self.* = .{
                .core = .{ .context = try Context.init(&s, entry, self), .stack = s },
                .value = undefined,
                .top = top,
                .args = held,
            };
            return self;
        }

        fn check(comptime Body: type, comptime Args: type) void {
            const info = @typeInfo(Body).@"fn";
            if (info.param_types.len < 2 or info.param_types[0] != *Yielder or info.param_types[1] != Input)
                @compileError("a coroutine's body takes *Yielder and its input first, then the arguments");
            if (info.param_types.len - 2 != @typeInfo(Args).@"struct".field_names.len) @compileError("the arguments do not match the body's parameters");
        }

        /// Runs the coroutine until it yields or returns, with `input` as
        /// its first parameter or what its `yield` returns. If it panics,
        /// panics here with its panic.
        pub fn next(self: *Self, input: Input) Result {
            return self.tryNext(input) catch self.core.panic.raise();
        }

        /// As `next`, but a panic in the coroutine is `error.Panicked`, and
        /// `panicked` describes it. The coroutine is then finished, its stack
        /// not unwound: what it held is held still.
        pub fn tryNext(self: *Self, input: Input) error{Panicked}!Result {
            std.debug.assert(self.core.state == .fresh or self.core.state == .suspended);
            self.value = .{ .input = input };
            try self.core.enter();
            return switch (self.core.state) {
                .suspended => .{ .yielded = self.value.yielded },
                .returned => .{ .returned = self.value.returned },
                else => unreachable, // unreachable: `enter` returns once the body yielded, returned or panicked
            };
        }

        pub fn state(self: *const Self) State {
            return self.core.state;
        }

        /// Whether the coroutine has returned or panicked.
        pub fn done(self: *const Self) bool {
            return self.core.state == .returned or self.core.state == .panicked;
        }

        /// The panic that ended the coroutine, if one did.
        pub fn panicked(self: *const Self) ?*const Panic {
            return if (self.core.state == .panicked) &self.core.panic else null;
        }

        /// Ends the coroutine and gives back its stack. A suspended one is
        /// canceled first: it runs until its body returns, every `yield`
        /// failing with `error.Canceled`. A panic while it is canceled
        /// panics here.
        pub fn deinit(self: *Self) Stack {
            if (self.core.state == .suspended) {
                self.core.canceling = true;
                self.value = .{ .input = undefined };
                self.core.enter() catch self.core.panic.raise();
                std.debug.assert(self.core.state == .returned);
            }
            std.debug.assert(self.core.state != .running);
            const top = self.top;
            var s = self.core.stack;
            self.core.context.deinit(&s);
            s.top = top;
            return s;
        }
    };
}

/// The panic handler that hands a coroutine's panic to the code that ran
/// it. Elsewhere it is std's, after the traces of the coroutines a panic
/// came up through.
pub fn handlePanic(msg: []const u8, first_trace_address: ?usize) noreturn {
    @branchHint(.cold);
    const cause = Panic.takeRaising();
    if (current()) |c| {
        const s = c.stack;
        // As std's handler starts its trace: at the panic, not in here.
        c.panic.record(msg, first_trace_address orelse @returnAddress(), cause, s.bottom, s.end);
        c.abandon();
    }
    if (cause) |p| p.describe();
    std.debug.defaultPanic(msg, first_trace_address);
}
