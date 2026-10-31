//! A panic in a coroutine, handed to the code that ran it: the message and
//! the coroutine's own stack trace, kept in the coroutine's state.
//!
//! Zig unwinds nothing on a panic, so a panicking coroutine cannot return
//! through its frames: the handler records the panic and switches out of
//! the coroutine for good. Its stack stays as it was, whatever it held held
//! still, until the coroutine is ended. The code that ran it panics with it
//! (`next`), which, if that code is itself a coroutine, hands it on up, or
//! gets `error.Panicked` (`tryNext`). The process ends at the outermost
//! code, which prints each coroutine's trace before its own.
//!
//! The handler, `coroutine.handlePanic`, is installed in the program's
//! root: `pub const panic = shuttle.panic;`.
const Panic = @This();

const std = @import("std");
const trace = @import("trace.zig");

/// Bytes of the message kept; a longer one is cut short.
pub const message_capacity = 256;
/// Frames of the trace kept, innermost first.
pub const trace_capacity = 32;

message_bytes: [message_capacity]u8 = undefined,
message_len: usize = 0,
trace_addresses: [trace_capacity]usize = undefined,
trace_len: usize = 0,
/// The panic of a coroutine this one ran, which it panicked with in turn.
cause: ?*const Panic = null,

pub fn message(p: *const Panic) []const u8 {
    return p.message_bytes[0..p.message_len];
}

/// The coroutine's return addresses where it panicked, innermost first,
/// ending at its first frame. Empty where frame pointers are omitted.
pub fn returnAddresses(p: *const Panic) []const usize {
    return p.trace_addresses[0..p.trace_len];
}

/// Panics here with `p`: through the program's panic handler, so a
/// coroutine running this code hands it on.
pub fn raise(p: *const Panic) noreturn {
    raising = p;
    @panic(p.message());
}

/// The panic a coroutine's code is raising on this thread, between
/// `raise` and the handler.
threadlocal var raising: ?*const Panic = null;

/// Takes the panic being raised on this thread, if the panic now handled
/// is `raise`'s.
pub fn takeRaising() ?*const Panic {
    const p = raising;
    raising = null;
    return p;
}

/// Keeps `msg`, the cause, and the trace of the stack `[low, high)` the
/// panicking code runs on, from the frame that returns to
/// `first_trace_address`.
pub fn record(p: *Panic, msg: []const u8, first_trace_address: usize, cause: ?*const Panic, low: usize, high: usize) void {
    p.message_len = @min(msg.len, message_capacity);
    @memcpy(p.message_bytes[0..p.message_len], msg[0..p.message_len]);
    p.cause = cause;
    // From the frame that panicked, leaving the handler's own out.
    p.trace_len = trace.here(first_trace_address, low, high, &p.trace_addresses).len;
}

/// Prints the traces of the coroutines a panic came up through, innermost
/// first, and says the code they came up to panicked with it.
pub fn describe(p: *const Panic) void {
    describeOne(p);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.writeAll("the code that ran it panicked with it:\n") catch return;
}

fn describeOne(p: *const Panic) void {
    if (p.cause) |inner| describeOne(inner);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    const w = stderr.writer;
    if (p.cause == null) {
        w.print("shuttle: a coroutine panicked: {s}\n", .{p.message()}) catch return;
    } else {
        w.writeAll("the coroutine that ran it panicked with it:\n") catch return;
    }
    w.writeAll("coroutine stack trace:\n") catch return;
    // std's trace takes its addresses as a mutable slice, which writing one
    // only reads: a copy of them, here on the way out.
    var addresses: @TypeOf(p.trace_addresses) = @splat(0);
    const kept = p.returnAddresses();
    @memcpy(addresses[0..kept.len], kept);
    std.debug.writeStackTrace(&.{ .return_addresses = addresses[0..kept.len], .skipped = .none }, stderr) catch return;
}
