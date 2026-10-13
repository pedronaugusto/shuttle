//! Naming a stack overflow. A context that runs off its stack touches the
//! guard below it and faults; std's handler then says "Segmentation fault at
//! address" and nothing of why. This handler says it was a stack overflow,
//! and in a coroutine whose stack it was, before std's handler does the
//! rest.
//!
//! It is installed in the program's root, where std's segfault handler is
//! on (by default in Debug and ReleaseSafe) and runs on the alternate signal
//! stack std gives each thread (`std_options.signal_stack_size`, on by
//! default): a handler cannot run on the stack that overflowed.
//!
//! ```
//! pub const debug = struct {
//!     pub const handleSegfault = shuttle.handleSegfault;
//! };
//! ```
//!
//! On Windows a switch keeps the thread information block's bounds on the
//! running stack, so the system raises its own stack overflow exception,
//! which std names.
const builtin = @import("builtin");
const std = @import("std");
const coroutine = @import("coroutine.zig");
const Stack = @import("Stack.zig");
const trace = @import("trace.zig");

/// What a fault at `address` is, as far as the stacks tell.
pub const Diagnosis = union(enum) {
    /// In the guard of the coroutine running on this thread.
    coroutine: Stack,
    /// Just around the stack pointer of the code that faulted: a frame that
    /// ran past the end of its stack, whichever stack that was.
    near_stack_pointer: usize,
    /// Nothing that says stack overflow.
    other,
};

/// The DWARF numbers of the stack pointer, the frame pointer and the
/// program counter, by which std's register context is read on every
/// architecture.
const sp_register: u16 = switch (builtin.cpu.arch) {
    .x86_64 => 7,
    .aarch64 => 31,
    .riscv64 => 2,
    else => 0,
};
const fp_register: u16 = switch (builtin.cpu.arch) {
    .x86_64 => 6,
    .aarch64 => 29,
    .riscv64 => 8,
    else => 0,
};
const pc_register: u16 = switch (builtin.cpu.arch) {
    .x86_64 => 16,
    .aarch64 => 32,
    else => 0,
};

pub fn diagnose(address: usize, context: ?std.debug.CpuContextPtr) Diagnosis {
    if (coroutine.running()) |c| if (c.stack().guards(address)) return .{ .coroutine = c.stack() };
    if (context) |ctx| if (register(ctx, sp_register)) |sp| {
        // A frame's own accesses lie just above the stack pointer, or within
        // a red zone just below it; nothing else of a program faults there.
        if (address +| 4096 >= sp and address < sp +| 256 * 1024) return .{ .near_stack_pointer = sp };
    };
    return .other;
}

fn register(ctx: std.debug.CpuContextPtr, number: u16) ?usize {
    if (@TypeOf(ctx) == noreturn or number == 0) return null;
    var copy = ctx.*;
    const bytes = copy.dwarfRegisterBytes(number) catch return null;
    if (bytes.len != @sizeOf(usize)) return null;
    return std.mem.readInt(usize, bytes[0..@sizeOf(usize)], builtin.cpu.arch.endian());
}

/// The segfault handler that names a stack overflow and ends the process
/// after printing the trace of the stack that overflowed, walked by its
/// frame records; any other fault goes on to std's handler. std's unwinder
/// is not used on an overflowed stack: on x86_64 macOS it walked one without
/// end.
pub fn handleSegfault(address: ?usize, name: []const u8, context: ?std.debug.CpuContextPtr) noreturn {
    if (address) |a| {
        const d = diagnose(a, context);
        describe(a, d);
        switch (d) {
            .coroutine => |s| traceOverflowed(s.bottom, s.end, context),
            // The stack's top is unknown: the walk ends at its first frame,
            // or where the chain breaks.
            .near_stack_pointer => |sp| traceOverflowed(sp, std.math.maxInt(usize), context),
            .other => std.debug.defaultHandleSegfault(address, name, context),
        }
        std.process.abort();
    }
    std.debug.defaultHandleSegfault(address, name, context);
}

/// The overflowed stack's frames, from where it faulted to its first.
fn traceOverflowed(low: usize, high: usize, context: ?std.debug.CpuContextPtr) void {
    const ctx = context orelse return;
    var addresses: [33]usize = undefined;
    var n: usize = 0;
    if (register(ctx, pc_register)) |pc| {
        // Printed as a return address is, one byte back: inside the faulting instruction's function still.
        addresses[0] = pc + 1;
        n = 1;
    }
    const fp = register(ctx, fp_register) orelse return;
    n += trace.walk(fp, low, high, addresses[n..]).len;
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.writeAll("stack trace of the stack that overflowed:\n") catch return;
    std.debug.writeStackTrace(&.{ .return_addresses = addresses[0..n], .skipped = if (n == addresses.len) .unknown else .none }, stderr) catch return;
}

fn describe(address: usize, d: Diagnosis) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    const w = stderr.writer;
    switch (d) {
        .coroutine => |s| w.print("shuttle: stack overflow in a coroutine: it touched 0x{x}, in the guard below its stack of {d} bytes (0x{x} to 0x{x}); give it a larger stack\n", .{ address, s.size().raw(), s.bottom, s.end }) catch return,
        .near_stack_pointer => |sp| w.print("shuttle: stack overflow: the fault at 0x{x} is beside the stack pointer, 0x{x}; the stack that ran out is too small for the code on it\n", .{ address, sp }) catch return,
        .other => {},
    }
}
