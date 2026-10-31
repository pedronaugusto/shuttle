//! Stacks in size classes, reserved once and handed out again and again,
//! from any thread, without allocating or making a system call after the
//! first time a stack is handed out.
//!
//! `init` reserves the address space of every stack of every class as one
//! mapping that faults on any access, and does nothing per stack: that
//! reservation and the classes' counts are what it guarantees. No later step
//! fails for address space, and a pool of thousands of stacks costs a few
//! system calls, holding no page tables. A stack is made usable the first
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
const aegis = @import("aegis");
const memory = @import("memory.zig");
const Stack = @import("Stack.zig");
const native = @import("arch.zig").native;

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
in_use: aegis.Atomic(Stacks) = .init(.fromRaw(0)),

/// A number of stacks.
const Stacks = aegis.units.Count(struct {}, u32);

/// One class's stacks.
const Shelf = struct {
    layout: Stack.Layout,
    count: u32,
    /// The number of the class's first stack among all the pool's.
    first: u32 = 0,
    /// The lowest byte of the class's stacks, in the pool's reservation.
    base: usize = 0,
    /// Per stack, the next on its list, plus one; zero ends the list.
    links: []aegis.Atomic(Link),
    /// Stacks made usable and given back: what `take` hands out first,
    /// as they are.
    free: List = .{},
    /// Stacks the system refused to make usable, to be tried again.
    unmade: List = .{},
    /// The stacks from this one up have never been handed out.
    fresh: aegis.Atomic(Stacks) = .init(.fromRaw(0)),
    /// Windows: per stack, its lowest committed byte. Only the stack's
    /// holder touches its entry, and only stacks below `fresh` have one.
    limits: if (is_windows) []usize else void,
    /// Linux x86_64, when the thread making the pool has a shadow stack:
    /// per stack, its shadow stack (`native.shadowFor`), made with it and kept
    /// for the pool's life. Only the stack's holder touches its entry.
    shadows: if (native.shadow_stacks) []native.Shadow else void,
    /// Under Valgrind, each stack's registration, made when it is first
    /// made usable and kept for the pool's life; empty elsewhere.
    valgrind: []usize,

    fn init(gpa: std.mem.Allocator, class: Class, options: Options) InitError!Shelf {
        const layout = try Stack.Layout.of(.{ .size = class.size, .guard = options.guard, .commit = options.commit });
        const links = try gpa.alloc(aegis.Atomic(Link), class.count);
        errdefer gpa.free(links);
        const limits = if (is_windows) try gpa.alloc(usize, class.count) else {};
        errdefer if (is_windows) gpa.free(limits);
        var shadows: if (native.shadow_stacks) []native.Shadow else void = if (native.shadow_stacks) &.{} else {};
        if (native.shadow_stacks and native.shadowStackPointer() != 0) {
            shadows = try gpa.alloc(native.Shadow, class.count);
            @memset(shadows, .{});
        }
        errdefer if (native.shadow_stacks) gpa.free(shadows);
        var valgrind: []usize = &.{};
        if (std.valgrind.runningOnValgrind() > 0) {
            valgrind = try gpa.alloc(usize, class.count);
            @memset(valgrind, 0);
        }
        return .{ .layout = layout, .count = class.count, .links = links, .limits = limits, .shadows = shadows, .valgrind = valgrind };
    }

    fn deinit(s: *Shelf, gpa: std.mem.Allocator) void {
        for (s.valgrind) |id| if (id != 0) std.valgrind.stackDeregister(id);
        if (s.valgrind.len > 0) gpa.free(s.valgrind);
        gpa.free(s.links);
        if (is_windows) gpa.free(s.limits);
        if (native.shadow_stacks) {
            for (s.shadows) |shadow| native.releaseShadow(shadow, s.layout.usable);
            gpa.free(s.shadows);
        }
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
            .shadow = if (native.shadow_stacks and s.shadows.len > 0) s.shadows[index] else .{},
        };
    }

    /// A stack never handed out, now the caller's, or null when none is
    /// left.
    fn claim(s: *Shelf) ?u32 {
        var next = s.fresh.load(.monotonic);
        while (next.compare(.fromRaw(s.count)) == .lt) {
            const after = next.add(.fromRaw(1)) catch unreachable; // unreachable: below the class's count, a u32
            next = s.fresh.cmpxchgWeak(next, after, .monotonic, .monotonic) orelse return next.raw();
        }
        return null;
    }
};

/// A lock-free stack of a class's stack indices, linked through the
/// class's `links`, its head tagged against reuse.
const List = struct {
    head: aegis.Atomic(Head) = .init(.of(.{ .index_plus_one = .end, .tag = 0 })),

    fn pop(l: *List, links: []aegis.Atomic(Link)) ?u32 {
        var head = l.head.load(.acquire);
        while (true) {
            const f = head.free();
            const index = f.index_plus_one.index() orelse return null;
            const next: Free = .{ .index_plus_one = links[index].load(.monotonic), .tag = f.tag +% 1 };
            head = l.head.cmpxchgWeak(head, .of(next), .acq_rel, .acquire) orelse return index;
        }
    }

    fn push(l: *List, links: []aegis.Atomic(Link), index: u32) void {
        var head = l.head.load(.monotonic);
        while (true) {
            const f = head.free();
            links[index].store(f.index_plus_one, .monotonic);
            const next: Free = .{ .index_plus_one = .of(index), .tag = f.tag +% 1 };
            head = l.head.cmpxchgWeak(head, .of(next), .release, .monotonic) orelse return;
        }
    }
};

const Free = packed struct(u64) { index_plus_one: Link, tag: u32 };

/// A list's head as its cell holds it: a `Free`, all 64 bits.
const Head = enum(u64) {
    _,

    fn of(f: Free) Head {
        return @fromBackingInt(@as(u64, @bitCast(f)));
    }

    fn free(h: Head) Free {
        return @bitCast(@backingInt(h));
    }
};

/// A stack's index plus one on a list, zero ending it.
const Link = enum(u32) {
    end = 0,
    _,

    fn of(stack: u32) Link {
        return @fromBackingInt(stack + 1);
    }

    /// The stack it names, or null at the end.
    fn index(l: Link) ?u32 {
        if (l == .end) return null;
        return @backingInt(l) - 1;
    }
};

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
    try checkMapCount(total, guard, native.shadow_stacks and native.shadowStackPointer() != 0);
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
    if (native.shadow_stacks and s.shadows.len > 0 and s.shadows[index].end == 0) {
        s.shadows[index] = native.shadowFor(s.layout.usable) catch {
            s.unmade.push(s.links, index);
            return error.SystemResources;
        };
    }
    // Valgrind is told of the stack once: a stack handed out is described
    // by its number alone, and carries no registration.
    if (s.valgrind.len > 0) {
        stack.register();
        s.valgrind[index] = stack.valgrind;
    }
    return p.handOut(class, index);
}

fn handOut(p: *Pool, class: u16, index: u32) Stack {
    _ = p.in_use.fetchAddWrapping(.fromRaw(1), .monotonic);
    return p.classes[class].stack(class, index);
}

/// Gives back a stack `take` handed out, or one `stackOf` described. Nothing
/// may run on it.
pub fn give(p: *Pool, stack: Stack) void {
    const s = stack;
    const slot = s.slot.?;
    const shelf = &p.classes[slot.class];
    if (is_windows) shelf.limits[slot.index] = @min(shelf.limits[slot.index], s.limit);
    // Where the next context on the stack takes its shadow stack's token.
    if (native.shadow_stacks and shelf.shadows.len > 0) shelf.shadows[slot.index] = s.shadow;
    shelf.free.push(shelf.links, slot.index);
    // Zero publishes the last give after it stopped touching the pool.
    _ = p.in_use.fetchSubWrapping(.fromRaw(1), .release);
}

/// The stacks handed out and not given back.
pub fn inUse(p: *const Pool) u32 {
    return p.in_use.load(.acquire).raw();
}

/// The stacks ever handed out, or tried: those that cost more than address
/// space. At most `count()`.
pub fn reached(p: *const Pool) u32 {
    var n: u32 = 0;
    // aegis: no-danger: a class's `fresh` stays below its count (`claim`), and `init` summed the counts in a u32 with a check
    for (p.classes) |*s| n += s.fresh.load(.monotonic).raw();
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

fn checkMapCount(total: u32, guard: Stack.Guard, shadows: bool) error{TooManyStacks}!void {
    // Guard regions split nothing: stacks made usable side by side are one
    // mapping. Otherwise each is a mapping of its own beside a no-access
    // one. A shadow stack is one more each. Room is left for everything
    // else in the process.
    if (guard == .region and !shadows) return;
    const limit = memory.maxMapCount() orelse return;
    const per_stack: u64 = @as(u64, if (guard == .region) 0 else 2) + @intFromBool(shadows);
    const needed: u64 = 4096 + 1 + per_stack * total;
    if (needed > limit) return error.TooManyStacks;
}
