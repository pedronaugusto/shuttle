# Architecture

shuttle owns switching between stacks and the stacks themselves: the switch
for each architecture and ABI, the first frame of a context, stacks with
guards, pools of them, and the coroutines, generators and handoff built on
the switch. Scheduling is the caller's. Its runtime closure is shuttle → aegis
→ std.

This describes the implementation in this repository. Change it with the code
when an owner, an invariant or a decision changes.

## Layers and owners

[ci/layers.zig](../ci/layers.zig) checks the production import graph. Layers
are ordered lowest first; imports stay within a layer or go down. Paths are
under `src/`.

| Layer | Files and responsibility |
|---|---|
| Platform | `memory.zig` reserves, commits, guards and releases address space; `teb.zig` reads and writes the Windows thread information block's stack fields; `sanitizer.zig` is ThreadSanitizer's fiber interface; `arch/x86_64.zig`, `arch/aarch64.zig` and `arch/riscv64.zig` own each architecture's switch, control state, first frame and trampoline. |
| The switch | `arch.zig` picks this architecture's. |
| Traces and stacks | `trace.zig` walks frame records inside given bounds; `Stack.zig` owns one stack: its layout, guard, Windows commit and Valgrind registration. |
| Pools and contexts | `Pool.zig` owns size classes of stacks in one reservation, their free lists, which stacks have been made usable, and their Valgrind registrations for the pool's life; `Context.zig` owns a context's saved state and `switchTo`. A context is what a switch saves and no more (registers; on Windows the stack bounds; under ThreadSanitizer the fiber): the stack it runs on is its maker's, and `init`, `deinit` and the traces are given it, so a scheduler that keeps thousands of contexts keeps only a stack's number beside each (`Pool.number`, `Pool.stackOf`). |
| Handoff and panics | `handoff.zig` owns the switch whose other side finishes it; `Panic.zig` owns a coroutine's recorded panic and its printing. |
| Coroutines | `coroutine.zig` owns `Coroutine`, the thread's running coroutine and the panic handler. |
| Generators and overflows | `generator.zig` wraps a coroutine as an iterator; `overflow.zig` names a stack overflow. |
| Public | `shuttle.zig`. |

## The switch

`switchTo` is inline: a switch costs what the code around it holds in
registers. A call to a switch and its return go to and from different
contexts, so each costs the return predictor a miss, which measured four
times the switch itself.

The assembly saves, into the context switching away, and loads, from the one
switched to:

| | Saved by the assembly | Saved by the compiler, as clobbered | Never touched |
|---|---|---|---|
| x86_64 System V | rsp, rbp, resume address, MXCSR, x87 control word | rbx, r12–r15 | fs, gs |
| x86_64 Windows | as System V | rbx, rdi, rsi, r12–r15, xmm6–xmm15 | gs |
| aarch64 (Linux, Apple, Windows) | sp, x29, x30, resume address, FPCR | x19–x28, d8–d15 | x18 where it is the platform register (Apple, Windows) |
| riscv64 | sp, s0, ra, resume address, fcsr (with F) | s1–s11, fs0–fs11 | gp, tp |

Every other register is declared clobbered, and LLVM takes a clobber only by a
name it knows for that register on that CPU. The vector registers are named
`xmm`, `ymm` and `zmm`: without AVX-512 there is no `zmm`, the clobber is
dropped, and values in `xmm` registers did not survive a switch (on Windows,
`xmm6`–`xmm15`, which a call keeps, were left to the next context). The
aarch64 link register is kept by the assembly: LLVM takes its clobber only as
`lr`, drops `x30`, and optimized code once kept a pointer in x30 across a
switch. x18 is named only where LLVM allocates it. An input register is never
also named as a clobber: LLVM then dropped the move into it in optimized
builds. The transfer register is the switch's one output, tied to its input.

The floating-point control state is callee-saved under System V and Windows
(MXCSR's control bits and the x87 control word) and belongs to the thread
under AAPCS64 and the RISC-V ABI (FPCR, fcsr). A context is a thread of
control as far as its code can tell, so each keeps its own. A new context starts with the state of
the thread that made it. The control registers are written only when the two
contexts' states differ: writing them costs more than the comparison.

A switch carries a message each way: the switching side passes a pointer to a
transfer on its stack, and the resumed side reads it at once, while the
switching side is suspended. On Windows a switch saves the thread information
block's stack base, limit and deallocation stack into the context it leaves
and loads the next one's.

### The first frame

A context's stack holds, from its top down, whatever was carved from it (a
coroutine's state and arguments), 64 zeroed bytes, then the first frame: the
argument and the entry. The trampoline loads them, takes the first message
from the transfer, and calls the entry with the stack aligned as a call
leaves it (8 mod 16 on x86_64). Outside Windows its unwind table marks the
return address undefined, which is how DWARF says a frame has no caller; on
Windows, whose unwinder reads no table there, it jumps in with a zero return
address. Either way debuggers, std's unwinder and `trace.walk` end there; the
zeroed bytes keep an unwinder that reads past the outermost frame inside the
stack.

## Stacks

A stack is reserved address space: a guard below the usable bytes, then the
usable bytes. It is reserved so that any access faults, and made usable by
`Stack.prepare`. Elsewhere than Windows the usable bytes are made readable and
writable and the system commits each page as it is touched; the guard is the
reservation's own no-access pages, or, where Linux has guard regions (6.13 and
later), a guard region in committed memory, which splits no mapping. On Linux
the reservation is marked as a stack (no transparent huge pages, 6.7 and later)
and charged no swap; OpenBSD, which refuses a stack pointer into memory not
mapped as a stack and maps a stack only read-write, maps the usable bytes again
in place. On Windows the top pages are committed, with a guard page below them;
the system commits further pages as the stack grows, because the switch keeps
the thread information block's bounds on the running stack; the guard below
the stack is never committed, and reaching it raises the system's stack
overflow. `Stack.reach` commits what the thread making a context writes there,
since the system grows a stack only for the thread running on it.

Zig emits no stack probes on aarch64, nor on x86_64 in ReleaseFast: a frame
larger than the guard can step over it. `Options.guard` makes it larger.

### Pools

`Pool.init` guarantees the reservation and the counts, and does nothing per
stack: every stack of every class is laid out, each with its own guard, in one
mapping that faults on any access. No later step fails for address space, and
a pool of 16,384 stacks is one mapping holding no page tables (it was 9 ms on
a Mac and 16.5 ms on Linux, with about 8 MiB of page tables, when `init`
guarded every stack). A stack is made usable the first time it is
handed out and stays so for the pool's life, so taking it again makes no
system call; the stacks in use cost what their code touches, the rest cost
address space.

Making a stack usable can fail mid-run, where the system refuses the charge:
Linux under strict overcommit (the reservation is charged nothing; a commit
is charged), Linux at `vm.max_map_count`, Windows at its commit limit, or a
guard region the kernel cannot install. That is `error.SystemResources` from
`take`, never a crash: the stack goes back on the free list unmade, and the
next `take` tries it again. A scheduler maps the error to its spawn's
refusal (reactor: `error.ConcurrencyUnavailable`).

Free stacks are a lock-free stack of indices with a tag against reuse; the
last stack given back is the next handed out, so the stacks in use stay warm,
and a stack never handed out (each class's next, by an atomic counter) is
taken only when no stack given back is free, so the stacks a program has made
are the ones it uses. Without guard regions each stack made usable is a
mapping of its own beside a no-access one, about two entries per stack against
Linux's `vm.max_map_count`, so `init` refuses a count that could reach it;
with them stacks made side by side merge into one mapping. On Windows a stack
given back keeps what its code committed.

## Coroutines

A coroutine's state (its context, the context of whoever runs it, its value
slot and its panic record) and the body's arguments are carved from the top of
its stack, so `init` allocates nothing and the coroutine never moves. `next`
writes the input, switches in, and reads what the body yielded or returned.
`yield` writes the value and switches back. Ending a suspended coroutine sets
its cancel flag and runs it: `yield` returns `error.Canceled`, at once on
every later call, and the body's `try` returns through its defers.

### Panics

`shuttle.panic` is a std panic handler. When the panicking code runs on the
stack of the coroutine this thread runs, it copies the message (up to 256
bytes) and walks the coroutine's frames inside its stack, from the panic to its
first frame (up to 32), then switches out of the coroutine for good. Its stack
is not unwound: what it held, it holds still. `next` panics with the record
again through the program's handler, so a coroutine that ran it hands it on
in turn, each recording the one it came from as its cause; at the outermost
code the handler prints each coroutine's trace, innermost first, and std's
handler ends the process. `tryNext` returns `error.Panicked` instead.

### Stack overflow

`shuttle.handleSegfault` is a std segfault handler; std runs it on the
alternate signal stack it gives each thread. A fault in the guard below the
running coroutine's stack is that coroutine's overflow; a fault just around
the faulting code's stack pointer (within a page below it, or 256 KiB above)
is an overflow of whatever stack that is. Either is named, its frames walked
by frame record inside the stack and printed, and the process ends: std's
unwinder is not used on an overflowed stack, as on x86_64 macOS it walked one
without end. Any other fault goes to std's handler. On Windows the system
raises its own stack overflow, which std names.

## Moving between threads

A suspended context may be resumed on any thread, and a coroutine run from one
thread after another. What that asks of the code:

- **Publish only once saved.** A context that puts itself where another thread
  can take it (a run queue, a wait list) must not be visible there before its
  registers are saved, or that thread may resume it from half-written state.
  `handoff.switchTo` does the publishing on the side switched to, once the
  switch is complete; every switch to a context that takes part must be one of
  those, and every context made for it must start at `handoff.entry`.
- **One thread at a time.** A context or a coroutine runs on one thread at a
  time; resuming one twice at once is a race the switch does not prevent.
- **Thread-local variables.** The compiler may compute a thread-local
  variable's address before a switch and use it after; once a context may
  have moved, that address is the old thread's. Read thread-local state
  through a function the compiler does not inline after a switch that may move
  the context. shuttle's own thread-local state, what the running code runs
  inside (the running coroutine), belongs to the context, not the thread:
  every switch saves the thread's into the context it leaves (`inside`) and
  installs the one it resumes. A coroutine whose body a runtime suspended in
  an `Io` call and resumed on another thread is the running coroutine there,
  so its panic is handed back and its overflow named. A coroutine's own
  context names it; a context from `init` or `.{}` names nothing.
- **Thread-owned locks and state.** A mutex the OS ties to the thread that
  locked it, `errno`, `GetLastError` and a thread's signal mask belong to the
  thread, not to the context: do not hold such a lock across a switch that may
  move the context.
- **Windows.** The stack bounds move with the context. Fiber local storage,
  `SetThreadStackGuarantee` and anything else in the thread information block
  stay with the thread.
- **ThreadSanitizer.** Each switch is announced to it, synchronizing, so what
  the switching side wrote happens before what the resumed side reads,
  whichever thread it runs on.

## Not done

- A coroutine cannot be unwound past a panic, as Zig has no unwinding.
- Valgrind is told of every stack made usable, and CI runs no test under it.
- aarch64 Linux and aarch64 Windows compile in CI and are not run there:
  preflight's runners are x86_64 Linux and Windows and arm64 macOS.
- riscv64 is compiled only.
