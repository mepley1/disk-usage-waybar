//! Helper functions for disks-usage-waybar module
//! Zig 0.15.1 + libc

const std = @import("std");

const ascii = std.ascii;
const fmt = std.fmt;
const fs = std.fs;
const Io = std.Io;
const json = std.json;
const linux = std.os.linux;
const mem = std.mem;
const posix = std.posix;

pub const gibi = 1_073_741_824; // 1024^3
pub const kibi = 1024;

/// Same as `std.debug.assert`
pub fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

/// Write to stdout, buffered
pub fn bufferedPrint(bytes: []const u8) error{WriteFailed}!void {
    var buf: [kibi]u8 = undefined;
    var w = fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    try stdout.print("{s}", .{bytes});
    try stdout.flush();
    return;
}

/// Write to stdout, unbuffered.
pub fn unbufferedPrint(bytes: []const u8) error{WriteFailed}!void {
    var w = fs.File.stdout().writer(&.{});
    const stdout = &w.interface;

    try stdout.writeAll(bytes);
    try stdout.flush();
    return;
}

/// Send realtime signal (`RTMIN` + `n`) to Waybar process, (by pid) to signal module update.
///
/// Asserts `pid > 0`, and `n <= 32`
///
/// To get pid, see `.getPidByName()`
/// ref: https://manpages.org/signal/7
pub fn rtSig(pid: linux.pid_t, n: u8) !void {
    assert(pid > 0);
    assert(n <= 32);
    const sig = linux.sigrtmin() + n;
    assert(sig <= linux.sigrtmax());
    try posix.kill(pid, sig);
    return;
}

/// Lookup PID of the first process matching `target_name`. Return null if not found.
pub fn getPidByName(proc_name: []const u8) !?linux.pid_t {
    var dir = try fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer dir.close();

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!ascii.isDigit(entry.name[0])) continue;

        var buf_path: [64]u8 = undefined;
        const comm_path = try fmt.bufPrint(&buf_path, "/proc/{s}/comm", .{entry.name});

        const comm_file = fs.openFileAbsolute(comm_path, .{}) catch continue;
        defer comm_file.close();

        const comm_max_len = 256;
        var buf_comm: [comm_max_len]u8 = undefined;
        const len = try comm_file.read(&buf_comm);
        assert(len <= comm_max_len);

        const comm = mem.trimEnd(u8, buf_comm[0..len], "\n");

        if (mem.eql(u8, comm, proc_name)) {
            const pid = try fmt.parseInt(linux.pid_t, entry.name, 10);
            assert(pid > 0);
            return pid;
        }
    }

    return null;
}

test "getPidByName" {
    try std.testing.expect(try getPidByName("systemd") == 1); // Depends on systemd
    try std.testing.expect(try getPidByName("nonexistent process") == null);
}

/// Concatenate two runtime-known slices. Caller must free returned slice.
///
/// Note: This results in a larger binary than using `std.fmt.allocPrint()`
pub fn concatRuntime(alloc: mem.Allocator, comptime T: type, arr1: []const T, arr2: []const T) []T {
    var combined = alloc.alloc(T, arr1.len + arr2.len) catch @panic("Out of memory");
    errdefer alloc.free(combined);
    @memcpy(combined[0..arr1.len], arr1);
    @memcpy(combined[arr1.len..], arr2);
    return combined;
}

test "concatRuntime" {
    const s = concatRuntime(std.testing.allocator, u8, "abc", "def");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("abcdef", s);
}

/// Similar to `concatRuntime`, but for arbitrary number of slices. Caller must free returned slice.
pub fn concatRuntimeMulti(alloc: mem.Allocator, comptime T: type, arrs: []const []const T) []const T {
    const out_len = blk: {
        var n: usize = 0;
        for (arrs) |arr| {
            n += arr.len;
        }
        break :blk n;
    };

    var out = alloc.alloc(T, out_len) catch @panic("Out of memory");
    errdefer alloc.free(out);

    var cur: usize = 0;
    for (arrs) |arr| {
        @memcpy(out[cur .. cur + arr.len], arr);
        cur += arr.len;
    }

    return out;
}

test "concatRuntimeMulti" {
    var alloc = std.testing.allocator;
    const s = concatRuntimeMulti(alloc, u8, &[3][]const u8{ "a", "b", "c" });
    defer alloc.free(s);
    try std.testing.expectEqualStrings("abc", s);
}

/// Read contents of `/proc/mounts`, return allocated slice. Caller must free.
///
/// See Andrew's pr notes #25077 (https://github.com/ziglang/zig/pull/25077)
pub fn readFileBytes(allocator: mem.Allocator, file_path: []const u8) ![]const u8 {
    assert(file_path.len <= posix.PATH_MAX);
    const file_contents: []const u8 = try fs.cwd().readFileAlloc(allocator, file_path, kibi * 8);
    errdefer allocator.free(file_contents);
    assert(file_contents.len > 0); // `file_contents` is zero bytes long -- failure reading
    return file_contents;
}

/// Contains data that will become parts of final output.
pub const OutputWaybar = struct {
    text: []const u8 = "Storage",
    tooltip: []const u8,
    class: []const u8, // call `CssClass.asSlice()` to get a slice
    percentage: u8,

    /// Jsonify and append trailing newline. Caller must free result.
    ///
    /// ref: https://ziggit.dev/t/zig-0-15-1-reader-writer-dont-make-copies-of-fieldparentptr-based-interfaces/11719
    pub fn jsonify(self: OutputWaybar, allocator: mem.Allocator, w: *Io.Writer.Allocating) error{ OutOfMemory, WriteFailed }![]const u8 {
        try json.Stringify.value(self, .{ .whitespace = .minified }, &w.writer);
        const s = try w.toOwnedSlice();
        defer allocator.free(s);

        // Append a trailing newline. Waybar seems to break without one.
        const out = try fmt.allocPrint(allocator, "{s}\n", .{s});
        return out;
    }
};

test "OutputWaybar" {
    const allocator: std.mem.Allocator = std.testing.allocator;

    var w: Io.Writer.Allocating = .init(allocator);
    defer w.deinit();

    const data = OutputWaybar{
        .class = "low",
        .percentage = 50,
        .tooltip = "abc",
    };

    try std.testing.expectEqualStrings("Storage", data.text);
    try std.testing.expectEqualStrings("abc", data.tooltip);
    try std.testing.expectEqualStrings("low", data.class);
    try std.testing.expectEqual(50, data.percentage);

    const as_json = try data.jsonify(allocator, &w);
    defer allocator.free(as_json);

    const expected: []const u8 = "{\"text\":\"Storage\",\"tooltip\":\"abc\",\"class\":\"low\",\"percentage\":50}\n";
    try std.testing.expectEqualStrings(expected, as_json);

    var parsed = try std.json.parseFromSlice(OutputWaybar, allocator, as_json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Storage", parsed.value.text);
    try std.testing.expectEqualStrings("abc", parsed.value.tooltip);
    try std.testing.expectEqualStrings("low", parsed.value.class);
    try std.testing.expectEqual(50, parsed.value.percentage);
}

/// CSS class to pass to Waybar, for dynamic styling.
pub const CssClass = enum {
    low,
    medium,
    high,
    critical,
    err,

    pub fn asSlice(self: CssClass) []const u8 {
        return @as([]const u8, @tagName(self));
    }
};

test "CssClass" {
    try std.testing.expectEqualSlices(u8, "low", CssClass.low.asSlice());
    try std.testing.expectEqualSlices(u8, "medium", CssClass.medium.asSlice());
    try std.testing.expectEqualSlices(u8, "high", CssClass.high.asSlice());
    try std.testing.expectEqualSlices(u8, "critical", CssClass.critical.asSlice());
    try std.testing.expectEqualSlices(u8, "err", CssClass.err.asSlice());
}
