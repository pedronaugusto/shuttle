const std = @import("std");

/// What a project that depends on shuttle builds: the `shuttle` module.
/// The tests, programs, example, benchmarks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    _ = b.addModule("shuttle", .{
        .root_source_file = b.path("src/shuttle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aegis", .module = aegis.module("aegis") }},
    });
}

/// shuttle's development: its tests (in the mode asked for, and again
/// optimized), its fault program, its properties, the example and the
/// benchmarks, under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("shuttle", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("shuttle");
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown");
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};

    const test_step = b.step("test", "Run the tests, the fault program, the example and each benchmark once");
    const check = b.step("check", "Compile the tests, programs, example and benchmarks without running them");

    // The suite alone, in the mode asked for: what ThreadSanitizer runs.
    const tests = suite(b, p.path("src/tests.zig"), "shuttle-tests", target, optimize, aegis.module("aegis"), shakedown, filters);
    const unit = b.step("unit", "Run the test suite alone");
    unit.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(unit);
    check.dependOn(&tests.step);

    // The switch's bugs were found in optimized code (a register kept
    // across a switch, a stack 8 bytes off), so every run of the tests runs
    // them optimized as well, without frame pointers, whatever its mode.
    if (optimize != .fast) {
        const fast_shakedown = b.dependency("shakedown", .{ .target = target, .optimize = .fast }).module("shakedown");
        const fast_aegis = p.dependency("aegis", .{ .target = target, .optimize = .fast }).module("aegis");
        const fast = suite(b, p.path("src/tests.zig"), "shuttle-tests-fast", target, .fast, fast_aegis, fast_shakedown, filters);
        fast.root_module.omit_frame_pointer = true;
        test_step.dependOn(&b.addRunArtifact(fast).step);
        check.dependOn(&fast.step);
    }

    // The properties alone, every binary of them a property: what the
    // fuzzer runs (`bay properties --fuzz`).
    const properties = suite(b, p.path("src/property_test.zig"), "shuttle-properties", target, optimize, aegis.module("aegis"), shakedown, filters);
    b.step("properties", "Run the properties alone").dependOn(&b.addRunArtifact(properties).step);
    check.dependOn(&properties.step);

    // Panics handed over and stack overflows named need shuttle's handlers
    // in a program's root, and the fatal ones a process of their own.
    const faults = b.addExecutable(.{
        .name = "faults",
        .root_module = b.createModule(.{ .root_source_file = p.path("src/testing/faults.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "shuttle", .module = module }} }),
    });
    test_step.dependOn(&b.addRunArtifact(faults).step);
    check.dependOn(&faults.step);

    // examples/usage.zig is also README.md's Usage blocks (bay docs --
    // usage), so the code a reader copies is code the tests run.
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "shuttle", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(check);

    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // The release tier fuzzes the properties and runs the suite under
        // ThreadSanitizer, where a switch it was not told of shows.
        .hardened = .{ .fuzz_step = "properties", .tsan_step = "unit" },
        // `bay bench` times them in ReleaseFast, by hand; never timed in CI,
        // where `bay test` runs each row once.
        .bench = .{
            .programs = &.{.{ .name = "shuttle-bench", .source = "bench/main.zig" }},
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on shuttle by path, with only the packages
    // shuttle needs: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "shuttle", .program = p.path("ci/consumer.zig"), .packages = &.{aegis}, .modules = &.{"shuttle"} });
}

fn suite(b: *std.Build, root: std.Build.LazyPath, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, aegis: *std.Build.Module, shakedown: *std.Build.Module, filters: []const []const u8) *std.Build.Step.Compile {
    return b.addTest(.{
        .name = name,
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "shakedown", .module = shakedown } },
        }),
    });
}

/// shuttle again, in the mode a benchmark builds in: an imported module
/// keeps its own mode, so a ReleaseFast benchmark over the Debug module
/// would time the Debug module. `b` is the development build; preflight
/// adds shakedown itself.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const shuttle = b.dependency("shuttle", .{ .target = target, .optimize = optimize }).module("shuttle");
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "shuttle", .module = shuttle }}) catch @panic("OOM");
}
