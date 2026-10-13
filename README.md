# shuttle

shuttle runs code on stacks of its own, in Zig: contexts that switch to one
another, the stacks they run on, and coroutines and generators on top. A
switch keeps what a call keeps, register class by register class, the
floating-point control state included, on x86_64 (System V and Windows),
aarch64 (Linux, Apple and Windows) and riscv64. It is for any program that
wants stackful contexts: a fiber job system, a task scheduler, a generator
over a recursive walk.

Work in progress toward the public cut.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/shuttle`, then take the `shuttle` module
through `b.dependency` and add it to your executable's imports. At run time
shuttle depends on std and on aegis, a std-only library of checked types. See
[the design](docs/design.md) for how a switch works, what each layer owns and
what moving a context between threads asks of its code.

## Usage

A coroutine is given a value each time it runs and hands one back each time
it yields, until it returns. Its state and its arguments live at the top of
its stack, so making one allocates nothing:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const shuttle = @import("shuttle");

/// Sums what it is given, handing back the running total, until it is
/// given zero.
const Sum = shuttle.Coroutine(u32, u64, error{Canceled}!u64);

fn sum(y: *Sum.Yielder, first: u32) error{Canceled}!u64 {
    var total: u64 = first;
    while (true) {
        const n = try y.yield(total); // back to whoever runs it, with total
        if (n == 0) return total;
        total += n;
    }
}

fn coroutine() !void {
    const stack = try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) });
    const co = try Sum.init(stack, sum, .{});
    std.debug.assert(co.next(5).yielded == 5); // the first input is sum's parameter
    std.debug.assert(co.next(7).yielded == 12); // later ones are what yield returns
    std.debug.assert(try co.next(0).returned == 12);
    var s = co.deinit(); // the stack back; a suspended coroutine is canceled first
    s.deinit();
}
```
<!-- END GENERATED -->

A generator only yields, and reads as an iterator:

<!-- BEGIN GENERATED zig build docs -- generator -->
```zig
const shuttle = @import("shuttle");

const Squares = shuttle.Generator(u64, error{});

fn squares(y: *Squares.Yielder, limit: u64) error{Canceled}!void {
    var i: u64 = 0;
    while (i * i < limit) : (i += 1) try y.yield(i * i);
}

fn generator() !void {
    var g = try Squares.init(try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) }), squares, .{@as(u64, 50)});
    var total: u64 = 0;
    while (try g.next()) |square| total += square;
    std.debug.assert(total == 0 + 1 + 4 + 9 + 16 + 25 + 36 + 49);
    var s = g.deinit();
    s.deinit();
}
```
<!-- END GENERATED -->

Contexts are the layer beneath, for a scheduler of its own: any context
switches to any suspended one, with a message each way. A thread's own
context is `.{}`. A context is what a switch saves, 40 bytes on aarch64 and
32 on x86_64; the stack it runs on stays its maker's:

<!-- BEGIN GENERATED zig build docs -- context -->
```zig
const shuttle = @import("shuttle");

var main_context: shuttle.Context = .{}; // a thread's own context needs no stack
var ping: shuttle.Context = undefined;

fn pinger(_: ?*anyopaque, message: ?*anyopaque) callconv(.c) noreturn {
    var n = @intFromPtr(message); // safe: the example sends counts
    while (true) n = @intFromPtr(shuttle.switchTo(&ping, &main_context, @ptrFromInt(n + 1))); // safe: as above
}

fn context() !void {
    var stack = try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) });
    defer stack.deinit();
    ping = try shuttle.Context.init(&stack, pinger, null); // the stack stays yours
    defer ping.deinit(&stack);
    const back = shuttle.switchTo(&main_context, &ping, @ptrFromInt(41)); // safe: a count
    std.debug.assert(@intFromPtr(back) == 42); // safe: a count
}
```
<!-- END GENERATED -->

A job system takes its stacks from a `Pool` and switches with the handoff: a
context that parks itself is published by the context it switched to, once
its registers are saved, so another thread can take it at once. The queues
and the workers stay the caller's:

<!-- BEGIN GENERATED zig build docs -- jobs -->
```zig
const shuttle = @import("shuttle");

const Job = struct {
    context: shuttle.Context,
    stack: shuttle.Stack,
    /// Whoever switched to the job, to switch back to.
    worker: *shuttle.Context = undefined,
    done: bool = false,
};

fn work(arg: ?*anyopaque) noreturn {
    const job: *Job = @ptrCast(@alignCast(arg.?)); // safe: the job passes itself
    // ... the job's work, parking with handoff.switchTo as it waits ...
    shuttle.handoff.switchTo(&job.context, job.worker, .{ .run = finished });
    unreachable; // unreachable: a finished job is never switched to again
}

/// Runs on the worker once the job's registers are saved: from here on
/// another thread could take the job, or its stack could be given back.
fn finished(_: ?*anyopaque, from: *shuttle.Context) void {
    const job: *Job = @fieldParentPtr("context", from);
    job.done = true;
}

fn jobs() !void {
    const gpa = std.heap.page_allocator;
    var pool = try shuttle.Pool.init(gpa, .{ .classes = &.{
        .{ .size = .fromRaw(64 * 1024), .count = 128 },
        .{ .size = .fromRaw(1024 * 1024), .count = 8 },
    } });
    defer pool.deinit(gpa);
    var worker: shuttle.Context = .{};
    var job: Job = .{ .context = undefined, .stack = pool.take(.fromRaw(16 * 1024)).?, .worker = &worker };
    job.context = try .init(&job.stack, shuttle.handoff.entry(work), &job);
    shuttle.handoff.switchTo(&worker, &job.context, null);
    std.debug.assert(job.done);
    job.context.deinit(&job.stack);
    pool.give(job.stack);
}
```
<!-- END GENERATED -->

A coroutine's panic is handed to the code that ran it, and a stack overflow
is named, once the program's root installs shuttle's handlers:

```zig
pub const panic = shuttle.panic;
pub const debug = struct {
    pub const handleSegfault = shuttle.handleSegfault;
};
```

## Design

A switch is a few instructions of inline assembly. They save the stack
pointer, the frame pointer, where to resume, the link register (aarch64,
riscv64) and the floating-point control state (MXCSR and the x87 control word,
FPCR, fcsr), and load the other context's. Every other register is declared
clobbered, so the compiler keeps what it needs across the switch the way it
does across a call: it saves only what is live there. A clobber counts only
by a name the compiler takes for the register on that CPU: the vector
registers are named `xmm`, `ymm` and `zmm`, since `zmm` alone means nothing
without AVX-512, and the aarch64 link register is kept by the assembly itself,
not left to a clobber. On Windows a switch also moves the thread information
block's stack bounds to the stack it runs next, so the system grows that stack
through its guard page, raises its own stack overflow there, and walks it.

A new context starts in a trampoline whose unwind table says nothing called
it, under 64 zeroed bytes: debuggers, std's unwinder and shuttle's own traces
end at a context's first frame. A stack is reserved address space with a
guard below it; on Windows its pages are committed as it grows. A `Pool`
reserves its stacks in size classes, each with its own guard, and hands them
out and takes them back from any thread without allocating. ThreadSanitizer
is told about every context and every switch, and Valgrind about every stack.

A coroutine's panic cannot unwind it, as Zig unwinds nothing: the handler
records the message and the coroutine's trace and switches out of it for
good, and the code that ran it panics with it, or gets `error.Panicked`. Ending
a suspended coroutine cancels it: its `yield` fails with `error.Canceled`, so
its `try` unwinds it through its defers.

## API

| Call | Does |
|---|---|
| `Stack.init(.{ .size, .guard, .commit })`, `stack.deinit()` | A stack of its own: usable bytes, a guard below them, and on Windows what is committed at first |
| `stack.carve(len, alignment)`, `stack.discard(keep_from)` | Takes bytes from the top for what lives as long as the stack; gives pages below a point back to the system |
| `Pool.init(gpa, .{ .classes, .guard, .commit })`, `pool.deinit(gpa)` | Stacks in size classes, reserved once |
| `pool.take(size)`, `pool.give(stack)` | The smallest class that fits and has a stack free, or null; a stack back. Any thread |
| `pool.takeExactly(size)`, `pool.number(stack)`, `pool.stackOf(n)`, `pool.count()`, `pool.inUse()` | Only the smallest class that fits; a stack's stable number among all the pool's, and the stack a number names, so a holder keeps only the number; how many it holds; how many are out |
| `Context.init(&stack, entry, arg)`, `context.deinit(&stack)` | A context that runs `entry(arg, message)` on `stack` when first switched to; ended, its stack free again |
| `switchTo(from, to, message)` | Saves the running context into `from`, runs `to`, and returns the message of the switch that resumes `from` |
| `context.trace(&stack, out)`, `context.traceFrom(&stack, first, out)`, `context.stackPointer()` | A context's return addresses to its first frame, running or suspended, from the caller or from a kept call site; where a suspended one's stack ends |
| `handoff.switchTo(from, to, after)`, `handoff.entry(body)` | A switch whose `after` runs on the side switched to once `from` is saved; the entry of a context switched to that way |
| `Coroutine(Input, Yield, Return)` | `init(stack, body, args)`, `next(input)`, `tryNext(input)`, `state()`, `done()`, `panicked()`, `deinit()` |
| `Coroutine(...).Yielder.yield(value)` | Hands `value` to the code running the coroutine and returns its next input, or `error.Canceled` |
| `Generator(Yield, Error)` | `init(stack, body, args)`, `next()` (each value, then null or the body's error), `deinit()` |
| `Panic` | A coroutine's panic: `message()`, `returnAddresses()`, `cause`, `raise()` |
| `panic`, `handleSegfault` | The handlers a program's root installs |
| `overflow.diagnose(address, context)` | Whether a fault is a stack overflow, and on whose stack |
| `supported` | Whether shuttle switches contexts on this target |

## Scope

- No scheduler: queues, wait lists, worker threads and I/O are the caller's.
- No unwinding past a panic: Zig has none. A canceled coroutine unwinds
  through the errors its `yield` returns.
- No AddressSanitizer annotations: Zig has no AddressSanitizer.
- No shadow stacks (x86 CET) and no pointer authentication or branch target
  identification (arm64e, BTI): a switch jumps where those would refuse it.
- No 32-bit targets.
- shuttle's contexts are not Win32 fibers: fiber local storage and
  `GetCurrentFiber` belong to the thread.

## Platforms

| | Linux | macOS | Windows | FreeBSD, NetBSD |
|---|---|---|---|---|
| x86_64 | tests run | compiled and linked | tests run | compiled |
| aarch64 | compiled | tests run | compiled and linked | |
| riscv64 | compiled | | | |

CI runs the tests in Debug on every landing, with the switch's tests again in
ReleaseFast without frame pointers, and in ReleaseSafe and ReleaseFast every
night, with ThreadSanitizer on x86_64 Linux. aarch64 Linux and riscv64 Linux
compile in CI and are not run there.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library, and
  [aegis](https://github.com/pedronaugusto/aegis) for checked sizes.
- [bay](https://github.com/pedronaugusto/bay) runs shuttle's development.
  [preflight](https://github.com/pedronaugusto/preflight) (the source checks,
  the tests and CI) and [shakedown](https://github.com/pedronaugusto/shakedown)
  (the properties and the benchmarks) are dev dependencies through bay, which a
  project that depends on shuttle never sees.

## Testing

`bay test` runs the suite, the fault program, the usage example and each
benchmark once. The switch is proven one register class at a time: the test's
own assembly holds a pattern in every register a call keeps (general, vector,
the frame pointer), calls into a switch to a context that overwrites every
register it can, and reads them back. A third test holds a floating-point
control state on each side and checks that each gets its own back. Two more
check the values the compiler itself keeps in registers across a switch.
Removing one class from the clobber list, or the control state from the
assembly, fails its test.

Contexts are run between threads, and a job system's core runs on four
workers, each job parking itself on the next worker's queue through the
handoff. Traces end at a context's first frame, std's unwinder included.
Properties run random programs against a model (a pool's classes; coroutines
run, canceled and replaced in any order) on every run, and under `bay
properties --fuzz` they search further. The fault program installs shuttle's
handlers and checks, in child processes, that a coroutine's panic reaches the
code that ran it (caught, and through a coroutine that ran it in turn) and
that a stack overflow is stopped by the guard and named.

`bay bench` times a switch and a handoff each way, a coroutine's `next` and
`yield`, a generator's value, and making a context on a stack of its own and
on a pool's, in ReleaseFast. Run from `zig-out/bench`, `shuttle-bench` prints
JSON lines; CI times nothing.

## Licence

MIT. See [LICENSE](LICENSE).
