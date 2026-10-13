//! Stacks in size classes, reserved once and handed out again and again,
//! from any thread, without allocating or making a system call after the
//! first time a stack is handed out.
//!
//! Each class reserves its stacks in slabs of 64 per mapping, every stack
//! with its own guard below it: a guard region where the kernel has them
//! (Linux 6.13 and later, no mapping of its own), a guard page elsewhere.
//! One guard per slab is not enough: Zig emits no stack probes on aarch64,
//! nor on x86_64 in ReleaseFast, so a large frame would step over a shared
//! guard into the next stack unseen. A guard page on Linux splits its slab's
//! mapping, two entries per stack against `vm.max_map_count`, so `init`
//! refuses a count that would reach the limit rather than fail later.
//!
//! On Windows a stack's top pages are committed the first time it is handed
//! out, with a guard page below them, and the system commits the rest as
//! the stack grows. A stack given back keeps what it committed, so the next
//! context on it starts with it.
//!
//! Free stacks are a lock-free stack of indices, tagged against reuse, and
//! the last stack given back is the first handed out, so the stacks in use
//! stay the warm ones.
const Pool = @This();

const builtin = @import("builtin");
const std = @import("std");
const memory = @import("memory.zig");
const Stack = @import("Stack.zig");

const Bytes = Stack.Bytes;
const is_windows = builtin.os.tag == .windows;

/// Stacks per mapping.
pub const per_slab = 64;

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

classes: []Shelf,

/// One class's stacks.
const Shelf = struct {
    layout: Stack.Layout,
    /// A stack and the guard below it.
    stride: usize,
    count: u32,
    slabs: []memory.Pages,
    /// Per stack, the next free one, plus one; zero ends the list.
    links: []u32,
    free: std.atomic.Value(u64) = .init(0),
    /// Windows: per stack, its lowest committed byte, zero until it is
    /// first handed out. Only the stack's holder touches its entry.
    limits: if (is_windows) []usize else void,

    fn init(gpa: std.mem.Allocator, class: Class, options: Options) InitError!Shelf {
        const layout = try Stack.Layout.of(.{ .size = class.size, .guard = options.guard, .commit = options.commit });
        const slab_count = std.math.divCeil(usize, class.count, per_slab) catch unreachable; // unreachable: the divisor is a nonzero constant
        var s: Shelf = .{
            .layout = layout,
            .stride = layout.reserved,
            .count = class.count,
            .slabs = try gpa.alloc(memory.Pages, slab_count),
            .links = undefined,
            .limits = undefined,
        };
        errdefer gpa.free(s.slabs);
        s.links = try gpa.alloc(u32, class.count);
        errdefer gpa.free(s.links);
        if (is_windows) {
            s.limits = try gpa.alloc(usize, class.count);
            @memset(s.limits, 0);
        }
        errdefer if (is_windows) gpa.free(s.limits);
        var made: usize = 0;
        errdefer for (s.slabs[0..made]) |slab| memory.release(slab);
        while (made < slab_count) : (made += 1) {
            const in_slab: usize = @min(per_slab, class.count - made * per_slab);
            const bytes = (Bytes.fromRaw(s.stride).mul(in_slab) catch return error.Overflow).raw();
            const slab = try memory.reserve(bytes);
            s.slabs[made] = slab;
            errdefer memory.release(slab);
            // Windows: below each stack, reserved and never committed.
            if (!is_windows) for (0..in_slab) |i| {
                const low = @intFromPtr(slab.ptr) + i * s.stride; // safe: an address inside the slab, laid out by stride
                _ = try memory.guard(memory.pages(low, low + layout.guard));
            };
        }
        // Every stack free, the first first out.
        var i = class.count;
        while (i > 0) {
            i -= 1;
            s.push(i);
        }
        return s;
    }

    fn deinit(s: *Shelf, gpa: std.mem.Allocator) void {
        for (s.slabs) |slab| memory.release(slab);
        gpa.free(s.slabs);
        gpa.free(s.links);
        if (is_windows) gpa.free(s.limits);
    }

    fn stack(s: *const Shelf, class: u16, index: u32) Stack {
        const slab = s.slabs[index / per_slab];
        const base = @intFromPtr(slab.ptr) + (index % per_slab) * s.stride; // safe: an address inside the slab, laid out by stride
        const bottom = base + s.layout.guard;
        return .{
            .base = base,
            .bottom = bottom,
            .top = base + s.stride,
            .end = base + s.stride,
            .limit = if (is_windows) s.limits[index] else bottom,
            .slot = .{ .class = class, .index = index },
        };
    }

    fn pop(s: *Shelf) ?u32 {
        var raw = s.free.load(.acquire);
        while (true) {
            const f: Free = @bitCast(raw);
            if (f.index_plus_one == 0) return null;
            const index = f.index_plus_one - 1;
            const next: Free = .{ .index_plus_one = @atomicLoad(u32, &s.links[index], .monotonic), .tag = f.tag +% 1 };
            raw = s.free.cmpxchgWeak(raw, @bitCast(next), .acq_rel, .acquire) orelse return index;
        }
    }

    fn push(s: *Shelf, index: u32) void {
        var raw = s.free.load(.monotonic);
        while (true) {
            const f: Free = @bitCast(raw);
            @atomicStore(u32, &s.links[index], f.index_plus_one, .monotonic);
            const next: Free = .{ .index_plus_one = index + 1, .tag = f.tag +% 1 };
            raw = s.free.cmpxchgWeak(raw, @bitCast(next), .release, .monotonic) orelse return;
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
    try checkMapCount(shelves);
    return .{ .classes = shelves };
}

/// Releases every stack. None may be in use.
pub fn deinit(p: *Pool, gpa: std.mem.Allocator) void {
    for (p.classes) |*s| s.deinit(gpa);
    gpa.free(p.classes);
    p.* = undefined;
}

/// A stack of at least `size` usable bytes: from the smallest class that
/// has one free. Null when every class that fits is in use, or (Windows) its
/// first pages could not be committed.
pub fn take(p: *Pool, size: Bytes) ?Stack {
    for (p.classes, 0..) |*s, class| {
        if (Bytes.fromRaw(s.layout.usable).compare(size) == .lt) continue;
        const index = s.pop() orelse continue;
        var stack = s.stack(@intCast(class), index); // safe: `init` refuses more classes than a u16 names
        if (is_windows and s.limits[index] == 0) {
            stack.prepare(s.layout.commit) catch {
                s.push(index);
                continue;
            };
            s.limits[index] = stack.limit;
        }
        stack.register();
        return stack;
    }
    return null;
}

/// Gives back a stack `take` handed out. Nothing may run on it.
pub fn give(p: *Pool, stack: Stack) void {
    var s = stack;
    s.unregister();
    const slot = s.slot.?;
    const shelf = &p.classes[slot.class];
    if (is_windows) shelf.limits[slot.index] = @min(shelf.limits[slot.index], s.limit);
    shelf.push(slot.index);
}

/// The usable size of each class, smallest first.
pub fn sizes(p: *const Pool, out: []Bytes) []Bytes {
    const n = @min(out.len, p.classes.len);
    for (p.classes[0..n], out[0..n]) |s, *o| o.* = .fromRaw(s.layout.usable);
    return out[0..n];
}

fn checkMapCount(shelves: []const Shelf) error{TooManyStacks}!void {
    if (shelves.len == 0) return;
    const limit = memory.maxMapCount() orelse return;
    // Guard regions split nothing; a guard page splits its slab: about two
    // mappings per stack. Room is left for everything else in the process.
    if (guardRegions()) return;
    var needed: u64 = 4096;
    for (shelves) |s| needed += s.slabs.len + 2 * @as(u64, s.count);
    if (needed > limit) return error.TooManyStacks;
}

/// Whether this kernel has guard regions: one page tried and released.
fn guardRegions() bool {
    if (builtin.os.tag != .linux) return false;
    const page = memory.pageSize();
    const probe = memory.reserve(page) catch return false;
    defer memory.release(probe);
    return memory.guard(probe) catch false;
}
