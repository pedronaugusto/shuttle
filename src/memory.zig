//! Address space for stacks: reserve it, guard it, commit it (Windows),
//! release it, and give pages back.
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

/// `len` bytes of address space. Elsewhere than Windows it is readable and
/// writable and committed as it is touched, with no swap reserved for it on
/// Linux and marked as a stack where the system has the mark (OpenBSD
/// refuses a stack pointer into memory without it). On Windows nothing may
/// touch it until it is committed.
pub fn reserve(len: usize) Error!Pages {
    if (is_windows) return allocate(len, .{ .RESERVE = true }, .{ .NOACCESS = true });
    var flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (@hasField(posix.MAP, "NORESERVE")) flags.NORESERVE = true;
    if (@hasField(posix.MAP, "STACK")) flags.STACK = true;
    return posix.mmap(null, len, .{ .READ = true, .WRITE = true }, flags, -1, 0) catch error.SystemResources;
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

/// Makes `memory` fault on any access. On Linux 6.13 and later a guard
/// region, which costs no mapping; elsewhere `PROT_NONE`, which on Linux
/// splits the mapping and so counts against `vm.max_map_count`. Returns
/// whether the guard is a region.
pub fn guard(memory: Pages) Error!bool {
    if (builtin.os.tag == .linux) {
        const madv_guard_install = 102;
        if (std.os.linux.errno(std.os.linux.madvise(memory.ptr, memory.len, madv_guard_install)) == .SUCCESS) return true;
    }
    if (is_windows) return false; // reserved and never committed: already a fault
    switch (posix.errno(posix.system.mprotect(memory.ptr, memory.len, .{}))) {
        .SUCCESS => return false,
        else => return error.SystemResources,
    }
}

/// Windows: makes reserved `memory` usable; with `as_guard`, as a guard
/// page, which turns usable on first touch and, inside the running stack's
/// bounds, makes the system commit the page below as the next guard.
pub fn commit(memory: Pages, as_guard: bool) Error!void {
    if (!is_windows) return;
    var base: windows.PVOID = memory.ptr;
    var size: windows.SIZE_T = memory.len;
    switch (windows.ntdll.NtAllocateVirtualMemory(windows.current_process, &base, 0, &size, .{ .COMMIT = true }, .{ .READWRITE = true, .GUARD = as_guard })) {
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
