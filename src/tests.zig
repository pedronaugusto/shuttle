//! Every test of shuttle, reached from here.
test {
    _ = @import("switch_test.zig");
    _ = @import("context_test.zig");
    _ = @import("handoff_test.zig");
    _ = @import("coroutine_test.zig");
    _ = @import("property_test.zig");
}
