//! shuttle: stackful contexts for Zig.
//!
//! - `Stack` and `Pool`: stacks with guards below them, in size classes.
//! - `Context` and `switchTo`: the switch, symmetric, any context to any.
//! - `handoff`: a switch whose other side finishes it, to publish the
//!   context that switched only once it is saved.
//! - `Coroutine` and `Generator`: typed values both ways, a panic handed to
//!   the resumer, cancellation that runs the body's defers.
//! - `panic` and `handleSegfault`: the handlers that hand a panic over and
//!   name a stack overflow.
const std = @import("std");

pub const Stack = @import("Stack.zig");
pub const Context = @import("Context.zig");
pub const Pool = @import("Pool.zig");
pub const handoff = @import("handoff.zig");
pub const Coroutine = @import("coroutine.zig").Coroutine;
pub const Generator = @import("generator.zig").Generator;
pub const Panic = @import("Panic.zig");

/// The panic handler that hands a coroutine's panic to the code that ran
/// it. Install it in the program's root: `pub const panic = shuttle.panic;`.
pub const panic = std.debug.FullPanic(@import("coroutine.zig").handlePanic);

/// The segfault handler that names a stack overflow; see `overflow`.
pub const handleSegfault = overflow.handleSegfault;
pub const overflow = @import("overflow.zig");

/// Whether shuttle switches contexts on this target.
pub const supported = @import("arch.zig").supported;

pub const switchTo = Context.switchTo;

// The tests run in this module, so test support that links shuttle
// (shakedown) takes this copy and the test binary holds one shuttle.
test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
