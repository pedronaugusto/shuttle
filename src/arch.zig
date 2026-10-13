//! The switch for each architecture shuttle runs on, behind one interface:
//! `Registers` (a suspended context), `Control` (its floating-point control
//! state), `Transfer` (what a switch carries), `swap`, `initial` (a new
//! context's registers and first frame) and `trampoline` (its first code).
const builtin = @import("builtin");

pub const x86_64 = @import("arch/x86_64.zig");
pub const aarch64 = @import("arch/aarch64.zig");
pub const riscv64 = @import("arch/riscv64.zig");

/// Whether shuttle has a switch for this architecture.
pub const supported = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .riscv64 => true,
    else => false,
};

/// This architecture's switch.
pub const native = switch (builtin.cpu.arch) {
    .x86_64 => x86_64,
    .aarch64 => aarch64,
    .riscv64 => riscv64,
    else => @compileError("shuttle has no switch for " ++ @tagName(builtin.cpu.arch)),
};
