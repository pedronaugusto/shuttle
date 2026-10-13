//! A context: code with a stack of its own, which runs until it switches to
//! another context and continues where it stopped when one switches back.
//!
//! A thread's own context is `.{}`: it needs no stack and no `init`, and is
//! saved when the thread first switches away. A context made with `init`
//! starts at its entry when first switched to. A context is what a switch
//! saves and nothing more: the stack it runs on is its maker's to keep, and
//! the calls that need the stack (`init`, `deinit`, `trace`) are given it.
//!
//! A switch is a call as far as the code on either side can tell: the
//! registers the calling convention says a call keeps are kept, the
//! floating-point control state included, and the others are not.
//! Switching is symmetric: any context may switch to any suspended one, on
//! any thread. What a context may do when it moves between threads is in
//! `docs/design.md`.
const Context = @This();

const builtin = @import("builtin");
const std = @import("std");
const native = @import("arch.zig").native;
const Stack = @import("Stack.zig");
const sanitizer = @import("sanitizer.zig");
const teb = @import("teb.zig");
const trace_ = @import("trace.zig");

const is_windows = builtin.os.tag == .windows;

/// Saved while the context is suspended.
registers: native.Registers = undefined,
/// Windows: the thread information block's stack fields, saved while the
/// context is suspended.
bounds: if (is_windows) teb.Bounds else void = if (is_windows) undefined else {},
/// ThreadSanitizer's record of the context.
fiber: sanitizer.Fiber = sanitizer.none,

/// A context's first function. `arg` is what `init` was given, `message`
/// what the first switch to it sent. It never returns: when its work is
/// done it switches away for good, and whoever holds the context releases
/// it.
pub const Entry = *const fn (arg: ?*anyopaque, message: ?*anyopaque) callconv(.c) noreturn;

/// Zeroed bytes kept above a context's first frame, so that an unwinder
/// that reads past the outermost frame reads zeros inside the stack.
pub const headroom = 64;

/// A context that runs `entry(arg, message)` on `stack` when first switched
/// to. The first frame goes below `stack.top`, so what was carved above it
/// stays; on Windows `stack` learns what was committed for it. The stack is
/// the context's until `deinit`: nothing else may run on it.
pub fn init(stack: *Stack, entry: Entry, arg: ?*anyopaque) error{StackTooSmall}!Context {
    const top = stack.top - headroom;
    try stack.reach(top - native.first_frame);
    const above: [*]u8 = @ptrFromInt(top); // safe: the headroom inside the stack, committed by `reach`
    @memset(above[0..headroom], 0);
    const registers = native.initial(top, @intFromPtr(entry), @intFromPtr(arg), @intFromPtr(&native.trampoline)); // safe: addresses, laid in the first frame and read back as functions and an argument
    return .{
        .registers = registers,
        .bounds = if (is_windows) .{ .base = stack.end, .limit = stack.limit, .deallocation = stack.base } else {},
        .fiber = sanitizer.create(),
    };
}

/// Ends a context made by `init` on `stack`, which must not be running:
/// the stack is free again. On Windows `stack` learns the pages its code
/// committed, so a context made on it next starts with them.
pub fn deinit(c: *Context, stack: *Stack) void {
    sanitizer.destroy(c.fiber);
    if (is_windows) stack.limit = @min(stack.limit, c.bounds.limit);
    c.* = undefined;
}

/// Saves the running context into `from` and runs `to`, sending `message`.
/// Returns the message of the switch that resumes `from`. `from` must be
/// the running context and `to` a suspended one: a context made by `init`
/// and not yet run, or one that switched away.
///
/// Inline, so a switch costs what the code around it holds in registers,
/// not every register a call keeps: a call and its return, to and from
/// different contexts, also cost the return predictor a miss each way,
/// four times the switch itself.
pub inline fn switchTo(from: *Context, to: *Context, message: ?*anyopaque) ?*anyopaque {
    if (sanitizer.enabled) {
        from.fiber = sanitizer.current();
        sanitizer.switchTo(to.fiber);
    }
    if (is_windows) {
        from.bounds = teb.get();
        teb.set(to.bounds);
    }
    const t: native.Transfer = .{ .from = &from.registers, .to = &to.registers, .message = message };
    return native.swap(&t).message;
}

/// The stack pointer of a suspended context: everything it keeps on its
/// stack lies above it.
pub fn stackPointer(c: *const Context) usize {
    return c.registers.sp;
}

/// The return addresses of a context made by `init` on `stack`, innermost
/// first, into `out`, ending at its first frame. Called from the context's
/// own code, the trace starts at the caller of `trace`; for a suspended
/// context, at the code that switched away. A suspended context's trace is
/// empty where frame records cannot be followed (frame pointers omitted, or
/// Windows x64), and a running one's where neither they nor the system's
/// unwinder can be.
pub noinline fn trace(c: *const Context, stack: *const Stack, out: []usize) []usize {
    return c.traceFrom(stack, @returnAddress(), out);
}

/// As `trace`, starting at the frame that returns to `first_address`
/// (an earlier frame's call site, which the caller kept), or at the
/// innermost frame when `first_address` is none of them.
pub noinline fn traceFrom(c: *const Context, stack: *const Stack, first_address: usize, out: []usize) []usize {
    const s = stack;
    if (s.contains(trace_.stackPointer())) return trace_.here(first_address, s.bottom, s.end, out);
    const walked = trace_.walk(c.registers.fp, s.bottom, s.end, out);
    const from = std.mem.findScalar(usize, walked, first_address) orelse return walked;
    @memmove(out[0 .. walked.len - from], walked[from..]);
    return out[0 .. walked.len - from];
}
