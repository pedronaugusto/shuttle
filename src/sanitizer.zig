//! ThreadSanitizer's fiber interface. It follows a thread by its stack: a
//! switch it is not told of leaves it reading one context's stack as
//! another's, and it reports races that are not there or crashes. Each
//! context is made known to it, and each switch announced, synchronizing,
//! so what the switching code wrote happens before what the resumed
//! context reads.
const builtin = @import("builtin");

pub const enabled = builtin.sanitize_thread;

extern fn __tsan_get_current_fiber() *anyopaque;
extern fn __tsan_create_fiber(flags: c_uint) *anyopaque;
extern fn __tsan_destroy_fiber(fiber: *anyopaque) void;
extern fn __tsan_switch_to_fiber(fiber: *anyopaque, flags: c_uint) void;

pub const Fiber = if (enabled) ?*anyopaque else void;
pub const none: Fiber = if (enabled) null else {};

pub inline fn current() Fiber {
    return if (enabled) __tsan_get_current_fiber() else {};
}

pub fn create() Fiber {
    return if (enabled) __tsan_create_fiber(0) else {};
}

pub fn destroy(fiber: Fiber) void {
    if (enabled) if (fiber) |f| __tsan_destroy_fiber(f);
}

/// Inline: a function of its own would be entered on the switching
/// context's record and left on the next one's, which then had one frame
/// fewer than it ever had, and faulted at its next call.
pub inline fn switchTo(fiber: Fiber) void {
    if (enabled) __tsan_switch_to_fiber(fiber.?, 0);
}
