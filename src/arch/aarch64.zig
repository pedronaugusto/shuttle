//! The switch on aarch64, for AAPCS64 (Linux and the BSDs), Apple's variant
//! and Windows.
//!
//! The assembly saves the stack pointer, the frame pointer (x29), where to
//! resume, the link register (x30) and FPCR, the floating-point control
//! register. Every other register is declared clobbered, so the compiler
//! saves the callee-saved ones in the switching function's own frame: x19 to
//! x28 and d8 to d15 (the low halves of v8 to v15).
//!
//! The link register is kept by the assembly itself, not left to a clobber:
//! LLVM takes the clobber only as `lr`, and std's `Io.fiber.contextSwitch`
//! names it `x30`, which LLVM drops. Optimized code then kept a pointer in
//! x30 across a switch and found the other context's there after it. x18 is
//! the platform register on Apple targets and Windows, which LLVM never
//! allocates there and ignores in a clobber list; on Linux it is an ordinary
//! temporary and the clobber counts.
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Whether x18 is the platform register here, which LLVM never allocates and
/// refuses in a clobber list: Apple targets, Windows, Android and Fuchsia.
pub const reserves_x18 = builtin.os.tag.isDarwin() or is_windows or builtin.os.tag == .fuchsia or builtin.abi.isAndroid() or
    @import("std").Target.aarch64.featureSetHas(builtin.cpu.features, .reserve_x18);

/// The floating-point control state a context keeps: FPCR (rounding mode,
/// flush-to-zero, default NaN and the trap enables).
pub const Control = extern struct { fpcr: u64 };

/// A suspended context's registers.
pub const Registers = extern struct {
    sp: usize,
    fp: usize,
    pc: usize,
    lr: usize,
    control: Control,
};

/// What a switch hands from one side to the other.
pub const Transfer = extern struct {
    from: *Registers,
    to: *Registers,
    message: ?*anyopaque,
};

comptime {
    if (@offsetOf(Registers, "lr") != 24 or @offsetOf(Registers, "control") != 32 or @offsetOf(Transfer, "message") != 16) @compileError("the switch reads these offsets");
}

pub fn control() Control {
    // aegis: boundary: reads the floating-point control register, which a context saves and restores
    return .{ .fpcr = asm volatile ("mrs %[r], fpcr"
        : [r] "=r" (-> u64),
    ) };
}

/// Saves the running context into `t.from`, loads `t.to` and runs it.
/// Returns the transfer that resumed this context later; it travels in x1,
/// where a new context's entry takes its second argument.
pub inline fn swap(t: *const Transfer) *const Transfer {
    // aegis: boundary: the switch itself: saves the running context's registers into `t.from` and loads `t.to`'s, as AAPCS64 has them
    return asm volatile (
        \\ ldp x0, x2, [x1]
        \\ mov x3, sp
        \\ adr x4, 0f
        \\ stp x3, x29, [x0]
        \\ stp x4, x30, [x0, #16]
        \\ mrs x5, fpcr
        \\ str x5, [x0, #32]
        \\ ldr x6, [x2, #32]
        \\ cmp x5, x6
        \\ b.eq 1f
        \\ msr fpcr, x6
        \\ 1:
        \\ ldp x3, x29, [x2]
        \\ ldp x4, x30, [x2, #16]
        \\ mov sp, x3
        \\ br x4
        \\ 0:
        : [received] "={x1}" (-> *const Transfer),
        : [sent] "0" (t),
        : clobbers);
}

/// Every register the code on the other side may change, but the stack and
/// frame pointers and the transfer's own, which is the output: an input
/// register also named as a clobber made LLVM drop the move into it in
/// optimized builds.
const clobbers: @import("std").lang.assembly.Clobbers = .{
    .x0 = true,
    .x2 = true,
    .x3 = true,
    .x4 = true,
    .x5 = true,
    .x6 = true,
    .x7 = true,
    .x8 = true,
    .x9 = true,
    .x10 = true,
    .x11 = true,
    .x12 = true,
    .x13 = true,
    .x14 = true,
    .x15 = true,
    .x16 = true,
    .x17 = true,
    .x18 = !reserves_x18,
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
    .lr = true,
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
    .z0 = true,
    .z1 = true,
    .z2 = true,
    .z3 = true,
    .z4 = true,
    .z5 = true,
    .z6 = true,
    .z7 = true,
    .z8 = true,
    .z9 = true,
    .z10 = true,
    .z11 = true,
    .z12 = true,
    .z13 = true,
    .z14 = true,
    .z15 = true,
    .z16 = true,
    .z17 = true,
    .z18 = true,
    .z19 = true,
    .z20 = true,
    .z21 = true,
    .z22 = true,
    .z23 = true,
    .z24 = true,
    .z25 = true,
    .z26 = true,
    .z27 = true,
    .z28 = true,
    .z29 = true,
    .z30 = true,
    .z31 = true,
    .p0 = true,
    .p1 = true,
    .p2 = true,
    .p3 = true,
    .p4 = true,
    .p5 = true,
    .p6 = true,
    .p7 = true,
    .p8 = true,
    .p9 = true,
    .p10 = true,
    .p11 = true,
    .p12 = true,
    .p13 = true,
    .p14 = true,
    .p15 = true,
    .ffr = true,
    .fpcr = true,
    .fpsr = true,
    .nzcv = true,
    .memory = true,
};

/// Bytes the first frame takes below the top it is laid out at.
pub const first_frame = 16;

/// The registers that start `entry(arg, message)` with its first frame below
/// `top` (16-aligned): [sp] the argument, [sp + 8] the entry. x29 and x30 are
/// zero. Outside Windows the trampoline calls the entry, and its unwind table
/// says nothing called it; on Windows it branches in with x30 zero, which
/// ends a walk there.
pub fn initial(top: usize, entry: usize, arg: usize, pc: usize) Registers {
    const sp = top - first_frame;
    // aegis: internal: inside the stack, below its top
    const slots: [*]usize = @ptrFromInt(sp);
    slots[0] = arg;
    slots[1] = entry;
    return .{ .sp = sp, .fp = 0, .pc = pc, .lr = 0, .control = control() };
}

pub fn trampoline() callconv(.naked) noreturn {
    // aegis: boundary: the first frame's entry: moves the entry and argument `initial` laid in into AAPCS64's argument registers
    if (is_windows) asm volatile (
        \\ ldp x0, x9, [sp]
        \\ ldr x1, [x1, #16]
        \\ br x9
        // aegis: boundary: as above, outside Windows
    ) else asm volatile (
        \\ .cfi_undefined lr
        \\ ldp x0, x9, [sp]
        \\ ldr x1, [x1, #16]
        \\ blr x9
        \\ brk #1
    );
}

/// The frame record a walk follows: [fp] the caller's frame pointer,
/// [fp + 8] the return address.
pub const record_caller = 0;
pub const record_return = 8;
