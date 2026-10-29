//! The switch on riscv64 (LP64 and LP64D).
//!
//! The assembly saves the stack pointer, the frame pointer (s0), where to
//! resume, the return address (ra) and, with the F extension, fcsr (the
//! rounding mode and the accrued exception flags). Every other register is
//! declared clobbered, so the compiler saves the callee-saved ones in the
//! switching function's own frame: s1 to s11 and fs0 to fs11. gp and tp are
//! the global and thread pointers, which no code allocates and which a
//! context that moves to another thread must find that thread's in.
const builtin = @import("builtin");
const std = @import("std");

const has_float = std.Target.riscv.featureSetHas(builtin.cpu.features, .f);

/// The floating-point control state a context keeps: fcsr, or nothing
/// without the F extension.
pub const Control = extern struct { fcsr: u64 };

pub const Registers = extern struct {
    sp: usize,
    fp: usize,
    pc: usize,
    ra: usize,
    control: Control,
};

pub const Transfer = extern struct {
    from: *Registers,
    to: *Registers,
    message: ?*anyopaque,
};

comptime {
    if (@offsetOf(Registers, "ra") != 24 or @offsetOf(Registers, "control") != 32 or @offsetOf(Transfer, "message") != 16) @compileError("the switch reads these offsets");
}

pub fn control() Control {
    if (!has_float) return .{ .fcsr = 0 };
    // aegis: boundary: reads the floating-point control and status register, which a context saves and restores
    return .{ .fcsr = asm volatile ("frcsr %[r]"
        : [r] "=r" (-> u64),
    ) };
}

const save_control = if (has_float)
    \\ frcsr a4
    \\ sd a4, 32(a0)
    \\ ld a5, 32(a2)
    \\ beq a4, a5, 1f
    \\ fscsr a5
    \\ 1:
    \\
else
    "";

/// Saves the running context into `t.from`, loads `t.to` and runs it.
/// Returns the transfer that resumed this context later; it travels in a1,
/// where a new context's entry takes its second argument.
pub inline fn swap(t: *const Transfer) *const Transfer {
    // aegis: boundary: the switch itself: saves the running context's registers into `t.from` and loads `t.to`'s, as the RISC-V calling convention has them
    return asm volatile (
        \\ ld a0, 0(a1)
        \\ ld a2, 8(a1)
        \\ lla a3, 0f
        \\ sd sp, 0(a0)
        \\ sd s0, 8(a0)
        \\ sd a3, 16(a0)
        \\ sd ra, 24(a0)
        \\
    ++ save_control ++
        \\ ld sp, 0(a2)
        \\ ld s0, 8(a2)
        \\ ld ra, 24(a2)
        \\ ld a3, 16(a2)
        \\ jr a3
        \\ 0:
        : [received] "={a1}" (-> *const Transfer),
        : [sent] "0" (t),
        : clobbers);
}

/// Every register the code on the other side may change, but the stack and
/// frame pointers and the transfer's own, which is the output: an input
/// register also named as a clobber made LLVM drop the move into it in
/// optimized builds.
const clobbers: @import("std").lang.assembly.Clobbers = .{
    .x1 = true,
    .x5 = true,
    .x6 = true,
    .x7 = true,
    .x9 = true,
    .x10 = true,
    .x12 = true,
    .x13 = true,
    .x14 = true,
    .x15 = true,
    .x16 = true,
    .x17 = true,
    .x18 = true,
    .x19 = true,
    .x20 = true,
    .x21 = true,
    .x22 = true,
    .x23 = true,
    .x24 = true,
    .x25 = true,
    .x26 = true,
    .x27 = true,
    .x28 = true,
    .x29 = true,
    .x30 = true,
    .x31 = true,
    .f0 = true,
    .f1 = true,
    .f2 = true,
    .f3 = true,
    .f4 = true,
    .f5 = true,
    .f6 = true,
    .f7 = true,
    .f8 = true,
    .f9 = true,
    .f10 = true,
    .f11 = true,
    .f12 = true,
    .f13 = true,
    .f14 = true,
    .f15 = true,
    .f16 = true,
    .f17 = true,
    .f18 = true,
    .f19 = true,
    .f20 = true,
    .f21 = true,
    .f22 = true,
    .f23 = true,
    .f24 = true,
    .f25 = true,
    .f26 = true,
    .f27 = true,
    .f28 = true,
    .f29 = true,
    .f30 = true,
    .f31 = true,
    .v0 = true,
    .v1 = true,
    .v2 = true,
    .v3 = true,
    .v4 = true,
    .v5 = true,
    .v6 = true,
    .v7 = true,
    .v8 = true,
    .v9 = true,
    .v10 = true,
    .v11 = true,
    .v12 = true,
    .v13 = true,
    .v14 = true,
    .v15 = true,
    .v16 = true,
    .v17 = true,
    .v18 = true,
    .v19 = true,
    .v20 = true,
    .v21 = true,
    .v22 = true,
    .v23 = true,
    .v24 = true,
    .v25 = true,
    .v26 = true,
    .v27 = true,
    .v28 = true,
    .v29 = true,
    .v30 = true,
    .v31 = true,
    .vtype = true,
    .vl = true,
    .vxsat = true,
    .vxrm = true,
    .vcsr = true,
    .fflags = true,
    .frm = true,
    .memory = true,
};

pub const first_frame = 16;

/// The registers that start `entry(arg, message)` with its first frame below
/// `top` (16-aligned): [sp] the argument, [sp + 8] the entry; s0 and ra zero.
/// The trampoline calls the entry, and its unwind table says nothing called
/// it.
pub fn initial(top: usize, entry: usize, arg: usize, pc: usize) Registers {
    const sp = top - first_frame;
    // aegis: internal: inside the stack, below its top
    const slots: [*]usize = @ptrFromInt(sp);
    slots[0] = arg;
    slots[1] = entry;
    return .{ .sp = sp, .fp = 0, .pc = pc, .ra = 0, .control = control() };
}

pub fn trampoline() callconv(.naked) noreturn {
    // aegis: boundary: the first frame's entry: moves the entry and argument `initial` laid in into the calling convention's argument registers
    asm volatile (
        \\ .cfi_undefined ra
        \\ ld a0, 0(sp)
        \\ ld t0, 8(sp)
        \\ ld a1, 16(a1)
        \\ jalr t0
        \\ unimp
    );
}

/// The frame record a walk follows, relative to s0, which points just above
/// it: [s0 - 16] the caller's s0, [s0 - 8] the return address.
pub const record_caller = -16;
pub const record_return = -8;

/// A return address as a frame record holds it: the address itself.
pub fn returnAddress(saved: usize) usize {
    return saved;
}
