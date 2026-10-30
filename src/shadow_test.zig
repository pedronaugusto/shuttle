//! Contexts under CET shadow stacks (Linux x86_64, the LLVM backend).
//!
//! A thread turns its shadow stack on and runs contexts there: on a stack
//! of its own and on a pool's, each used again and again, so that a context
//! starts below the token the one before it left, from a few calls deep. A
//! call and its return are checked against the shadow stack, so a switch
//! that kept the thread's shadow stack, or took the wrong token, faults
//! (SIGSEGV, SEGV_CPERR) and the test binary with it. Where the processor
//! or the kernel has no shadow stacks the test is skipped.
const std = @import("std");
const Context = @import("Context.zig");
const Stack = @import("Stack.zig");
const Pool = @import("Pool.zig");
const native = @import("arch.zig").native;

const linux = std.os.linux;

// arch/x86/include/uapi/asm/prctl.h
const arch_shstk_enable = 0x5001;
const arch_shstk_shstk = 1 << 0;

const Run = struct {
    outcome: enum { pending, unsupported, failed, passed } = .pending,
    /// What failed, for the test to say: the shadow stack pointer read
    /// after turning it on, or the error the contexts' run returned.
    failure: union(enum) { none, no_pointer, err: anyerror } = .none,
    /// What the contexts counted, checked against what they were asked.
    calls: u64 = 0,
    rounds: u32 = 0,
};

/// A context's work: rounds, each a chain of calls that return through the
/// shadow stack, then a switch back.
const Task = struct {
    driver: *Context,
    self: Context,
    rounds: u32,
    run: *Run,

    fn entry(task: *Task, _: ?Context.Nothing) callconv(.c) noreturn {
        for (0..task.rounds) |i| {
            task.run.calls += depth(@intCast(i % 24));
            task.run.rounds += 1;
            _ = Context.switchTo(&task.self, task.driver, Context.Nothing, null);
        }
        task.leaveFrom(3);
        unreachable; // unreachable: nothing switches back to a finished task
    }

    /// The last switch away, `calls` calls deep: the next context on the
    /// stack takes the token it leaves there. Nothing switches back, so the
    /// count after each call never runs; it keeps the call from being a tail
    /// call, a frame on both stacks.
    noinline fn leaveFrom(task: *Task, calls: u32) void {
        if (calls == 0) {
            _ = Context.switchTo(&task.self, task.driver, Context.Nothing, null);
            return;
        }
        task.leaveFrom(calls - 1);
        task.run.calls += 1;
    }
};

/// `n` nested calls, none of them a tail call.
noinline fn depth(n: u32) u64 {
    if (n == 0) return 0;
    return 1 + depth(n - 1);
}

/// A task of `rounds` rounds on `stack`, run to its end.
fn runOn(stack: *Stack, rounds: u32, run: *Run) error{StackTooSmall}!void {
    var driver: Context = .{};
    var task: Task = .{ .driver = &driver, .self = undefined, .rounds = rounds, .run = run };
    task.self = try Context.init(stack, *Task, Context.Nothing, Task.entry, &task);
    for (0..rounds + 1) |_| _ = Context.switchTo(&driver, &task.self, Context.Nothing, null);
    task.self.deinit(stack);
}

const uses_per_stack = 8;
const rounds_per_task = 16;

fn exercise(run: *Run) !void {
    var stack = try Stack.init(.{ .size = .fromRaw(64 * 1024) });
    defer stack.deinit();
    if (stack.shadow.end == 0) return error.NoShadowStack;
    for (0..uses_per_stack) |_| try runOn(&stack, rounds_per_task, run);

    var pool = try Pool.init(std.testing.allocator, .{ .classes = &.{.{ .size = .fromRaw(64 * 1024), .count = 2 }} });
    defer pool.deinit(std.testing.allocator);
    for (0..uses_per_stack) |_| {
        var pooled = (try pool.take(.fromRaw(64 * 1024))).?;
        if (pooled.shadow.end == 0) return error.NoShadowStack;
        try runOn(&pooled, rounds_per_task, run);
        pool.give(pooled);
    }
}

/// The thread's whole life. Its shadow stack starts empty when it is turned
/// on, so neither the call that turns it on nor this function may return:
/// the call is the system call itself, inline, and the thread ends with
/// another.
fn shadowThread(run: *Run) noreturn {
    const rc = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (@backingInt(linux.SYS.arch_prctl)),
          [code] "{rdi}" (@as(usize, arch_shstk_enable)),
          [features] "{rsi}" (@as(usize, arch_shstk_shstk)),
        : .{ .rcx = true, .r11 = true, .memory = true });
    if (linux.errno(rc) != .SUCCESS) {
        run.outcome = .unsupported;
    } else if (native.shadowStackPointer() == 0) {
        run.outcome = .failed;
        run.failure = .no_pointer;
    } else {
        exercise(run) catch |err| {
            run.outcome = .failed;
            run.failure = .{ .err = err };
        };
        if (run.outcome == .pending) run.outcome = .passed;
    }
    asm volatile ("syscall"
        :
        : [number] "{rax}" (@backingInt(linux.SYS.exit)),
          [status] "{rdi}" (@as(usize, 0)),
        : .{ .rcx = true, .r11 = true, .memory = true });
    unreachable; // unreachable: the thread has ended
}

test "contexts run under CET shadow stacks, each on its stack's own, reused without running out" {
    if (comptime !native.shadow_stacks) return error.SkipZigTest;
    var run: Run = .{};
    const thread = try std.Thread.spawn(.{}, shadowThread, .{&run});
    thread.join();
    switch (run.outcome) {
        .unsupported => return error.SkipZigTest,
        .pending, .failed => {
            switch (run.failure) {
                .none => std.debug.print("shadow stacks: the thread ended without an outcome\n", .{}),
                .no_pointer => std.debug.print("shadow stacks: on, but RDSSP read zero\n", .{}),
                .err => |err| std.debug.print("shadow stacks: the contexts' run failed: {t} (after {d} rounds)\n", .{ err, run.rounds }),
            }
            return error.TestUnexpectedResult;
        },
        .passed => {},
    }
    const tasks = 2 * uses_per_stack;
    try std.testing.expectEqual(tasks * rounds_per_task, run.rounds);
    var calls: u64 = 0;
    for (0..rounds_per_task) |i| calls += i % 24;
    try std.testing.expectEqual(tasks * calls, run.calls);
}
