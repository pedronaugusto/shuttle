//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "platform", .patterns = &.{
        "src/memory.zig",
        "src/teb.zig",
        "src/sanitizer.zig",
        "src/arch/x86_64.zig",
        "src/arch/aarch64.zig",
        "src/arch/riscv64.zig",
    } },
    .{ .name = "the switch", .patterns = &.{"src/arch.zig"} },
    .{ .name = "traces and stacks", .patterns = &.{
        "src/trace.zig",
        "src/Stack.zig",
    } },
    .{ .name = "pools and contexts", .patterns = &.{
        "src/Pool.zig",
        "src/Context.zig",
    } },
    .{ .name = "handoff and panics", .patterns = &.{
        "src/handoff.zig",
        "src/Panic.zig",
    } },
    .{ .name = "coroutines", .patterns = &.{"src/coroutine.zig"} },
    .{ .name = "generators and overflows", .patterns = &.{
        "src/generator.zig",
        "src/overflow.zig",
    } },
    .{ .name = "public", .patterns = &.{"src/shuttle.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "builtin",
        "aegis",
        "shakedown",
        "shuttle",
        "preflight_bench_options",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const references: []const gantry.rules.ReferenceRule = &package_references;
pub const owned: []const gantry.rules.TokenRule = &.{};

pub const required = [_][]const u8{
    "src/shuttle.zig",
    "src/arch.zig",
    "src/Context.zig",
    "src/Stack.zig",
    "src/Pool.zig",
    "src/coroutine.zig",
    "src/tests.zig",
};
