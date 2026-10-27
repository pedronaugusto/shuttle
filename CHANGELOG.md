# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A switch on Windows no longer runs code on a stack the thread information block does not describe. It set the next stack's bounds, then made calls on the stack it was leaving; a call that first touched that stack's guard page was not grown by the system but raised a guard page violation no handler took, which ended the process with no message (0xC0000005 or a bare exit code). It took a switch from a stack to one below it, at the depth in a page where the switch's own calls reached a page nothing above it had: uplink's HTTP/2 server tests on reactor's Windows runtime, Debug builds, ended so. The switch's assembly now exchanges the bounds as it moves the stack pointer (`teb.Exchange`), on x86_64 and aarch64.

## [0.4.0] - 2026-10-27

### Breaking

- `Context.inside` and `Context.runningInside()` are a `?*Context`, where they were an erased pointer: the context of the coroutine whose code runs on a context, which names itself. A coroutine finds itself from it with `@fieldParentPtr`.
- `Stack.carve(T)` takes a type and returns a `*T` aligned for it, where it took a length and an alignment and returned bytes.
- `Pool.in_use` is an aegis atomic cell of a count of stacks; `inUse()` reads it as before.

### Changed

- On aegis 0.2.1, under the aegis pack: a coroutine's life (fresh, running, suspended, returned, panicked) is an aegis state machine; its body is handed a `Yielder` that holds the coroutine, and its arguments sit beside it in one frame carved from the stack, so the entry is told where both are in its one argument; the pool's counters, its lists' heads and links are aegis atomic cells; a panic's trace is copied out rather than cast to the mutable slice std's writer names. The processor's and the system's seams (the switch, the first frame's entry, the control registers, the thread information block, the system's pages, ThreadSanitizer's fibers, frame records) carry their contract where they are.

## [0.3.3] - 2026-10-24

### Changed

- Pins aegis 0.1.17.

## [0.3.2] - 2026-10-21

### Fixed

- A coroutine whose code moved threads (its body suspended in a runtime's `Io` call and resumed on another thread, as reactor moves tasks) is the running coroutine on the thread it runs on: its panic is handed to the code that ran it, where it ended the process with std's handler, and an overflow of its stack is named as the coroutine's. What the running code runs inside now belongs to the context: every switch saves the thread's into the context it leaves and installs the one it resumes (`Context.inside`, read by `Context.runningInside`). A switch round trip costs about 1 ns more through `handoff` (7.2 to 8.4 ns on an M3); `coroutine/next` is 3 ns faster, as `enter` no longer sets and restores the slot itself.

## [0.3.1] - 2026-10-21

### Changed

- aegis 0.1.14 (from 0.1.12), which preflight 0.12.1 selects.
- Development: preflight 0.12.1, and the lint gates the aegis pack, glint's A001-A005 (A004 already).

### Fixed

- Development: the test of a context resumed on another thread no longer keeps a pointer to a thread's frame after it returns (glint's E001); the pointer was not read after, so nothing failed.

## [0.3.0] - 2026-10-17

### Breaking

- A pool makes a stack usable the first time it hands it out, not at `init`: `Pool.init` reserves every stack's address space in one mapping that faults on any access and does nothing per stack, so a pool of 16,384 stacks is one mapping with no page tables, where guarding each took 9 ms on a Mac and 16.5 ms on Linux, about 8 MiB of page tables, and as long again to release (reactor's `init` on its defaults: 7 ms to 0.7 on a Mac, 18 ms to 0.8 on Linux). A stack made usable (committed as touched, its guard below it) stays so for the pool's life. `take` and `takeExactly` return `TakeError!?Stack`: null when no stack is free, as before, and `error.SystemResources` when the system refused to make a fresh one usable (strict overcommit, `vm.max_map_count`, the Windows commit limit); the stack stays in the pool and a later `take` tries it again.
- `Stack.prepare(commit, guard)` takes what guards the stack (`Stack.Guard`: the reservation's no-access pages, or a Linux guard region); a stack's reservation is no-access until prepared, everywhere.
- `Pool.per_slab` is gone: a pool's stacks are one reservation.

### Added

- `Pool.reached()`: how many stacks were ever handed out, the ones that cost more than address space.

### Changed

- Pins preflight 0.8.2 for development, and aegis 0.1.12.

## [0.2.4] - 2026-10-17

### Fixed

- The trace test expected a frame below a context's entry, which the trampoline's call leaves everywhere but on Windows, where it branches in: a suspended context's trace is now held to be the running one less the frame that called `trace` (the windows-11-arm nightly's red).

## [0.2.3] - 2026-10-15

### Fixed

- A coroutine's `enter` takes its thread's slot afresh after the switch back: the compiler could reuse the slot's address computed before the switch, which on aarch64 is a register read it merges, so a runtime that moved the task running the coroutine to another thread meanwhile (reactor's) wrote the thread it left. The slot now passes through an assembly statement, as reactor's seat does; `running` reads it the same way.

## [0.2.2] - 2026-10-14

### Changed

- Pins aegis 0.1.8.

## [0.2.1] - 2026-10-14

### Changed

- Pins aegis 0.1.6.

## [0.2.0] - 2026-10-13

### Breaking

- A `Context` is what a switch saves and no more: its registers, on Windows the stack bounds, under ThreadSanitizer its fiber. 40 bytes on aarch64 where it was 112, 32 on x86_64 where it was 104, 56 on Windows x64 where it was 128: a scheduler that keeps a context in each task's record keeps 72 bytes less of it hot. The stack it runs on is its maker's, and the calls that need it are given it: `Context.init(&stack, entry, arg)` (on Windows `stack` learns what was committed for the first frame), `context.deinit(&stack)`, which returns nothing (on Windows `stack` learns what the context's code committed), `context.trace(&stack, out)` and `context.traceFrom(&stack, first, out)`. A coroutine's stack is its `Core.stack` field, where it was `Core.stack()`.

### Added

- `Pool.stackOf(n)`: the stack a number (`Pool.number`) names, as `take` handed it out, so a holder keeps only the number and describes the stack again to give it back.

### Changed

- A pool tells Valgrind of each of its stacks once, for the pool's life, where it did at each `take` and `give`: a stack described again by its number carries no registration.
- The tests run in the `shuttle` module itself, which gets shakedown for them: a shakedown that links shuttle takes this copy, so a test binary holds one shuttle.

## [0.1.1] - 2026-10-13

### Added

- `Pool.takeExactly`: a stack of the smallest class that fits and of no other, for a scheduler that keeps its larger stacks for the work that asked for them.
- `Pool.number`, `Pool.count` and `Pool.inUse`: each stack's number among all the pool's, stable for the pool's life, for tables kept beside it; how many it holds; how many are handed out.
- `Context.traceFrom`: a context's trace from a call site the caller kept.

### Changed

- `handoff.switchTo` is inline, as `switchTo` is: a call returned to from another context costs the return predictor a miss.

### Fixed

- `Pool.sizes` reads each class in place: it copied them, their free lists' atomic heads included, which a take or a give on another thread could be writing.
- The 0.1.0 section of this changelog listed the first release under Breaking; it is Added.

## [0.1.0] - 2026-10-13

### Added

- `Context` and `switchTo`: a symmetric switch with a message each way, inline, keeping what a call keeps on x86_64 (System V and Windows), aarch64 (Linux, Apple and Windows) and riscv64, the floating-point control state included (MXCSR and the x87 control word, FPCR, fcsr). The vector registers are named as LLVM takes them without AVX-512 (`xmm`, `ymm`, `zmm`); the aarch64 link register is kept by the assembly. On Windows the switch moves the thread information block's stack bounds.
- A first frame whose unwind table ends every walk there, under zeroed bytes; `Context.trace`, a frame walk bounded by the context's stack, running or suspended.
- `Stack`: a guard below every stack (a guard region on Linux 6.13 and later), Windows pages committed as the stack grows, Valgrind told of each stack; `carve`, `reach`, `discard`.
- `Pool`: stacks in size classes, each with its own guard, taken and given back from any thread without allocating; refuses a count that would reach Linux's `vm.max_map_count`.
- `handoff`: a switch whose `after` runs on the side switched to once the side that switched is saved, for publishing a context to another thread or giving back a finished one's stack.
- `Coroutine(Input, Yield, Return)`: values both ways, its state and arguments at the top of its stack, cancellation through the body's defers when a suspended one is ended, and a panic handed to the code that ran it (`next` panics with it, `tryNext` returns `error.Panicked`).
- `Generator(Yield, Error)`: a coroutine read as an iterator.
- `panic` and `handleSegfault`: the handlers that hand a coroutine's panic over, with each coroutine's trace, and name a stack overflow.
- ThreadSanitizer told of every context and switch.
- Pins aegis 0.1.3.
