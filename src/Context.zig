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
/// context is suspended; the switch's assembly exchanges them.
bounds: if (is_windows) teb.Bounds else void = if (is_windows) undefined else {},
/// ThreadSanitizer's record of the context.
fiber: sanitizer.Fiber = sanitizer.none,
/// What the context's code runs inside (the context of the coroutine whose
/// code it is), saved while the context is suspended. A switch saves the
/// thread's into the context it leaves and installs the one it resumes, so
/// it moves with the context to whichever thread resumes it. A coroutine's
/// own context names itself; `.{}` and `init` name nothing.
inside: ?*Context = null,

/// What the code running on this thread runs inside: the `inside` of its
/// context, installed by the switch that resumed it.
threadlocal var running_inside: ?*Context = null;

/// This thread's slot, its address taken afresh at every call. The compiler
/// may otherwise reuse a thread-local's address computed before a switch
/// after it, the address of the thread a moved context left: on aarch64 the
/// address is a register read it merges freely (reactor's lanes crashed so
/// in optimized builds). The address passes through an assembly statement,
/// which the compiler cannot see through.
noinline fn insideSlot() *?*Context {
    // aegis: boundary: the slot's address passes through the processor unchanged, so the compiler cannot reuse one from before a switch
    return asm volatile (""
        : [address] "=r" (-> *?*Context),
        : [slot] "0" (&running_inside),
    );
}

/// What the running code runs inside, as `inside` names it: null outside
/// any coroutine.
pub fn runningInside() ?*Context {
    return insideSlot().*;
}

/// The message type of contexts whose switches carry none: its only value
/// is null.
pub const Nothing = *opaque {};

/// The first function of a context whose code is handed an `Arg` and whose
/// switches carry `Message`s: `arg` is what `init` was given, `message`
/// what the first switch to it sent. `Arg` is a pointer, or an optional
/// one; `Message` a pointer to what the switches share (`Nothing` when
/// they share nothing). It never returns: when its work is done it
/// switches away for good, and whoever holds the context releases it.
pub fn Entry(comptime Arg: type, comptime Message: type) type {
    comptime checkArg(Arg);
    comptime checkMessage(Message);
    return *const fn (arg: Arg, message: ?Message) callconv(.c) noreturn;
}

/// What the first argument register holds: an address, never a slice.
fn checkArg(comptime Arg: type) void {
    const pointer = switch (@typeInfo(Arg)) {
        .pointer => |p| p,
        .optional => |o| if (@typeInfo(o.child) == .pointer) @typeInfo(o.child).pointer else @compileError("a context's argument is a pointer or an optional one, not " ++ @typeName(Arg)),
        else => @compileError("a context's argument is a pointer or an optional one, not " ++ @typeName(Arg)),
    };
    if (pointer.size == .slice) @compileError("a context's argument is one address, not the slice " ++ @typeName(Arg));
}

/// What a switch hands over: one address, which the side switched to may
/// write through.
fn checkMessage(comptime Message: type) void {
    const info = @typeInfo(Message);
    if (info != .pointer or info.pointer.size != .one or info.pointer.attrs.@"const") @compileError("a switch's message is a mutable single pointer, not " ++ @typeName(Message));
}

/// Zeroed bytes kept above a context's first frame, so that an unwinder
/// that reads past the outermost frame reads zeros inside the stack.
pub const headroom = 64;

/// A context that runs `entry(arg, message)` on `stack` when first switched
/// to; its switches carry `Message`s. The first frame goes below
/// `stack.top`, so what was carved above it stays; on Windows `stack`
/// learns what was committed for it. The stack is the context's until
/// `deinit`: nothing else may run on it.
pub fn init(stack: *Stack, comptime Arg: type, comptime Message: type, entry: Entry(Arg, Message), arg: Arg) error{StackTooSmall}!Context {
    const top = stack.top - headroom;
    try stack.reach(top - native.first_frame);
    // aegis: internal: the headroom inside the stack, committed by `reach`
    const above: [*]u8 = @ptrFromInt(top);
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
/// and not yet run, or one that switched away. Every switch to a context
/// carries the `Message` its `init` named.
///
/// Inline, so a switch costs what the code around it holds in registers,
/// not every register a call keeps: a call and its return, to and from
/// different contexts, also cost the return predictor a miss each way,
/// four times the switch itself.
pub inline fn switchTo(from: *Context, to: *Context, comptime Message: type, message: ?Message) ?Message {
    comptime checkMessage(Message);
    if (sanitizer.enabled) {
        from.fiber = sanitizer.current();
        sanitizer.switchTo(to.fiber);
    }
    const slot = insideSlot();
    from.inside = slot.*;
    slot.* = to.inside;
    const t: native.Transfer = if (is_windows)
        .{ .from = &from.registers, .to = &to.registers, .message = message, .bounds = teb.exchange(&from.bounds, &to.bounds) }
    else
        .{ .from = &from.registers, .to = &to.registers, .message = message };
    // aegis: boundary: the swap hands back the word the switch that resumed `from` sent, which every switch to `from` sends as a `Message`
    return @ptrCast(@alignCast(native.swap(&t).message));
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
