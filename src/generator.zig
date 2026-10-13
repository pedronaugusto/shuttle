//! A generator: a coroutine that only yields, read as an iterator.
//!
//! `Generator(Yield, Error)` runs a body `fn (*Yielder, args...) E!void`,
//! whose error set E holds `Error` and `error.Canceled`; `next` returns
//! each yielded value, then null once the body returns, or the error it
//! returned. Ending a generator before its body returns cancels it, as
//! ending a coroutine does.
const Stack = @import("Stack.zig");
const Coroutine = @import("coroutine.zig").Coroutine;

pub fn Generator(comptime Yield: type, comptime Error: type) type {
    return struct {
        const Self = @This();
        const Co = Coroutine(void, Yield, (Error || error{Canceled})!void);

        co: *Co,

        /// Whether the body fails only by being canceled.
        const none = if (@typeInfo(Error).error_set.error_names) |names| names.len == 0 else false;

        pub const Yielder = Co.Yielder;
        pub const InitError = Co.InitError;

        /// A generator running `body(yielder, args...)` on `stack` from
        /// its first `next`.
        pub fn init(stack: Stack, comptime body: anytype, args: anytype) InitError!Self {
            const Args = @TypeOf(args);
            const wrap = struct {
                fn run(y: *Yielder, _: void, a: Args) (Error || error{Canceled})!void {
                    return @call(.auto, body, .{y} ++ a);
                }
            }.run;
            return .{ .co = try Co.init(stack, wrap, .{args}) };
        }

        /// The next value the body yields, or null once it has returned.
        /// A panic in the body panics here.
        pub fn next(g: *Self) Error!?Yield {
            if (g.co.done()) return null;
            switch (g.co.next({})) {
                .yielded => |v| return v,
                .returned => |r| {
                    if (comptime none) {
                        r catch |e| switch (e) {
                            error.Canceled => {},
                        };
                    } else {
                        r catch |e| switch (e) {
                            error.Canceled => {},
                            else => |other| return other,
                        };
                    }
                    return null;
                },
            }
        }

        /// Ends the generator, canceling a body that has not returned, and
        /// gives back its stack.
        pub fn deinit(g: *Self) Stack {
            return g.co.deinit();
        }
    };
}
