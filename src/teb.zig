//! Windows: the stack fields of the thread information block, which a switch
//! keeps on the running stack. The system grows a stack through its guard
//! page only inside these bounds, raises a stack overflow at their bottom,
//! and its unwinder and stack probes check against them.
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

/// `DeallocationStack`'s offset in a 64-bit thread information block, on
/// x86_64 and aarch64 alike; std does not name the field.
const deallocation_offset = 0x1478;

fn deallocationField() *usize {
    return @ptrFromInt(@intFromPtr(windows.teb()) + deallocation_offset); // safe: a field of the running thread's information block
}

pub fn get() Bounds {
    const teb = windows.teb();
    return .{
        .base = @intFromPtr(teb.NtTib.StackBase), // safe: an address, kept as a number
        .limit = @intFromPtr(teb.NtTib.StackLimit), // safe: an address, kept as a number
        .deallocation = deallocationField().*,
    };
}

pub fn set(b: Bounds) void {
    const teb = windows.teb();
    teb.NtTib.StackBase = @ptrFromInt(b.base); // safe: the bounds of a stack this thread runs on next
    teb.NtTib.StackLimit = @ptrFromInt(b.limit); // safe: as above
    deallocationField().* = b.deallocation;
}
