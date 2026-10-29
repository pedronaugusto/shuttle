//! The switch on x86_64, for the System V ABI and for Windows x64.
//!
//! The assembly saves what the compiler cannot: the stack pointer, the frame
//! pointer, where to resume, and the floating-point control state (MXCSR and
//! the x87 control word, callee-saved under both ABIs). Every other register
//! is declared clobbered, so the compiler saves the callee-saved ones in the
//! switching function's own frame: rbx and r12-r15 under System V, and on
//! Windows also rdi, rsi and xmm6-xmm15.
//!
//! The vector registers are named `xmm`, `ymm` and `zmm`: LLVM takes a clobber
//! only by a name the CPU has, so `zmm` alone means nothing without AVX-512,
//! and the values the compiler kept in `xmm` registers did not survive a
//! switch (std's `Io.fiber.contextSwitch` names only `zmm`).
//!
//! Where a switch jumps, to the resume address or a new context's
//! trampoline, an `endbr64` marks the target as one an indirect jump may
//! reach: CET's indirect branch tracking refuses any other. It is a no-op
//! on a processor without CET, or with tracking off.
//!
//! On Linux a context runs on a CET shadow stack of its own where the
//! thread has one (`shadow_stacks`).
const builtin = @import("builtin");
const std = @import("std");
const teb = @import("../teb.zig");

const is_windows = builtin.os.tag == .windows;

/// The floating-point control state a context keeps: MXCSR, then the x87
/// control word. One word, so a switch compares the two at once.
pub const Control = extern struct {
    mxcsr: u32,
    x87: u16,
    /// Zero, so that equal states compare equal.
    pad: u16 = 0,
};

/// A suspended context's registers.
pub const Registers = extern struct {
    sp: usize,
    fp: usize,
    pc: usize,
    control: Control,
    /// Linux: the shadow stack pointer, zero where the thread has no shadow
    /// stack.
    ssp: usize,
};

/// Whether contexts run on shadow stacks of their own where the thread has
/// one: on Linux, whose threads have one when the program asks
/// (`arch_prctl`), as glibc does for a program built for them. A call
/// pushes its return address there too, and a return whose address differs
/// faults, so each context's calls need their own: a stack made on such a
/// thread gets one (`Shadow`). The switch saves the shadow stack pointer
/// of the context it leaves, which leaves a restore token on that shadow
/// stack, and restores the next one's from its token (RSTORSSP,
/// SAVEPREVSSP). Elsewhere a thread's shadow stack, where there is one, is
/// the system's to switch (Windows switches it only for its fibers), and
/// shuttle's contexts cannot run with one. Zig's own x86_64 backend, which
/// builds Debug by default, encodes none of these instructions: there they
/// take the LLVM backend (`-fllvm`, or any release mode).
pub const shadow_stacks = builtin.os.tag == .linux and builtin.zig_backend == .stage2_llvm;

/// A stack's shadow stack: one past its highest byte, and the shadow stack
/// pointer the next context made on the stack starts at, which has a
/// restore token just below it. Zero for none.
pub const Shadow = if (shadow_stacks) struct { end: usize = 0, ssp: usize = 0 } else struct {};

/// A shadow stack for a stack of `usable` bytes (whole pages) when the
/// running thread has one, else none: as large as the stack, which no chain
/// of calls on it outgrows, committed only as calls reach it, and with a
/// restore token in its top word for a switch to take (`map_shadow_stack`,
/// Linux 6.6 and later). It is one more mapping.
pub fn shadowFor(usable: usize) error{SystemResources}!Shadow {
    if (!shadow_stacks or shadowStackPointer() == 0) return .{};
    const linux = std.os.linux;
    // include/uapi/asm-generic/mman-common.h
    const shadow_stack_set_token = 1 << 0;
    const rc = linux.syscall3(.map_shadow_stack, 0, usable, shadow_stack_set_token);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    return .{ .end = rc + usable, .ssp = rc + usable };
}

/// Releases a shadow stack `shadowFor` made for a stack of `usable` bytes.
pub fn releaseShadow(shadow: Shadow, usable: usize) void {
    if (!shadow_stacks or shadow.end == 0) return;
    // Unmapping a whole mapping this process made cannot fail.
    // aegis: boundary: munmap takes back the mapping map_shadow_stack returned as a number
    _ = std.os.linux.munmap(@ptrFromInt(shadow.end - usable), usable);
}

/// The running thread's shadow stack pointer, or zero when it has no shadow
/// stack: RDSSP is then a no-op, and leaves the zero.
pub fn shadowStackPointer() usize {
    if (!shadow_stacks) return 0;
    // aegis: boundary: reads the shadow stack pointer, which only the processor holds
    return asm volatile ("rdsspq %[ssp]"
        : [ssp] "=r" (-> usize),
        : [zero] "0" (@as(usize, 0)),
    );
}

/// What a switch hands from one side to the other: where to save, what to
/// load, and the message; on Windows also the stack bounds it exchanges.
/// Read by the assembly at these offsets.
pub const Transfer = if (is_windows) extern struct {
    from: *Registers,
    to: *Registers,
    message: ?*anyopaque,
    bounds: teb.Exchange,
} else extern struct {
    from: *Registers,
    to: *Registers,
    message: ?*anyopaque,
};

comptime {
    if (@offsetOf(Registers, "control") != 24 or @offsetOf(Registers, "ssp") != 32 or @offsetOf(Transfer, "message") != 16) @compileError("the switch reads these offsets");
    if (is_windows and @offsetOf(Transfer, "bounds") != 24) @compileError("the switch reads these offsets");
}

/// The control state of the running code.
pub fn control() Control {
    var c: Control = .{ .mxcsr = 0, .x87 = 0 };
    // aegis: boundary: reads MXCSR and the x87 control word, which a context saves and restores
    asm volatile (
        \\ stmxcsr (%%rax)
        \\ fnstcw 4(%%rax)
        :
        : [c] "{rax}" (&c),
        : .{ .memory = true });
    return c;
}

/// Saves the running context into `t.from`, loads `t.to` and runs it.
/// Returns the transfer that resumed this context later. The transfer's
/// address goes in the register a new context's entry takes its second
/// argument in (rsi, or rdx on Windows), so the trampoline need not move it.
pub inline fn swap(t: *const Transfer) *const Transfer {
    // aegis: boundary: the switch itself: saves the running context's registers into `t.from` and loads `t.to`'s, as the Windows x64 convention has them
    if (is_windows) return asm volatile (body("rdx")
        : [received] "={rdx}" (-> *const Transfer),
        : [sent] "0" (t),
        : clobbers(.rdx));
    // aegis: boundary: the switch itself, as the System V convention has the registers
    return asm volatile (body("rsi")
        : [received] "={rsi}" (-> *const Transfer),
        : [sent] "0" (t),
        : clobbers(.rsi));
}

/// The transfer is in `sent`; rax and rcx hold the two register sets, r8
/// the resume address. MXCSR and the x87 control word are written only when
/// the context switched to keeps different ones: loading them costs more
/// than the comparison. On Linux the shadow stack pointer is saved, and the
/// next context's restored when it has one (`shadow_switch`). On Windows
/// the stack bounds are exchanged last, just before the stack pointer moves
/// (`teb`). The register is spelt out,
/// not an operand, because Zig's own x86_64 backend reads no operand inside
/// a memory reference.
fn body(comptime sent: []const u8) []const u8 {
    return "movq 0(%%" ++ sent ++ "), %%rax\n" ++
        "movq 8(%%" ++ sent ++ "), %%rcx\n" ++
        \\ leaq 0f(%%rip), %%r8
        \\ movq %%rsp, 0(%%rax)
        \\ movq %%rbp, 8(%%rax)
        \\ movq %%r8, 16(%%rax)
        \\ stmxcsr 24(%%rax)
        \\ fnstcw 28(%%rax)
        \\ movq 24(%%rax), %%r9
        \\ cmpq 24(%%rcx), %%r9
        \\ je 1f
        \\ ldmxcsr 24(%%rcx)
        \\ fldcw 28(%%rcx)
        \\ 1:
        \\
    ++ (if (shadow_stacks) shadow_switch else "") ++ (if (is_windows) exchange(sent) else "") ++
        \\ movq 0(%%rcx), %%rsp
        \\ movq 8(%%rcx), %%rbp
        \\ jmpq *16(%%rcx)
        \\ 0:
        \\ endbr64
    ;
}

/// Linux: the shadow stack pointer saved into `from` (zero without a shadow
/// stack), and when `to` has one, its restore token taken: SAVEPREVSSP
/// then leaves one on the shadow stack left, just below the pointer saved.
const shadow_switch =
    \\ xorl %%r9d, %%r9d
    \\ rdsspq %%r9
    \\ movq %%r9, 32(%%rax)
    \\ movq 32(%%rcx), %%r9
    \\ testq %%r9, %%r9
    \\ jz 2f
    \\ rstorssp -8(%%r9)
    \\ saveprevssp
    \\ 2:
    \\
;

/// Windows: the thread information block's stack fields saved into the
/// transfer's `bounds.save` and loaded from its `bounds.load`, in r9 to r11.
fn exchange(comptime sent: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\ movq 24(%%{0s}), %%r10
        \\ movq 32(%%{0s}), %%r11
        \\ movq {1d}(%%r10), %%r9
        \\ movq %%r9, 0(%%r11)
        \\ movq {2d}(%%r10), %%r9
        \\ movq %%r9, 8(%%r11)
        \\ movq {3d}(%%r10), %%r9
        \\ movq %%r9, 16(%%r11)
        \\ movq 40(%%{0s}), %%r11
        \\ movq 0(%%r11), %%r9
        \\ movq %%r9, {1d}(%%r10)
        \\ movq 8(%%r11), %%r9
        \\ movq %%r9, {2d}(%%r10)
        \\ movq 16(%%r11), %%r9
        \\ movq %%r9, {3d}(%%r10)
        \\
    , .{ sent, teb.base_offset, teb.limit_offset, teb.deallocation_offset });
}

const Register = enum { rsi, rdx };

/// Every register but the stack and frame pointers and the transfer's own,
/// which is the output: an input register also named as a clobber made LLVM
/// drop the move into it in optimized builds.
fn clobbers(comptime kept: Register) @import("std").lang.assembly.Clobbers {
    return .{
        .rax = true,
        .rcx = true,
        .rdx = kept != .rdx,
        .rbx = true,
        .rsi = kept != .rsi,
        .rdi = true,
        .r8 = true,
        .r9 = true,
        .r10 = true,
        .r11 = true,
        .r12 = true,
        .r13 = true,
        .r14 = true,
        .r15 = true,
        .mm0 = true,
        .mm1 = true,
        .mm2 = true,
        .mm3 = true,
        .mm4 = true,
        .mm5 = true,
        .mm6 = true,
        .mm7 = true,
        .st0 = true,
        .st1 = true,
        .st2 = true,
        .st3 = true,
        .st4 = true,
        .st5 = true,
        .st6 = true,
        .st7 = true,
        .xmm0 = true,
        .xmm1 = true,
        .xmm2 = true,
        .xmm3 = true,
        .xmm4 = true,
        .xmm5 = true,
        .xmm6 = true,
        .xmm7 = true,
        .xmm8 = true,
        .xmm9 = true,
        .xmm10 = true,
        .xmm11 = true,
        .xmm12 = true,
        .xmm13 = true,
        .xmm14 = true,
        .xmm15 = true,
        .ymm0 = true,
        .ymm1 = true,
        .ymm2 = true,
        .ymm3 = true,
        .ymm4 = true,
        .ymm5 = true,
        .ymm6 = true,
        .ymm7 = true,
        .ymm8 = true,
        .ymm9 = true,
        .ymm10 = true,
        .ymm11 = true,
        .ymm12 = true,
        .ymm13 = true,
        .ymm14 = true,
        .ymm15 = true,
        .zmm0 = true,
        .zmm1 = true,
        .zmm2 = true,
        .zmm3 = true,
        .zmm4 = true,
        .zmm5 = true,
        .zmm6 = true,
        .zmm7 = true,
        .zmm8 = true,
        .zmm9 = true,
        .zmm10 = true,
        .zmm11 = true,
        .zmm12 = true,
        .zmm13 = true,
        .zmm14 = true,
        .zmm15 = true,
        .zmm16 = true,
        .zmm17 = true,
        .zmm18 = true,
        .zmm19 = true,
        .zmm20 = true,
        .zmm21 = true,
        .zmm22 = true,
        .zmm23 = true,
        .zmm24 = true,
        .zmm25 = true,
        .zmm26 = true,
        .zmm27 = true,
        .zmm28 = true,
        .zmm29 = true,
        .zmm30 = true,
        .zmm31 = true,
        .fpsr = true,
        .fpcr = true,
        .mxcsr = true,
        .rflags = true,
        .dirflag = true,
        .memory = true,
    };
}

/// Bytes the first frame takes below the top it is laid out at.
pub const first_frame = 48;

/// The registers that start `entry(arg, message)` on a stack whose first
/// frame goes below `top` (16-aligned), and that frame.
///
/// On `shadow`, the stack's shadow stack, where it has one, the context
/// starts at the restore token below its pointer.
///
/// Outside Windows the trampoline calls the entry, so the trampoline is the
/// outermost frame and its unwind table says nothing called it; the frame
/// is the argument, the entry and the end of the shadow stack (zero for
/// none). On Windows, whose unwinder reads no such table here, it jumps in
/// with a zero return address, which ends a walk; rsp is then 8 mod 16 as
/// after a call, with the 32 bytes of home space above the return address
/// the callee may write.
pub fn initial(top: usize, entry: usize, arg: usize, pc: usize, shadow: Shadow) Registers {
    const sp = if (is_windows) top - first_frame + 8 else top - 32;
    // aegis: internal: inside the stack, below its top
    const slots: [*]usize = @ptrFromInt(sp);
    if (is_windows) {
        slots[0] = 0;
        slots[1] = arg;
        slots[2] = entry;
    } else {
        slots[0] = arg;
        slots[1] = entry;
        slots[2] = if (shadow_stacks) shadow.end else 0;
    }
    return .{ .sp = sp, .fp = 0, .pc = pc, .control = control(), .ssp = if (shadow_stacks) shadow.ssp else 0 };
}

/// Linux: on a shadow stack a context ran on before, the restore token the
/// new context took lies where that one last switched away, below the end.
/// The entries above it are popped (INCSSP, at most 255 at a time), so each
/// context's shadow stack starts at its end, and a stack reused again and
/// again never runs out of it. The end is the first frame's third word,
/// zero for none; rax and rcx are free, rsi holds the transfer.
const shadow_start =
    \\ movq 16(%%rsp), %%rax
    \\ testq %%rax, %%rax
    \\ jz 2f
    \\ rdsspq %%rcx
    \\ subq %%rcx, %%rax
    \\ shrq $3, %%rax
    \\ jz 2f
    \\ 1:
    \\ movl $255, %%ecx
    \\ cmpq %%rcx, %%rax
    \\ cmovbq %%rax, %%rcx
    \\ incsspq %%rcx
    \\ subq %%rcx, %%rax
    \\ jnz 1b
    \\ 2:
    \\
;

/// The first instructions of a context.
pub fn trampoline() callconv(.naked) noreturn {
    // aegis: boundary: the first frame's entry: moves the entry and argument `initial` laid in into the Windows x64 argument registers
    if (is_windows) asm volatile (
        \\ endbr64
        \\ movq 8(%%rsp), %%rcx
        \\ movq 16(%%rdx), %%rdx
        \\ jmpq *16(%%rsp)
        // aegis: boundary: as above, into the System V argument registers
    ) else asm volatile (
        \\ .cfi_undefined %%rip
        \\ endbr64
        \\
    ++ (if (shadow_stacks) shadow_start else "") ++
        \\ movq 0(%%rsp), %%rdi
        \\ movq 16(%%rsi), %%rsi
        \\ callq *8(%%rsp)
        \\ ud2
    );
}

/// The frame record a walk follows: [fp] the caller's frame pointer,
/// [fp + 8] the return address.
pub const record_caller = 0;
pub const record_return = 8;

/// A return address as a frame record holds it: the address itself.
pub fn returnAddress(saved: usize) usize {
    return saved;
}
