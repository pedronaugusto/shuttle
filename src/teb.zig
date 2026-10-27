//! Windows: the stack fields of the thread information block, which a switch
//! keeps on the running stack. The system grows a stack through its guard
//! page only inside these bounds, raises a stack overflow at their bottom,
//! and its unwinder and stack probes check against them.
//!
//! The switch's assembly exchanges them (`Exchange`) as it moves the stack
//! pointer, with nothing between: code that ran on one stack under another's
//! bounds, as a call in Zig between the two did, failed the moment it first
//! touched its stack's guard page, which the system then did not grow but
//! raised as a guard page violation no handler took.
const std = @import("std");
const windows = std.os.windows;

pub const Bounds = extern struct {
    /// One past the highest byte (`StackBase`).
    base: usize,
    /// The lowest committed byte (`StackLimit`).
    limit: usize,
    /// The lowest reserved byte (`DeallocationStack`).
    deallocation: usize,
};

/// What a switch exchanges: the running thread's information block, where
/// its bounds are saved for the context it leaves, and those it loads for
/// the context it resumes. Read by the assembly at these offsets.
pub const Exchange = extern struct {
    block: usize,
    save: *Bounds,
    load: *const Bounds,
};

/// The fields' offsets in a 64-bit thread information block, on x86_64 and
/// aarch64 alike: `StackBase` and `StackLimit` in its `NtTib`, and
/// `DeallocationStack`, which std does not name.
pub const base_offset = 8;
pub const limit_offset = 16;
pub const deallocation_offset = 0x1478;

comptime {
    if (@offsetOf(Bounds, "limit") != 8 or @offsetOf(Bounds, "deallocation") != 16 or @offsetOf(Exchange, "save") != 8 or @offsetOf(Exchange, "load") != 16)
        @compileError("the switch reads these offsets");
    if (@offsetOf(windows.TEB, "NtTib") + @offsetOf(windows.NT_TIB, "StackBase") != base_offset or
        @offsetOf(windows.TEB, "NtTib") + @offsetOf(windows.NT_TIB, "StackLimit") != limit_offset)
        @compileError("the switch writes these offsets");
}

/// The running thread's, for a switch to exchange.
pub fn exchange(save: *Bounds, load: *const Bounds) Exchange {
    return .{ .block = @intFromPtr(windows.teb()), .save = save, .load = load };
}

fn deallocationField() *usize {
    // aegis: boundary: a field of the running thread's information block
    return @ptrFromInt(@intFromPtr(windows.teb()) + deallocation_offset);
}

pub fn get() Bounds {
    const teb = windows.teb();
    return .{
        .base = @intFromPtr(teb.NtTib.StackBase), // safe: an address, kept as a number
        .limit = @intFromPtr(teb.NtTib.StackLimit), // safe: an address, kept as a number
        .deallocation = deallocationField().*,
    };
}
