//! Stacks in size classes, reserved once and handed out again and again,
//! from any thread, without allocating or making a system call after the
//! first time a stack is handed out.
//!
//! `init` reserves the address space of every stack of every class as one
//! mapping that faults on any access, and does nothing per stack: that
//! reservation and the classes' counts are what it guarantees. No later step
//! fails for address space, and a pool of thousands of stacks starts in
//! microseconds, holding no page tables. A stack is made usable the first
//! time it is handed out (`Stack.prepare`: its bytes readable and writable,
//! committed as they are touched, or on Windows its top committed; its guard
//! below it) and stays so for the pool's life: one given back is handed out
//! again as it is.
//!
//! Making a stack usable can fail mid-run, where the system refuses the
//! charge (Linux under strict overcommit or at `vm.max_map_count`, Windows
//! at its commit limit). `take` then returns `error.SystemResources`, and
//! the stack stays in the pool, to be tried again by a later `take`.
//!
//! Every stack has its own guard below it. One guard per class is not
//! enough: Zig emits no stack probes on aarch64, nor on x86_64 in
//! ReleaseFast, so a large frame would step over a shared guard into the
//! next stack unseen. On Linux 6.13 and later the guard is a guard region
//! and stacks made usable side by side make one mapping; elsewhere it is the
//! reservation's own no-access pages, and each stack made usable is a
//! mapping of its own beside one of them: on Linux two entries per stack
//! against `vm.max_map_count`, so `init` refuses a count that could reach the
//! limit rather than fail later.
//!
//! Free stacks are a lock-free stack of indices, tagged against reuse, and
//! the last stack given back is the first handed out, so the stacks in use
//! stay the warm ones; a stack on it is usable, so taking one is a pop and
//! nothing more. Only when none is free does `take` make one: a stack the
//! system refused before (kept on a list of its own), else one never handed
//! out.
const Pool = @This();

const builtin = @import("builtin");
const std = @import("std");
const memory = @import("memory.zig");
const Stack = @import("Stack.zig");

const Bytes = Stack.Bytes;
const is_windows = builtin.os.tag == .windows;

pub const Class = struct {
    /// Usable bytes of each stack, rounded up to whole pages.
    size: Bytes,
    count: u32,
};

pub const Options = struct {
    /// The classes, in any order; no two of the same size.
    classes: []const Class,
    /// Bytes of guard below each stack, as `Stack.Options.guard`.
    guard: ?Bytes = null,
    /// Windows: bytes committed when a stack is first handed out, as
    /// `Stack.Options.commit`.
    commit: ?Bytes = null,
};

pub const InitError = error{
    OutOfMemory,
    SystemResources,
    Overflow,
    /// Two classes of one size, or more classes than a stack can name.
    InvalidClasses,
    /// More stacks than Linux's `vm.max_map_count` lets a process map.
    TooManyStacks,
};

pub const TakeError = error{
    /// The stack's first hand-out could not make it usable: the system
    /// refused to commit its memory or to install its guard. The stack
    /// stays in the pool, to be tried again.
    SystemResources,
};

classes: []Shelf,
/// Every stack's address space, all classes' in one mapping.
reservation: memory.Pages,
guard: Stack.Guard,
/// Stacks handed out and not given back.
in_use: std.atomic.Value(u32) = .init(0),

/// One class's stacks.
const Shelf = struct {
    layout: Stack.Layout,
    count: u32,
    /// The number of the class's first stack among all the pool's.
    first: u32 = 0,
    /// The lowest byte of the class's stacks, in the pool's reservation.
    base: usize = 0,
    /// Per stack, the next on its list, plus one; zero ends the list.
    links: []u32,
    /// Stacks made usable and given back: what `take` hands out first,
    /// as they are.
    free: List = .{},
    /// Stacks the system refused to make usable, to be tried again.
    unmade: List = .{},
    /// The stacks from this one up have never been handed out.
    fresh: std.atomic.Value(u32) = .init(0),
    /// Windows: per stack, its lowest committed byte. Only the stack's
    /// holder touches its entry, and only stacks below `fresh` have one.
    limits: if (is_windows) []usize else void,
    /// Under Valgrind, each stack's registration, made when it is first
    /// made usable and kept for the pool's life; empty elsewhere.
    valgrind: []usize,

    fn init(gpa: std.mem.Allocator, class: Class, options: Options) InitError!Shelf {
        const layout = try Stack.Layout.of(.{ .size = class.size, .guard = options.guard, .commit = options.commit });
        const links = try gpa.alloc(u32, class.count);
        errdefer gpa.free(links);
        const limits = if (is_windows) try gpa.alloc(usize, class.count) else {};
        errdefer if (is_windows) gpa.free(limits);
        var valgrind: []usize = &.{};
        if (std.valgrind.runningOnValgrind() > 0) {
            valgrind = try gpa.alloc(usize, class.count);
            @memset(valgrind, 0);
        }
        return .{ .layout = layout, .count = class.count, .links = links, .limits = limits, .valgrind = valgrind };
    }

    fn deinit(s: *Shelf, gpa: std.mem.Allocator) void {
        for (s.valgrind) |id| if (id != 0) std.valgrind.stackDeregister(id);
        if (s.valgrind.len > 0) gpa.free(s.valgrind);
        gpa.free(s.links);
        if (is_windows) gpa.free(s.limits);
    }

    /// The bytes of all the class's stacks.
    fn span(s: *const Shelf) error{Overflow}!usize {
        return (Bytes.fromRaw(s.layout.reserved).mul(s.count) catch return error.Overflow).raw();
    }

    fn stack(s: *const Shelf, class: u16, index: u32) Stack {
        const base = s.base + @as(usize, index) * s.layout.reserved; // safe: inside the class's span, laid out by stride
        const bottom = base + s.layout.guard;
        return .{
            .base = base,
            .bottom = bottom,
            .top = base + s.layout.reserved,
            .end = base + s.layout.reserved,
            .limit = if (is_windows) s.limits[index] else bottom,
            .slot = .{ .class = class, .index = index },
        };
    }

    /// A stack never handed out, now the caller's, or null when none is
    /// left.
    fn claim(s: *Shelf) ?u32 {
        var next = s.fresh.load(.monotonic);
        while (next < s.count) {
            next = s.fresh.cmpxchgWeak(next, next + 1, .monotonic, .monotonic) orelse return next;
        }
        return null;
    }
};

/// A lock-free stack of a class's stack indices, linked through the
/// class's `links`, its head tagged against reuse.
const List = struct {
    head: std.atomic.Value(u64) = .init(0),

    fn pop(l: *List, links: []u32) ?u32 {
        var raw = l.head.load(.acquire);
        while (true) {
            const f: Free = @bitCast(raw);
            if (f.index_plus_one == 0) return null;
            const index = f.index_plus_one - 1;
            const next: Free = .{ .index_plus_one = @atomicLoad(u32, &links[index], .monotonic), .tag = f.tag +% 1 };
            raw = l.head.cmpxchgWeak(raw, @bitCast(next), .acq_rel, .acquire) orelse return index;
        }
    }

    fn push(l: *List, links: []u32, index: u32) void {
        var raw = l.head.load(.monotonic);
        while (true) {
            const f: Free = @bitCast(raw);
            @atomicStore(u32, &links[index], f.index_plus_one, .monotonic);
            const next: Free = .{ .index_plus_one = index + 1, .tag = f.tag +% 1 };
            raw = l.head.cmpxchgWeak(raw, @bitCast(next), .release, .monotonic) orelse return;
        }
    }
};

const Free = packed struct(u64) { index_plus_one: u32, tag: u32 };

pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Pool {
    if (options.classes.len > std.math.maxInt(u16)) return error.InvalidClasses;
    const shelves = try gpa.alloc(Shelf, options.classes.len);
    errdefer gpa.free(shelves);
    var made: usize = 0;
    errdefer for (shelves[0..made]) |*s| s.deinit(gpa);
    for (options.classes, shelves) |class, *s| {
        s.* = try .init(gpa, class, options);
        made += 1;
    }
    std.mem.sort(Shelf, shelves, {}, struct {
        fn less(_: void, a: Shelf, b: Shelf) bool {
            return a.layout.usable < b.layout.usable;
        }
    }.less);
    for (shelves[1..], shelves[0..shelves.len -| 1]) |s, before| if (s.layout.usable == before.layout.usable) return error.InvalidClasses;
    var total: u32 = 0;
    var bytes: usize = 0;
    for (shelves) |*s| {
        s.first = total;
        total = std.math.add(u32, total, s.count) catch return error.TooManyStacks;
        bytes = std.math.add(usize, bytes, try s.span()) catch return error.Overflow;
    }
    const guard: Stack.Guard = if (memory.guardRegions()) .region else .reserved;
    try checkMapCount(total, guard);
    const reservation: memory.Pages = if (bytes == 0) &.{} else try memory.reserve(bytes);
    var offset: usize = @intFromPtr(reservation.ptr); // safe: an address, to lay the classes out
    for (shelves) |*s| {
        s.base = offset;
        offset += s.span() catch unreachable; // unreachable: summed above without overflow
    }
    return .{ .classes = shelves, .reservation = reservation, .guard = guard };
}

/// Releases every stack. None may be in use.
pub fn deinit(p: *Pool, gpa: std.mem.Allocator) void {
    std.debug.assert(p.inUse() == 0);
    for (p.classes) |*s| s.deinit(gpa);
    gpa.free(p.classes);
    if (p.reservation.len > 0) memory.release(p.reservation);
    p.* = undefined;
}

/// A stack of at least `size` usable bytes: from the smallest class that
/// has one free. Null when every class that fits is in use. A class whose
/// free stack could not be made usable is passed over for a larger one;
/// `error.SystemResources` when none could be had and one was refused.
pub fn take(p: *Pool, size: Bytes) TakeError!?Stack {
    for (p.classes, 0..) |*s, class| {
        if (Bytes.fromRaw(s.layout.usable).compare(size) == .lt) continue;
        if (s.free.pop(s.links)) |index| return p.handOut(@intCast(class), index); // safe: `init` refuses more classes than a u16 names
        return p.makeFrom(@intCast(class)); // safe: as above
    }
    return null;
}

/// A stack of the smallest class with at least `size` usable bytes, and of
/// no other: null when that class has none free, or none is that large. For
/// a scheduler that keeps its larger stacks for the work that asked for
/// them.
pub fn takeExactly(p: *Pool, size: Bytes) TakeError!?Stack {
    for (p.classes, 0..) |*s, class| {
        if (Bytes.fromRaw(s.layout.usable).compare(size) == .lt) continue;
        if (s.free.pop(s.links)) |index| return p.handOut(@intCast(class), index); // safe: `init` refuses more classes than a u16 names
        return p.make(@intCast(class)); // safe: as above
    }
    return null;
}

/// `take` once `first`, the smallest class that fits, has none given
/// back: a stack made in it, else the next class's, and so on. Out of the
/// way of `take`, whose own code stays a pop.
fn makeFrom(p: *Pool, first: u16) TakeError!?Stack {
    @branchHint(.cold);
    var refused = false;
    for (p.classes[first..], first..) |*s, at| {
        const class: u16 = @intCast(at); // safe: `init` refuses more classes than a u16 names
        if (class != first) if (s.free.pop(s.links)) |index| return p.handOut(class, index);
        const stack = p.make(class) catch {
            refused = true;
            continue;
        };
        return stack orelse continue;
    }
    return if (refused) error.SystemResources else null;
}

/// None given back: a stack refused before, or one never handed out, made
/// usable now.
fn make(p: *Pool, class: u16) TakeError!?Stack {
    const s = &p.classes[class];
    const index = s.unmade.pop(s.links) orelse s.claim() orelse return null;
    var stack = s.stack(class, index);
    stack.prepare(s.layout.commit, p.guard) catch {
        s.unmade.push(s.links, index);
        return error.SystemResources;
    };
    if (is_windows) s.limits[index] = stack.limit;
    // Valgrind is told of the stack once: a stack handed out is described
    // by its number alone, and carries no registration.
    if (s.valgrind.len > 0) {
        stack.register();
        s.valgrind[index] = stack.valgrind;
    }
    return p.handOut(class, index);
}

fn handOut(p: *Pool, class: u16, index: u32) Stack {
    _ = p.in_use.fetchAdd(1, .monotonic);
    return p.classes[class].stack(class, index);
}

/// Gives back a stack `take` handed out, or one `stackOf` described. Nothing
/// may run on it.
pub fn give(p: *Pool, stack: Stack) void {
    const s = stack;
    const slot = s.slot.?;
    const shelf = &p.classes[slot.class];
    if (is_windows) shelf.limits[slot.index] = @min(shelf.limits[slot.index], s.limit);
    shelf.free.push(shelf.links, slot.index);
    // Zero publishes the last give after it stopped touching the pool.
    _ = p.in_use.fetchSub(1, .release);
}

/// The stacks handed out and not given back.
pub fn inUse(p: *const Pool) u32 {
    return p.in_use.load(.acquire);
}

/// The stacks ever handed out, or tried: those that cost more than address
/// space. At most `count()`.
pub fn reached(p: *const Pool) u32 {
    var n: u32 = 0;
    for (p.classes) |*s| n += s.fresh.load(.monotonic);
    return n;
}

/// How many stacks the pool holds, all classes together.
pub fn count(p: *const Pool) u32 {
    if (p.classes.len == 0) return 0;
    const last = p.classes[p.classes.len - 1];
    return last.first + last.count;
}

/// A stack's number among all the pool's, below `count()` and the same for
/// as long as the pool lives: what a table kept beside the pool, one entry a
/// stack, is indexed by.
pub fn number(p: *const Pool, stack: Stack) u32 {
    const slot = stack.slot.?;
    return p.classes[slot.class].first + slot.index;
}

/// The stack numbered `n` (`number`) of a stack `take` handed out, as it
/// handed it out: a holder that keeps only the number describes its stack
/// again with this, to give it back or to look at its bounds.
pub fn stackOf(p: *const Pool, n: u32) Stack {
    for (p.classes, 0..) |*s, class| {
        if (n >= s.first and n - s.first < s.count) return s.stack(@intCast(class), n - s.first); // safe: `init` refuses more classes than a u16 names
    }
    unreachable; // unreachable: a number is below `count()`
}

/// The usable size of each class, smallest first.
pub fn sizes(p: *const Pool, out: []Bytes) []Bytes {
    const n = @min(out.len, p.classes.len);
    for (p.classes[0..n], out[0..n]) |*s, *o| o.* = .fromRaw(s.layout.usable);
    return out[0..n];
}

fn checkMapCount(total: u32, guard: Stack.Guard) error{TooManyStacks}!void {
    // Guard regions split nothing: stacks made usable side by side are one
    // mapping. Otherwise each is a mapping of its own beside a no-access
    // one. Room is left for everything else in the process.
    if (guard == .region) return;
    const limit = memory.maxMapCount() orelse return;
    const needed: u64 = 4096 + 1 + 2 * @as(u64, total);
    if (needed > limit) return error.TooManyStacks;
}
