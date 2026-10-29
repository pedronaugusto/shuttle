//! Stack traces of a context, walked by frame pointer inside its own stack.
//!
//! std's unwinder is not used on a context's stack where frame records can
//! be followed instead: on aarch64 Darwin it restores a frame's saved
//! registers reading up from its frame pointer, and past a context's first
//! frame that read leaves the stack and faults (a crash there then hung on
//! the unwinder's own lock). The walk here reads only frame records inside
//! the bounds it is given, and ends at the first frame, whose caller is
//! zero. On Windows x64 frame pointers do not point at the saved frame
//! pointer (LLVM sets rbp anywhere in the frame there, as the unwind tables
//! say where), so the running code's trace is the system's unwinder's, which
//! a context's zero return address ends.
const builtin = @import("builtin");
const std = @import("std");
const native = @import("arch.zig").native;

/// Whether frame records can be followed: not where frame pointers are
/// omitted (`-fomit-frame-pointer`), nor on Windows x64.
pub const by_records = !builtin.omit_frame_pointer and !(builtin.os.tag == .windows and builtin.cpu.arch == .x86_64);

/// Whether a suspended context's trace can be walked: by its frame records.
pub const suspended_available = by_records;

/// The largest frame a walk steps over; a larger step is a broken chain.
pub const max_frame = 16 * 1024 * 1024;

/// The return addresses of the frames from the one whose frame pointer is
/// `fp`, innermost first, into `out`: while each frame record lies inside
/// `[low, high)`, up to a frame whose caller or return address is zero.
pub fn walk(start: usize, low: usize, high: usize, out: []usize) []usize {
    if (!by_records) return out[0..0];
    var fp = start;
    var n: usize = 0;
    while (n < out.len) {
        const record_low = fp +% @as(usize, @bitCast(@as(isize, @min(native.record_caller, native.record_return))));
        const record_high = record_low +% 2 * @sizeOf(usize);
        if (fp % @alignOf(usize) != 0 or record_low < low or record_high > high or record_high < record_low) break;
        const caller = load(fp, native.record_caller);
        const ra = native.returnAddress(load(fp, native.record_return));
        if (ra <= 1) break;
        out[n] = ra;
        n += 1;
        // The stack grows down: a caller's frame is above its callee's, and
        // not further than any frame is large.
        if (caller <= fp or caller - fp > max_frame) break;
        fp = caller;
    }
    return out[0..n];
}

fn load(fp: usize, comptime offset: comptime_int) usize {
    const at = fp +% @as(usize, @bitCast(@as(isize, offset)));
    // aegis: boundary: `walk` checked the record lies inside the stack
    return @as(*const usize, @ptrFromInt(at)).*;
}

/// The running code's frame pointer.
pub inline fn framePointer() usize {
    return @frameAddress();
}

/// The running code's stack pointer: which stack the code runs on, also
/// where frame pointers are omitted and the frame pointer register holds
/// anything.
pub inline fn stackPointer() usize {
    return switch (builtin.cpu.arch) {
        // aegis: boundary: reads the stack pointer register
        .x86_64 => asm volatile ("movq %%rsp, %[sp]"
            : [sp] "=r" (-> usize),
        ),
        // aegis: boundary: reads the stack pointer register
        .aarch64 => asm volatile ("mov %[sp], sp"
            : [sp] "=r" (-> usize),
        ),
        // aegis: boundary: reads the stack pointer register
        .riscv64 => asm volatile ("mv %[sp], sp"
            : [sp] "=r" (-> usize),
        ),
        else => @frameAddress(),
    };
}

/// The running code's return addresses, innermost first, into `out`, from
/// the frame that returns to `first` (the caller's caller of this function,
/// when it is `@returnAddress()` of that caller), to the stack's first frame
/// inside `[low, high)`.
pub noinline fn here(first: usize, low: usize, high: usize, out: []usize) []usize {
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        return std.debug.captureCurrentStackTrace(.{ .first_address = first }, out).return_addresses;
    }
    const walked = walk(@frameAddress(), low, high, out);
    const from = std.mem.findScalar(usize, walked, first) orelse return walked;
    @memmove(out[0 .. walked.len - from], walked[from..]);
    return out[0 .. walked.len - from];
}
