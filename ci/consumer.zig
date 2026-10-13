//! A consumer imports the one module and reaches every part with only its
//! runtime dependencies.
const shuttle = @import("shuttle");

fn body(y: *shuttle.Generator(u8, error{}).Yielder) error{Canceled}!void {
    try y.yield(1);
}

pub fn main() !void {
    if (!shuttle.supported) return;
    var g = try shuttle.Generator(u8, error{}).init(try shuttle.Stack.init(.{ .size = .fromRaw(64 * 1024) }), body, .{});
    _ = try g.next();
    var s = g.deinit();
    s.deinit();
}
