//! The guard below a pool's stacks on Linux 6.13 and later: a guard region
//! inside committed memory, so stacks made usable side by side are one
//! mapping. The probe that picks it (`memory.guardRegions`) must find it on
//! every such kernel, where a failed probe would fall back without a word;
//! that an overflow into one is named is `testing/faults.zig`'s
//! "overflow-pooled".
const builtin = @import("builtin");
const std = @import("std");
const memory = @import("memory.zig");
const Pool = @import("Pool.zig");
const Stack = @import("Stack.zig");

const linux = std.os.linux;

/// The running kernel's version, major and minor.
fn kernelVersion() ?[2]u32 {
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return null;
    var parts = std.mem.tokenizeAny(u8, std.mem.sliceTo(&uts.release, 0), ".-");
    const major = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    return .{ major, minor };
}

/// The mapping in `/proc/self/maps` that holds `address`: its start and end.
fn mappingOf(gpa: std.mem.Allocator, address: usize) !?[2]usize {
    const rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Unreadable;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buffer, buffer.len);
        if (linux.errno(n) != .SUCCESS) return error.Unreadable;
        if (n == 0) break;
        try text.appendSlice(gpa, buffer[0..n]);
    }
    var lines = std.mem.tokenizeScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        const range = line[0 .. std.mem.findScalar(u8, line, ' ') orelse continue];
        const dash = std.mem.findScalar(u8, range, '-') orelse continue;
        const start = try std.fmt.parseInt(usize, range[0..dash], 16);
        const end = try std.fmt.parseInt(usize, range[dash + 1 ..], 16);
        if (start <= address and address < end) return .{ start, end };
    }
    return null;
}

test "on Linux 6.13 and later a pool's guards are guard regions, and its stacks side by side one mapping" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const version = kernelVersion() orelse return error.SkipZigTest;
    if (version[0] < 6 or (version[0] == 6 and version[1] < 13)) return error.SkipZigTest;
    try std.testing.expect(memory.guardRegions());

    const gpa = std.testing.allocator;
    var pool = try Pool.init(gpa, .{ .classes = &.{.{ .size = .fromRaw(64 * 1024), .count = 3 }} });
    defer pool.deinit(gpa);
    try std.testing.expectEqual(Stack.Guard.region, pool.guard);
    var stacks: [3]Stack = undefined;
    for (&stacks) |*s| s.* = (try pool.take(.fromRaw(64 * 1024))).?;
    defer for (stacks) |s| pool.give(s);

    // Guards and stacks alike, from the lowest guard to the highest top.
    var low: usize = std.math.maxInt(usize);
    var high: usize = 0;
    for (stacks) |s| {
        low = @min(low, s.base);
        high = @max(high, s.end);
    }
    try std.testing.expectEqual(3 * (stacks[0].end - stacks[0].base), high - low);
    const mapping = (try mappingOf(gpa, stacks[1].bottom)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(mapping[0] <= low and high <= mapping[1]);
}
