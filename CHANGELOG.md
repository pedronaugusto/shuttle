# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-13

### Breaking

- The first release. Below 1.0 a minor release may change what the one before it shipped; this one starts the line at 0.1.0.

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
