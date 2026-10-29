//! A stack a context runs on: reserved address space, a guard below it that
//! faults on any access, and on Windows pages committed as the stack grows.
//!
//! What a stack costs is the pages its code touches: the size is address
//! space, reserved no-access and then made usable. Elsewhere than Windows
//! the system commits a page on first touch.
//! On Windows the top pages are committed when the stack is made, with a
//! guard page below them; touching the guard commits the page below it,
//! as the system grows a thread's own stack, because a switch keeps the
//! thread information block's bounds on the running stack. The guard below
//! the stack is never committed: a fault there is a stack overflow.
//!
//! A `Stack` is a value: copying it copies the description, not the
//! memory. Its memory is released by `deinit` when it was made by `init`,
//! or given back with `Pool.give` when a pool handed it out.
const Stack = @This();

const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const memory = @import("memory.zig");
const native = @import("arch.zig").native;

pub const Bytes = aegis.units.Bytes(usize);

const is_windows = builtin.os.tag == .windows;

/// The lowest byte of the reservation: the guard starts here.
base: usize,
/// The lowest usable byte, just above the guard.
bottom: usize,
/// One past the highest usable byte, 16-aligned. `carve` lowers it.
top: usize,
/// One past the highest byte of the reservation: the top before anything
/// was carved from it.
end: usize,
/// Windows: the lowest committed byte. Elsewhere `bottom`.
limit: usize,
/// Valgrind's number for the stack, zero when not running under it.
valgrind: usize = 0,
/// Which pool slot the stack is, or none for a stack made by `init`.
slot: ?Slot = null,
/// Linux x86_64: the stack's shadow stack, made with it on a thread that
/// has one (`native.shadowFor`); none elsewhere.
shadow: native.Shadow = .{},

/// A pool's stack: its size class and its place there.
pub const Slot = struct { class: u16, index: u32 };

pub const Options = struct {
    /// Usable bytes, rounded up to whole pages.
    size: Bytes,
    /// Bytes of guard below the stack, rounded up to whole pages; one page
    /// when null. Zig emits no stack probes on aarch64, nor on x86_64 in
    /// ReleaseFast, so a frame larger than the guard can step over it: a
    /// stack whose code keeps large arrays in its frames wants a larger one.
    guard: ?Bytes = null,
    /// Windows: bytes committed at the top when the stack is made, rounded
    /// up to whole pages; two pages when null. The rest is committed as the
    /// stack grows.
    commit: ?Bytes = null,
};

pub const InitError = error{ SystemResources, Overflow };

/// A stack of its own reservation.
pub fn init(options: Options) InitError!Stack {
    const layout = try Layout.of(options);
    const reservation = try memory.reserve(layout.reserved);
    errdefer memory.release(reservation);
    const base = @intFromPtr(reservation.ptr); // safe: an address, kept as a number to lay the stack out
    var s: Stack = .{
        .base = base,
        .bottom = base + layout.guard,
        .top = base + layout.reserved,
        .end = base + layout.reserved,
        .limit = base + layout.guard,
    };
    try s.prepare(layout.commit, .reserved);
    s.shadow = try native.shadowFor(layout.usable);
    s.register();
    return s;
}

/// Releases a stack made by `init`. Nothing may run on it.
pub fn deinit(s: *Stack) void {
    std.debug.assert(s.slot == null); // a pool's stack goes back with Pool.give
    s.unregister();
    native.releaseShadow(s.shadow, s.end - s.bottom);
    memory.release(memory.pages(s.base, s.end));
    s.* = undefined;
}

/// What `Options` ask for, in whole pages.
pub const Layout = struct {
    guard: usize,
    usable: usize,
    commit: usize,
    /// The guard and the usable bytes.
    reserved: usize,

    pub fn of(options: Options) error{Overflow}!Layout {
        const page = memory.pageSize();
        // Windows keeps a guard page inside the usable bytes, below what is committed.
        const least = if (is_windows) 2 * page else page;
        const usable_bytes = try roundPages(@max(options.size.raw(), least), page);
        const guard_bytes = try roundPages(@max(if (options.guard) |g| g.raw() else page, page), page);
        const commit = @min(usable_bytes - page, try roundPages(if (options.commit) |c| c.raw() else 2 * page, page));
        const reserved = (Bytes.fromRaw(usable_bytes).add(.fromRaw(guard_bytes)) catch return error.Overflow).raw();
        return .{ .guard = guard_bytes, .usable = usable_bytes, .commit = @max(commit, page), .reserved = reserved };
    }
};

fn roundPages(bytes: usize, page: usize) error{Overflow}!usize {
    const up = (aegis.int.Checked(usize).init(bytes).add(page - 1) catch return error.Overflow).raw();
    return std.mem.alignBackward(usize, up, page);
}

/// What faults below a stack's usable bytes.
pub const Guard = enum {
    /// The reservation's own no-access pages, left as they are: a mapping
    /// of their own, between the stack and whatever lies below.
    reserved,
    /// Linux 6.13 and later: a guard region in committed memory, so that
    /// stacks laid side by side make one mapping (`vm.max_map_count`).
    region,
};

/// Makes a stack in reserved address space usable, with its guard below
/// it. When it fails nothing may run on the stack, and trying again is
/// harmless. Windows: commits the top `commit` bytes and a guard page below
/// them, the guard below the stack staying reserved. Elsewhere: makes the
/// usable bytes readable and writable, committed as they are touched.
pub fn prepare(s: *Stack, commit: usize, guard: Guard) error{SystemResources}!void {
    if (!is_windows) {
        switch (guard) {
            .reserved => try memory.commit(memory.pages(s.bottom, s.end), false),
            .region => {
                try memory.commit(memory.pages(s.base, s.end), false);
                try memory.installGuard(memory.pages(s.base, s.bottom));
            },
        }
        s.limit = s.bottom;
        return;
    }
    std.debug.assert(guard == .reserved);
    const page = memory.pageSize();
    const low = s.end - commit;
    std.debug.assert(low - page >= s.bottom);
    try memory.commit(memory.pages(low, s.end), false);
    try memory.commit(memory.pages(low - page, low), true);
    s.limit = low;
}

/// Makes the stack usable down to `low` before code other than its own
/// writes there: on Windows the system grows a stack only for the thread
/// running on it, so a context's first frame and anything carved above it,
/// written by the thread making the context, are committed here.
pub fn reach(s: *Stack, low: usize) error{StackTooSmall}!void {
    if (low < s.bottom) return error.StackTooSmall;
    if (!is_windows) return;
    const page = memory.pageSize();
    const want = std.mem.alignBackward(usize, low, page);
    if (want >= s.limit) return;
    if (want - page < s.bottom) return error.StackTooSmall;
    memory.commit(memory.pages(want, s.limit), false) catch return error.StackTooSmall;
    memory.commit(memory.pages(want - page, want), true) catch return error.StackTooSmall;
    s.limit = want;
}

/// Takes a `T` from the top of the stack, for what lives as long as the
/// code on it: a coroutine's state and its arguments. The stack below is
/// what is left to run on.
pub fn carve(s: *Stack, comptime T: type) error{StackTooSmall}!*T {
    const bytes = try s.carveBytes(@sizeOf(T), .of(T));
    // aegis: internal: `carveBytes` gave room for a `T` at an address aligned for one
    return @ptrCast(@alignCast(bytes));
}

/// Takes `len` bytes aligned to `alignment` from the top of the stack: what
/// `carve` does for a size and an alignment known only at run time, as a
/// runtime's task context and result are. The alignment is at least 16, the
/// stack's own, so the stack below stays aligned for a call.
pub fn carveBytes(s: *Stack, len: usize, alignment: std.mem.Alignment) error{StackTooSmall}![*]u8 {
    if (len > s.top - s.bottom) return error.StackTooSmall;
    const at = std.mem.alignBackward(usize, s.top - len, @max(alignment.toByteUnits(), 16));
    if (at < s.bottom) return error.StackTooSmall;
    try s.reach(at);
    s.top = at;
    // aegis: internal: an address inside the stack's usable bytes, committed by `reach`, aligned as asked and with `len` bytes just above
    return @ptrFromInt(at);
}

/// The usable bytes, what has been carved included.
pub fn size(s: *const Stack) Bytes {
    return .fromRaw(s.end - s.bottom);
}

/// The usable bytes themselves, `bottom` to `end`, for code that reads or
/// fills a stack nothing runs on (a scheduler measuring how deep its tasks
/// went). On Windows only the bytes from `limit` up are committed: `reach`
/// the lowest byte touched first.
pub fn usable(s: *const Stack) []u8 {
    // aegis: internal: the stack's usable bytes, which its reservation holds from `bottom` to `end`
    const low: [*]u8 = @ptrFromInt(s.bottom);
    return low[0 .. s.end - s.bottom];
}

/// Whether `address` lies in the stack's usable bytes.
pub fn contains(s: *const Stack, address: usize) bool {
    return address >= s.bottom and address < s.end;
}

/// Whether `address` lies in the guard below the stack: an access there is
/// a stack overflow.
pub fn guards(s: *const Stack, address: usize) bool {
    return address >= s.base and address < s.bottom;
}

/// Gives the pages of the stack below `keep_from` back to the system: a
/// stack that once ran deep stops holding the memory. Nothing may run on
/// the stack below `keep_from`. Not on Windows, whose stacks grow only
/// through their guard page.
pub fn discard(s: *const Stack, keep_from: usize) void {
    const high = std.mem.alignBackward(usize, @min(keep_from, s.end), memory.pageSize());
    if (high <= s.bottom) return;
    memory.discard(memory.pages(s.bottom, high));
}

/// Tells Valgrind the stack is one, so that a switch onto it is not taken
/// for an enormous frame.
pub fn register(s: *Stack) void {
    s.valgrind = std.valgrind.stackRegister(s.usable());
}

pub fn unregister(s: *Stack) void {
    if (s.valgrind != 0) std.valgrind.stackDeregister(s.valgrind);
    s.valgrind = 0;
}
