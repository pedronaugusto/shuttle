//! The switch keeps what a call keeps, register class by register class.
//!
//! Each class is proven the same way. The test's own assembly loads a
//! pattern into every register of the class that the calling convention
//! says a call keeps, then calls a function that switches to a context,
//! and reads the registers back once the call returns. That context
//! overwrites every register it can (general, vector and floating-point
//! control alike) before it switches back. A switch that failed to keep one
//! leaves the context's value, not the pattern. The assembly holds the
//! values itself, so the proof does not hang on where a compiler happens to
//! keep its own.
const builtin = @import("builtin");
const std = @import("std");
const Context = @import("Context.zig");
const Stack = @import("Stack.zig");
const native = @import("arch.zig").native;
const aarch64 = @import("arch.zig").aarch64;
const supported = @import("arch.zig").supported;

const is_windows = builtin.os.tag == .windows;
const arch = builtin.cpu.arch;

/// The context every class's probe switches to: it overwrites the
/// registers and switches back, forever.
const Scrambler = struct {
    var driver: Context = .{};
    var task: Context = undefined;
    var stack: Stack = undefined;
    /// The control state the context sets before it switches back, and
    /// what it finds once it is back.
    var own: native.Control = undefined;
    var found: native.Control = undefined;
    var sink: usize = 0;

    fn start() !void {
        own = scrambledControl();
        stack = try Stack.init(.{ .size = .fromRaw(64 * 1024) });
        task = try Context.init(&stack, ?Context.Nothing, Context.Nothing, run, null);
    }

    fn finish() void {
        task.deinit(&stack);
        stack.deinit();
    }

    fn run(_: ?Context.Nothing, _: ?Context.Nothing) callconv(.c) noreturn {
        while (true) {
            sink = scramble(&own);
            _ = Context.switchTo(&task, &driver, Context.Nothing, null);
            found = native.control();
        }
    }

    /// What a probe calls: one switch to the context and back.
    fn bounce() callconv(.c) void {
        _ = Context.switchTo(&driver, &task, Context.Nothing, null);
    }
};

/// A control state unlike the default and unlike any probe's.
fn scrambledControl() native.Control {
    return switch (arch) {
        // Round down, all exceptions masked; x87 round down.
        .x86_64 => .{ .mxcsr = 0x3f80, .x87 = 0x077f },
        // Round toward minus infinity.
        .aarch64 => .{ .fpcr = 2 << 22 },
        // Round down.
        .riscv64 => .{ .fcsr = 2 << 5 },
        else => unreachable, // unreachable: the tests skip other architectures
    };
}

/// A control state the probes hold, unlike the default.
fn probeControl() native.Control {
    return switch (arch) {
        // Round toward zero, flush to zero; x87 round toward zero.
        .x86_64 => .{ .mxcsr = 0xff80, .x87 = 0x0f7f },
        // Round toward zero, flush to zero.
        .aarch64 => .{ .fpcr = (3 << 22) | (1 << 24) },
        // Round toward zero.
        .riscv64 => .{ .fcsr = 1 << 5 },
        else => unreachable, // unreachable: the tests skip other architectures
    };
}

/// Overwrites every register code may write: general, vector and the
/// floating-point control state, which it sets to `control.*`.
inline fn scramble(control: *const native.Control) usize {
    // The result is kept, not discarded: Zig's own x86_64 backend crashes
    // compiling a discarded assembly result in an inline function.
    return switch (arch) {
        .x86_64 => scrambleX86(control),
        .aarch64 => scrambleAarch64(control),
        .riscv64 => scrambleRiscv(control),
        else => unreachable, // unreachable: the tests skip other architectures
    };
}

inline fn scrambleX86(control: *const native.Control) usize {
    return asm volatile (
        \\ ldmxcsr 0(%%rax)
        \\ fldcw 4(%%rax)
        \\ movq $-1, %%rax
        \\ movq %%rax, %%rbx
        \\ movq %%rax, %%rcx
        \\ movq %%rax, %%rdx
        \\ movq %%rax, %%rsi
        \\ movq %%rax, %%rdi
        \\ movq %%rax, %%r8
        \\ movq %%rax, %%r9
        \\ movq %%rax, %%r10
        \\ movq %%rax, %%r11
        \\ movq %%rax, %%r12
        \\ movq %%rax, %%r13
        \\ movq %%rax, %%r14
        \\ movq %%rax, %%r15
        \\ pcmpeqd %%xmm0, %%xmm0
        \\ pcmpeqd %%xmm1, %%xmm1
        \\ pcmpeqd %%xmm2, %%xmm2
        \\ pcmpeqd %%xmm3, %%xmm3
        \\ pcmpeqd %%xmm4, %%xmm4
        \\ pcmpeqd %%xmm5, %%xmm5
        \\ pcmpeqd %%xmm6, %%xmm6
        \\ pcmpeqd %%xmm7, %%xmm7
        \\ pcmpeqd %%xmm8, %%xmm8
        \\ pcmpeqd %%xmm9, %%xmm9
        \\ pcmpeqd %%xmm10, %%xmm10
        \\ pcmpeqd %%xmm11, %%xmm11
        \\ pcmpeqd %%xmm12, %%xmm12
        \\ pcmpeqd %%xmm13, %%xmm13
        \\ pcmpeqd %%xmm14, %%xmm14
        \\ pcmpeqd %%xmm15, %%xmm15
        : [r] "={rax}" (-> usize),
        : [c] "0" (control),
        : .{ .rbx = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true, .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .xmm4 = true, .xmm5 = true, .xmm6 = true, .xmm7 = true, .xmm8 = true, .xmm9 = true, .xmm10 = true, .xmm11 = true, .xmm12 = true, .xmm13 = true, .xmm14 = true, .xmm15 = true, .mxcsr = true, .fpcr = true, .rflags = true, .memory = true });
}

inline fn scrambleAarch64(control: *const native.Control) usize {
    return asm volatile (
        \\ ldr x9, [x0]
        \\ msr fpcr, x9
        \\ mov x0, #-1
        \\ mov x1, #-1
        \\ mov x2, #-1
        \\ mov x3, #-1
        \\ mov x4, #-1
        \\ mov x5, #-1
        \\ mov x6, #-1
        \\ mov x7, #-1
        \\ mov x8, #-1
        \\ mov x9, #-1
        \\ mov x10, #-1
        \\ mov x11, #-1
        \\ mov x12, #-1
        \\ mov x13, #-1
        \\ mov x14, #-1
        \\ mov x15, #-1
        \\ mov x16, #-1
        \\ mov x17, #-1
        \\ mov x19, #-1
        \\ mov x20, #-1
        \\ mov x21, #-1
        \\ mov x22, #-1
        \\ mov x23, #-1
        \\ mov x24, #-1
        \\ mov x25, #-1
        \\ mov x26, #-1
        \\ mov x27, #-1
        \\ mov x28, #-1
        \\ movi v0.16b, #0xff
        \\ movi v1.16b, #0xff
        \\ movi v2.16b, #0xff
        \\ movi v3.16b, #0xff
        \\ movi v4.16b, #0xff
        \\ movi v5.16b, #0xff
        \\ movi v6.16b, #0xff
        \\ movi v7.16b, #0xff
        \\ movi v8.16b, #0xff
        \\ movi v9.16b, #0xff
        \\ movi v10.16b, #0xff
        \\ movi v11.16b, #0xff
        \\ movi v12.16b, #0xff
        \\ movi v13.16b, #0xff
        \\ movi v14.16b, #0xff
        \\ movi v15.16b, #0xff
        \\ movi v16.16b, #0xff
        \\ movi v17.16b, #0xff
        \\ movi v18.16b, #0xff
        \\ movi v19.16b, #0xff
        \\ movi v20.16b, #0xff
        \\ movi v21.16b, #0xff
        \\ movi v22.16b, #0xff
        \\ movi v23.16b, #0xff
        \\ movi v24.16b, #0xff
        \\ movi v25.16b, #0xff
        \\ movi v26.16b, #0xff
        \\ movi v27.16b, #0xff
        \\ movi v28.16b, #0xff
        \\ movi v29.16b, #0xff
        \\ movi v30.16b, #0xff
        \\ movi v31.16b, #0xff
        : [r] "={x0}" (-> usize),
        : [c] "0" (control),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v8 = true, .v9 = true, .v10 = true, .v11 = true, .v12 = true, .v13 = true, .v14 = true, .v15 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true, .fpcr = true, .nzcv = true, .memory = true });
}

inline fn scrambleRiscv(control: *const native.Control) usize {
    return asm volatile (
        \\ ld t0, 0(a0)
        \\ fscsr t0
        \\ li t0, -1
        \\ mv t1, t0
        \\ mv t2, t0
        \\ mv a0, t0
        \\ mv a1, t0
        \\ mv a2, t0
        \\ mv a3, t0
        \\ mv a4, t0
        \\ mv a5, t0
        \\ mv a6, t0
        \\ mv a7, t0
        \\ mv s1, t0
        \\ mv s2, t0
        \\ mv s3, t0
        \\ mv s4, t0
        \\ mv s5, t0
        \\ mv s6, t0
        \\ mv s7, t0
        \\ mv s8, t0
        \\ mv s9, t0
        \\ mv s10, t0
        \\ mv s11, t0
        \\ mv t3, t0
        \\ mv t4, t0
        \\ mv t5, t0
        \\ mv t6, t0
        \\ fmv.d.x f0, t0
        \\ fmv.d.x f1, t0
        \\ fmv.d.x f2, t0
        \\ fmv.d.x f3, t0
        \\ fmv.d.x f4, t0
        \\ fmv.d.x f5, t0
        \\ fmv.d.x f6, t0
        \\ fmv.d.x f7, t0
        \\ fmv.d.x f8, t0
        \\ fmv.d.x f9, t0
        \\ fmv.d.x f10, t0
        \\ fmv.d.x f11, t0
        \\ fmv.d.x f12, t0
        \\ fmv.d.x f13, t0
        \\ fmv.d.x f14, t0
        \\ fmv.d.x f15, t0
        \\ fmv.d.x f16, t0
        \\ fmv.d.x f17, t0
        \\ fmv.d.x f18, t0
        \\ fmv.d.x f19, t0
        \\ fmv.d.x f20, t0
        \\ fmv.d.x f21, t0
        \\ fmv.d.x f22, t0
        \\ fmv.d.x f23, t0
        \\ fmv.d.x f24, t0
        \\ fmv.d.x f25, t0
        \\ fmv.d.x f26, t0
        \\ fmv.d.x f27, t0
        \\ fmv.d.x f28, t0
        \\ fmv.d.x f29, t0
        \\ fmv.d.x f30, t0
        \\ fmv.d.x f31, t0
        : [r] "={a0}" (-> usize),
        : [c] "0" (control),
        : .{ .x5 = true, .x6 = true, .x7 = true, .x9 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = true, .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true, .x29 = true, .x30 = true, .x31 = true, .f0 = true, .f1 = true, .f2 = true, .f3 = true, .f4 = true, .f5 = true, .f6 = true, .f7 = true, .f8 = true, .f9 = true, .f10 = true, .f11 = true, .f12 = true, .f13 = true, .f14 = true, .f15 = true, .f16 = true, .f17 = true, .f18 = true, .f19 = true, .f20 = true, .f21 = true, .f22 = true, .f23 = true, .f24 = true, .f25 = true, .f26 = true, .f27 = true, .f28 = true, .f29 = true, .f30 = true, .f31 = true, .fflags = true, .frm = true, .memory = true });
}

/// A probe: the function to call, then patterns, then what the registers
/// held after the call. Laid out for the assembly that reads it.
fn Probe(comptime slots: usize) type {
    return extern struct {
        bounce: *const fn () callconv(.c) void = Scrambler.bounce,
        pad: usize = 0,
        patterns: [slots]u64 align(16),
        out: [slots]u64 align(16) = @splat(0),
        /// What the frame pointer's pattern points at: a frame record that
        /// ends any walk, since a sanitizer's runtime may walk frames from
        /// inside the switch.
        record: [2]usize align(16) = .{ 0, 0 },
    };
}

fn patterns(comptime n: usize, seed: u64) [n]u64 {
    var p: [n]u64 = undefined;
    for (&p, 0..) |*v, i| v.* = (seed *% (i + 1)) ^ 0x5a5a_0000_0000_0000;
    return p;
}

// General registers.

/// The general registers a call keeps, the frame pointer among them.
const gpr_count = switch (arch) {
    .x86_64 => if (is_windows) 8 else 6, // rbx rbp r12-r15, and rdi rsi on Windows
    .aarch64 => 11, // x19-x28, x29
    .riscv64 => 12, // s0-s11
    else => 0,
};

const GprProbe = Probe(gpr_count);

/// Where the frame pointer is among the general registers' patterns.
const fp_index = switch (arch) {
    .x86_64 => 1, // rbx, then rbp
    .aarch64 => 10, // x19-x28, then x29
    else => 0, // s0 first
};

/// What a probe's call may change of the general and vector registers, on
/// x86_64: all of them, as far as the compiler around the probe can tell.
const x86_general: std.lang.assembly.Clobbers = .{ .rbx = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true, .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .xmm4 = true, .xmm5 = true, .xmm6 = true, .xmm7 = true, .xmm8 = true, .xmm9 = true, .xmm10 = true, .xmm11 = true, .xmm12 = true, .xmm13 = true, .xmm14 = true, .xmm15 = true, .rflags = true, .memory = true };

noinline fn holdGeneral(p: *GprProbe) void {
    switch (arch) {
        .x86_64 => _ = if (is_windows) asm volatile (
            \\ pushq %%rbp
            \\ movq %%rsp, %%rcx
            \\ andq $-16, %%rsp
            \\ pushq %%rcx
            \\ pushq %%rax
            \\ movq 16(%%rax), %%rbx
            \\ movq 24(%%rax), %%rbp
            \\ movq 32(%%rax), %%r12
            \\ movq 40(%%rax), %%r13
            \\ movq 48(%%rax), %%r14
            \\ movq 56(%%rax), %%r15
            \\ movq 64(%%rax), %%rdi
            \\ movq 72(%%rax), %%rsi
            \\ subq $32, %%rsp
            \\ callq *0(%%rax)
            \\ addq $32, %%rsp
            \\ movq 0(%%rsp), %%rax
            \\ movq %%rbx, 80(%%rax)
            \\ movq %%rbp, 88(%%rax)
            \\ movq %%r12, 96(%%rax)
            \\ movq %%r13, 104(%%rax)
            \\ movq %%r14, 112(%%rax)
            \\ movq %%r15, 120(%%rax)
            \\ movq %%rdi, 128(%%rax)
            \\ movq %%rsi, 136(%%rax)
            \\ addq $8, %%rsp
            \\ popq %%rsp
            \\ popq %%rbp
            : [r] "={rax}" (-> usize),
            : [p] "0" (p),
            : x86_general) else asm volatile (
            \\ pushq %%rbp
            \\ movq %%rsp, %%rcx
            \\ andq $-16, %%rsp
            \\ pushq %%rcx
            \\ pushq %%rax
            \\ movq 16(%%rax), %%rbx
            \\ movq 24(%%rax), %%rbp
            \\ movq 32(%%rax), %%r12
            \\ movq 40(%%rax), %%r13
            \\ movq 48(%%rax), %%r14
            \\ movq 56(%%rax), %%r15
            \\ callq *0(%%rax)
            \\ movq 0(%%rsp), %%rax
            \\ movq %%rbx, 64(%%rax)
            \\ movq %%rbp, 72(%%rax)
            \\ movq %%r12, 80(%%rax)
            \\ movq %%r13, 88(%%rax)
            \\ movq %%r14, 96(%%rax)
            \\ movq %%r15, 104(%%rax)
            \\ addq $8, %%rsp
            \\ popq %%rsp
            \\ popq %%rbp
            : [r] "={rax}" (-> usize),
            : [p] "0" (p),
            : x86_general),
        .aarch64 => _ = asm volatile (
            \\ stp x29, x30, [sp, #-32]!
            \\ str x0, [sp, #16]
            \\ ldp x19, x20, [x0, #16]
            \\ ldp x21, x22, [x0, #32]
            \\ ldp x23, x24, [x0, #48]
            \\ ldp x25, x26, [x0, #64]
            \\ ldp x27, x28, [x0, #80]
            \\ ldr x29, [x0, #96]
            \\ ldr x16, [x0]
            \\ blr x16
            \\ ldr x0, [sp, #16]
            \\ stp x19, x20, [x0, #112]
            \\ stp x21, x22, [x0, #128]
            \\ stp x23, x24, [x0, #144]
            \\ stp x25, x26, [x0, #160]
            \\ stp x27, x28, [x0, #176]
            \\ str x29, [x0, #192]
            \\ ldp x29, x30, [sp], #32
            : [r] "={x0}" (-> usize),
            : [p] "0" (p),
            : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = !aarch64.reserves_x18, .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true, .nzcv = true, .memory = true }),
        .riscv64 => holdGeneralRiscv(p),
        else => unreachable, // unreachable: the tests skip other architectures
    }
}

inline fn holdGeneralRiscv(p: *GprProbe) void {
    _ = asm volatile (
        \\ addi sp, sp, -32
        \\ sd ra, 0(sp)
        \\ sd s0, 8(sp)
        \\ sd a0, 16(sp)
        \\ ld t0, 0(a0)
        \\ ld s0, 16(a0)
        \\ ld s1, 24(a0)
        \\ ld s2, 32(a0)
        \\ ld s3, 40(a0)
        \\ ld s4, 48(a0)
        \\ ld s5, 56(a0)
        \\ ld s6, 64(a0)
        \\ ld s7, 72(a0)
        \\ ld s8, 80(a0)
        \\ ld s9, 88(a0)
        \\ ld s10, 96(a0)
        \\ ld s11, 104(a0)
        \\ jalr t0
        \\ ld a0, 16(sp)
        \\ sd s0, 112(a0)
        \\ sd s1, 120(a0)
        \\ sd s2, 128(a0)
        \\ sd s3, 136(a0)
        \\ sd s4, 144(a0)
        \\ sd s5, 152(a0)
        \\ sd s6, 160(a0)
        \\ sd s7, 168(a0)
        \\ sd s8, 176(a0)
        \\ sd s9, 184(a0)
        \\ sd s10, 192(a0)
        \\ sd s11, 200(a0)
        \\ ld ra, 0(sp)
        \\ ld s0, 8(sp)
        \\ addi sp, sp, 32
        : [r] "={a0}" (-> usize),
        : [p] "0" (p),
        : .{ .x5 = true, .x6 = true, .x7 = true, .x9 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = true, .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true, .x29 = true, .x30 = true, .x31 = true, .f0 = true, .f1 = true, .f2 = true, .f3 = true, .f4 = true, .f5 = true, .f6 = true, .f7 = true, .f10 = true, .f11 = true, .f12 = true, .f13 = true, .f14 = true, .f15 = true, .f16 = true, .f17 = true, .f28 = true, .f29 = true, .f30 = true, .f31 = true, .memory = true });
}

test "the general registers a call keeps, the frame pointer among them, survive a switch to a context that overwrites them" {
    if (!supported) return error.SkipZigTest;
    try Scrambler.start();
    defer Scrambler.finish();
    var p: GprProbe = .{ .patterns = patterns(gpr_count, 0x0123_4567_89ab_cdef) };
    // The frame pointer's pattern is a frame record of its own, unique all the same.
    p.patterns[fp_index] = @intFromPtr(&p.record) + if (arch == .riscv64) 16 else 0; // safe: an address, held as the frame pointer
    holdGeneral(&p);
    try std.testing.expectEqualSlices(u64, &p.patterns, &p.out);
}

// Vector registers.

/// The vector registers a call keeps, as 64-bit halves: d8-d15 on aarch64,
/// xmm6-xmm15 on Windows x64 (both halves), fs0-fs11 on riscv64. System V
/// x86_64 keeps none.
const vector_count = switch (arch) {
    .x86_64 => if (is_windows) 20 else 0,
    .aarch64 => 8,
    .riscv64 => 12,
    else => 0,
};

const VectorProbe = Probe(vector_count);

noinline fn holdVector(p: *VectorProbe) void {
    switch (arch) {
        .x86_64 => if (is_windows) {
            _ = asm volatile (
                \\ pushq %%rbp
                \\ movq %%rsp, %%rcx
                \\ andq $-16, %%rsp
                \\ pushq %%rcx
                \\ pushq %%rax
                \\ movdqu 16(%%rax), %%xmm6
                \\ movdqu 32(%%rax), %%xmm7
                \\ movdqu 48(%%rax), %%xmm8
                \\ movdqu 64(%%rax), %%xmm9
                \\ movdqu 80(%%rax), %%xmm10
                \\ movdqu 96(%%rax), %%xmm11
                \\ movdqu 112(%%rax), %%xmm12
                \\ movdqu 128(%%rax), %%xmm13
                \\ movdqu 144(%%rax), %%xmm14
                \\ movdqu 160(%%rax), %%xmm15
                \\ subq $32, %%rsp
                \\ callq *0(%%rax)
                \\ addq $32, %%rsp
                \\ movq 0(%%rsp), %%rax
                \\ movdqu %%xmm6, 176(%%rax)
                \\ movdqu %%xmm7, 192(%%rax)
                \\ movdqu %%xmm8, 208(%%rax)
                \\ movdqu %%xmm9, 224(%%rax)
                \\ movdqu %%xmm10, 240(%%rax)
                \\ movdqu %%xmm11, 256(%%rax)
                \\ movdqu %%xmm12, 272(%%rax)
                \\ movdqu %%xmm13, 288(%%rax)
                \\ movdqu %%xmm14, 304(%%rax)
                \\ movdqu %%xmm15, 320(%%rax)
                \\ addq $8, %%rsp
                \\ popq %%rsp
                \\ popq %%rbp
                : [r] "={rax}" (-> usize),
                : [p] "0" (p),
                : .{ .rcx = true, .rdx = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .xmm4 = true, .xmm5 = true, .xmm6 = true, .xmm7 = true, .xmm8 = true, .xmm9 = true, .xmm10 = true, .xmm11 = true, .xmm12 = true, .xmm13 = true, .xmm14 = true, .xmm15 = true, .rflags = true, .memory = true });
        },
        .aarch64 => _ = asm volatile (
            \\ stp x29, x30, [sp, #-32]!
            \\ str x0, [sp, #16]
            \\ ldp d8, d9, [x0, #16]
            \\ ldp d10, d11, [x0, #32]
            \\ ldp d12, d13, [x0, #48]
            \\ ldp d14, d15, [x0, #64]
            \\ ldr x16, [x0]
            \\ blr x16
            \\ ldr x0, [sp, #16]
            \\ stp d8, d9, [x0, #80]
            \\ stp d10, d11, [x0, #96]
            \\ stp d12, d13, [x0, #112]
            \\ stp d14, d15, [x0, #128]
            \\ ldp x29, x30, [sp], #32
            : [r] "={x0}" (-> usize),
            : [p] "0" (p),
            : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = !aarch64.reserves_x18, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v8 = true, .v9 = true, .v10 = true, .v11 = true, .v12 = true, .v13 = true, .v14 = true, .v15 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true, .nzcv = true, .memory = true }),
        .riscv64 => _ = asm volatile (
            \\ addi sp, sp, -16
            \\ sd ra, 0(sp)
            \\ sd a0, 8(sp)
            \\ ld t0, 0(a0)
            \\ fld fs0, 16(a0)
            \\ fld fs1, 24(a0)
            \\ fld fs2, 32(a0)
            \\ fld fs3, 40(a0)
            \\ fld fs4, 48(a0)
            \\ fld fs5, 56(a0)
            \\ fld fs6, 64(a0)
            \\ fld fs7, 72(a0)
            \\ fld fs8, 80(a0)
            \\ fld fs9, 88(a0)
            \\ fld fs10, 96(a0)
            \\ fld fs11, 104(a0)
            \\ jalr t0
            \\ ld a0, 8(sp)
            \\ fsd fs0, 112(a0)
            \\ fsd fs1, 120(a0)
            \\ fsd fs2, 128(a0)
            \\ fsd fs3, 136(a0)
            \\ fsd fs4, 144(a0)
            \\ fsd fs5, 152(a0)
            \\ fsd fs6, 160(a0)
            \\ fsd fs7, 168(a0)
            \\ fsd fs8, 176(a0)
            \\ fsd fs9, 184(a0)
            \\ fsd fs10, 192(a0)
            \\ fsd fs11, 200(a0)
            \\ ld ra, 0(sp)
            \\ addi sp, sp, 16
            : [r] "={a0}" (-> usize),
            : [p] "0" (p),
            : .{ .x5 = true, .x6 = true, .x7 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x28 = true, .x29 = true, .x30 = true, .x31 = true, .f0 = true, .f1 = true, .f2 = true, .f3 = true, .f4 = true, .f5 = true, .f6 = true, .f7 = true, .f8 = true, .f9 = true, .f10 = true, .f11 = true, .f12 = true, .f13 = true, .f14 = true, .f15 = true, .f16 = true, .f17 = true, .f18 = true, .f19 = true, .f20 = true, .f21 = true, .f22 = true, .f23 = true, .f24 = true, .f25 = true, .f26 = true, .f27 = true, .f28 = true, .f29 = true, .f30 = true, .f31 = true, .memory = true }),
        else => unreachable, // unreachable: the tests skip other architectures
    }
}

test "the vector registers a call keeps survive a switch to a context that overwrites them" {
    if (!supported or vector_count == 0) return error.SkipZigTest;
    try Scrambler.start();
    defer Scrambler.finish();
    var p: VectorProbe = .{ .patterns = patterns(vector_count, 0x0fed_cba9_8765_4321) };
    holdVector(&p);
    try std.testing.expectEqualSlices(u64, &p.patterns, &p.out);
}

// Floating-point control state.

const ControlProbe = extern struct {
    bounce: *const fn () callconv(.c) void = Scrambler.bounce,
    pattern: native.Control,
    /// Zeroed, so bytes the control registers do not fill compare equal.
    out: native.Control = std.mem.zeroes(native.Control),
    saved: native.Control = std.mem.zeroes(native.Control),
};

comptime {
    if (supported and (@offsetOf(ControlProbe, "pattern") != 8 or @offsetOf(ControlProbe, "out") != 16 or @offsetOf(ControlProbe, "saved") != 24)) @compileError("the probe's assembly reads these offsets");
}

noinline fn holdControl(p: *ControlProbe) void {
    switch (arch) {
        .x86_64 => _ = asm volatile (
            \\ pushq %%rbp
            \\ movq %%rsp, %%rcx
            \\ andq $-16, %%rsp
            \\ pushq %%rcx
            \\ pushq %%rax
            \\ stmxcsr 24(%%rax)
            \\ fnstcw 28(%%rax)
            \\ ldmxcsr 8(%%rax)
            \\ fldcw 12(%%rax)
            \\ subq $32, %%rsp
            \\ callq *0(%%rax)
            \\ addq $32, %%rsp
            \\ movq 0(%%rsp), %%rax
            \\ stmxcsr 16(%%rax)
            \\ fnstcw 20(%%rax)
            \\ ldmxcsr 24(%%rax)
            \\ fldcw 28(%%rax)
            \\ addq $8, %%rsp
            \\ popq %%rsp
            \\ popq %%rbp
            : [r] "={rax}" (-> usize),
            : [p] "0" (p),
            : .{ .rbx = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true, .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .xmm4 = true, .xmm5 = true, .xmm6 = true, .xmm7 = true, .xmm8 = true, .xmm9 = true, .xmm10 = true, .xmm11 = true, .xmm12 = true, .xmm13 = true, .xmm14 = true, .xmm15 = true, .mxcsr = true, .fpcr = true, .rflags = true, .memory = true }),
        .aarch64 => _ = asm volatile (
            \\ stp x29, x30, [sp, #-32]!
            \\ str x0, [sp, #16]
            \\ mrs x9, fpcr
            \\ str x9, [x0, #24]
            \\ ldr x9, [x0, #8]
            \\ msr fpcr, x9
            \\ ldr x16, [x0]
            \\ blr x16
            \\ ldr x0, [sp, #16]
            \\ mrs x9, fpcr
            \\ str x9, [x0, #16]
            \\ ldr x9, [x0, #24]
            \\ msr fpcr, x9
            \\ ldp x29, x30, [sp], #32
            : [r] "={x0}" (-> usize),
            : [p] "0" (p),
            : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = !aarch64.reserves_x18, .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v8 = true, .v9 = true, .v10 = true, .v11 = true, .v12 = true, .v13 = true, .v14 = true, .v15 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true, .fpcr = true, .nzcv = true, .memory = true }),
        .riscv64 => _ = asm volatile (
            \\ addi sp, sp, -16
            \\ sd ra, 0(sp)
            \\ sd a0, 8(sp)
            \\ frcsr t1
            \\ sd t1, 24(a0)
            \\ ld t1, 8(a0)
            \\ fscsr t1
            \\ ld t0, 0(a0)
            \\ jalr t0
            \\ ld a0, 8(sp)
            \\ frcsr t1
            \\ sd t1, 16(a0)
            \\ ld t1, 24(a0)
            \\ fscsr t1
            \\ ld ra, 0(sp)
            \\ addi sp, sp, 16
            : [r] "={a0}" (-> usize),
            : [p] "0" (p),
            : .{ .x5 = true, .x6 = true, .x7 = true, .x9 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = true, .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true, .x29 = true, .x30 = true, .x31 = true, .f0 = true, .f1 = true, .f2 = true, .f3 = true, .f4 = true, .f5 = true, .f6 = true, .f7 = true, .f8 = true, .f9 = true, .f10 = true, .f11 = true, .f12 = true, .f13 = true, .f14 = true, .f15 = true, .f16 = true, .f17 = true, .f18 = true, .f19 = true, .f20 = true, .f21 = true, .f22 = true, .f23 = true, .f24 = true, .f25 = true, .f26 = true, .f27 = true, .f28 = true, .f29 = true, .f30 = true, .f31 = true, .fflags = true, .frm = true, .memory = true }),
        else => unreachable, // unreachable: the tests skip other architectures
    }
}

test "each context keeps its own floating-point control state across a switch, both ways" {
    if (!supported) return error.SkipZigTest;
    if (arch == .riscv64 and !std.Target.riscv.featureSetHas(builtin.cpu.features, .f)) return error.SkipZigTest;
    try Scrambler.start();
    defer Scrambler.finish();
    var p: ControlProbe = .{ .pattern = probeControl() };
    holdControl(&p);
    // The caller's state came back to it.
    try std.testing.expectEqual(p.pattern, p.out);
    // The context's state came back to it, though the caller ran with another.
    holdControl(&p);
    try std.testing.expectEqual(Scrambler.own, Scrambler.found);
    // And the caller's own state is as it was before any of this.
    try std.testing.expectEqual(p.saved, native.control());
}

// What the compiler itself keeps.

test "values the switching code keeps in vector registers survive a context that overwrites them" {
    if (!supported) return error.SkipZigTest;
    try Scrambler.start();
    defer Scrambler.finish();
    const V = @Vector(4, f32);
    var input: [12]V = undefined;
    for (&input, 0..) |*v, i| v.* = @splat(@floatFromInt(i + 1));
    std.mem.doNotOptimizeAway(&input);
    // Nothing but the switch between computing them and reading them: no
    // other call for the compiler to spill around.
    var kept: [12]V = undefined;
    inline for (0..12) |i| kept[i] = input[i] * input[i];
    _ = Context.switchTo(&Scrambler.driver, &Scrambler.task, Context.Nothing, null);
    inline for (0..12) |i| {
        const square: f32 = @floatFromInt((i + 1) * (i + 1));
        try std.testing.expectEqual(@as(V, @splat(square)), kept[i]);
    }
}

test "values the switching code keeps in general registers survive a context that overwrites them" {
    if (!supported) return error.SkipZigTest;
    try Scrambler.start();
    defer Scrambler.finish();
    var input: [12]u64 = undefined;
    for (&input, 0..) |*v, i| v.* = i + 1;
    std.mem.doNotOptimizeAway(&input);
    var kept: [12]u64 = undefined;
    inline for (0..12) |i| kept[i] = input[i] *% 0x9e37_79b9_7f4a_7c15;
    _ = Context.switchTo(&Scrambler.driver, &Scrambler.task, Context.Nothing, null);
    inline for (0..12) |i| try std.testing.expectEqual(@as(u64, i + 1) *% 0x9e37_79b9_7f4a_7c15, kept[i]);
}
