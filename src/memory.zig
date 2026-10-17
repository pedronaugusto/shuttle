//! Address space for stacks: reserve it, commit it, guard it, release it,
//! and give pages back.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;

pub const page_size_min = std.heap.page_size_min;
pub const Pages = []align(page_size_min) u8;

pub fn pageSize() usize {
    return std.heap.pageSize();
}

pub const Error = error{SystemResources};

/// `len` bytes of address space that fault on any access until committed:
/// nothing is committed or charged for them (Windows: reserved; elsewhere
/// `PROT_NONE`, which no system counts against its commit limit). On Linux
/// what is later committed has no swap reserved for it and is marked as a
/// stack, which keeps transparent huge pages off it (6.7 and later).
pub fn reserve(len: usize) Error!Pages {
    if (is_windows) return allocate(len, .{ .RESERVE = true }, .{ .NOACCESS = true });
    var flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (@hasField(posix.MAP, "NORESERVE")) flags.NORESERVE = true;
    // Elsewhere the mark asks for read-write memory: OpenBSD's is given at
    // commit, and FreeBSD's would make a mapping that grows of itself.
    if (builtin.os.tag == .linux) flags.STACK = true;
    return posix.mmap(null, len, .{}, flags, -1, 0) catch error.SystemResources;
}

fn allocate(len: usize, kind: windows.MEM.ALLOCATE, protection: windows.PAGE) Error!Pages {
    // A null base lets the system choose; std types the base as a non-null
    // pointer, so the null goes in through an optional of the same layout.
    var base: ?windows.PVOID = null;
    var size: windows.SIZE_T = len;
    switch (windows.ntdll.NtAllocateVirtualMemory(windows.current_process, @ptrCast(&base), 0, &size, kind, protection)) { // safe: an optional pointer has the pointer's layout, null as zero
        .SUCCESS => {},
        else => return error.SystemResources,
    }
    const start: [*]align(page_size_min) u8 = @ptrCast(@alignCast(base.?)); // safe: the system hands out whole pages
    return start[0..len];
}

pub fn release(memory: Pages) void {
    if (is_windows) {
        var base: windows.PVOID = memory.ptr;
        var size: windows.SIZE_T = 0;
        // Releasing a whole reservation this process made cannot fail.
        _ = windows.ntdll.NtFreeVirtualMemory(windows.current_process, &base, &size, .{ .RELEASE = true });
        return;
    }
    posix.munmap(memory);
}

/// Whether this kernel has guard regions (Linux 6.13 and later): one page
/// tried and released.
pub fn guardRegions() bool {
    if (builtin.os.tag != .linux) return false;
    const page = pageSize();
    const probe = reserve(page) catch return false;
    defer release(probe);
    commit(probe, false) catch return false;
    installGuard(probe) catch return false;
    return true;
}

/// Linux 6.13 and later: makes committed `memory` fault on any access as a
/// guard region, which splits no mapping and so costs nothing against
/// `vm.max_map_count`. It stays through `discard` and `commit`.
pub fn installGuard(memory: Pages) Error!void {
    if (builtin.os.tag != .linux) return error.SystemResources;
    const madv_guard_install = 102;
    if (std.os.linux.errno(std.os.linux.madvise(memory.ptr, memory.len, madv_guard_install)) != .SUCCESS) return error.SystemResources;
}

/// Makes reserved `memory` usable. Elsewhere than Windows it is readable
/// and writable and the system commits each page as it is first touched;
/// the call fails where the system refuses the charge (Linux under strict
/// overcommit, or past `vm.max_map_count`). On Windows it is committed now;
/// with `as_guard`, as a guard page, which turns usable on first touch and,
/// inside the running stack's bounds, makes the system commit the page
/// below as the next guard.
pub fn commit(memory: Pages, as_guard: bool) Error!void {
    if (is_windows) {
        var base: windows.PVOID = memory.ptr;
        var size: windows.SIZE_T = memory.len;
        switch (windows.ntdll.NtAllocateVirtualMemory(windows.current_process, &base, 0, &size, .{ .COMMIT = true }, .{ .READWRITE = true, .GUARD = as_guard })) {
            .SUCCESS => return,
            else => return error.SystemResources,
        }
    }
    std.debug.assert(!as_guard);
    if (builtin.os.tag == .openbsd) {
        // OpenBSD refuses a stack pointer into memory not mapped as a
        // stack, and maps one only read-write: mapped again in place.
        const flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true, .STACK = true };
        _ = posix.mmap(memory.ptr, memory.len, .{ .READ = true, .WRITE = true }, flags, -1, 0) catch return error.SystemResources;
        return;
    }
    switch (posix.errno(posix.system.mprotect(memory.ptr, memory.len, .{ .READ = true, .WRITE = true }))) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
}

/// Gives `memory`'s pages back to the system; they read as zero (Linux) or
/// as anything (elsewhere) once touched again. Windows keeps them: a stack
/// grows there through its guard page, and a page given back below the
/// guard would never be committed again.
pub fn discard(memory: Pages) void {
    if (is_windows) return;
    const advice: u32 = if (builtin.os.tag == .linux) std.os.linux.MADV.DONTNEED else posix.MADV.FREE;
    // Pages not given back stay usable: there is nothing to report.
    posix.madvise(memory.ptr, memory.len, advice) catch return;
}

/// Linux: the most mappings a process may hold (`vm.max_map_count`), or
/// null where it cannot be read.
pub fn maxMapCount() ?u64 {
    if (builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    const rc = linux.open("/proc/sys/vm/max_map_count", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buffer: [32]u8 = undefined;
    const n = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, buffer[0..n], " \n"), 10) catch null;
}

/// The page range `[from, to)`, both page-aligned.
pub fn pages(from: usize, to: usize) Pages {
    const start: [*]align(page_size_min) u8 = @ptrFromInt(from); // safe: callers pass page boundaries of a reservation of theirs
    return start[0 .. to - from];
}
