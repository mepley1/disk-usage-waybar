//! Helper functions for disks-usage-waybar module
//! Zig 0.15.1 + libc

const std = @import("std");
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const enums = std.enums;
const fmt = std.fmt;
const fs = std.fs;
const Io = std.Io;
const json = std.json;
const linux = std.os.linux;
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;
const process = std.process;

const c_sys = @cImport({
    @cInclude("sys/statvfs.h");
});

pub const gibi = 1_073_741_824; // 1024^3
pub const kibi = 1024;

const stat_has_ftype: bool = @hasField(c_sys.struct_statvfs, "f_type");

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

/// Send realtime signal (`RTMIN` + `n`) to Waybar process, to signal module update.
///
/// Asserts `pid > 0` and `n <= 32`
///
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

/// Parse mounts file contents, stat each mountpoint, return the interesting data.
/// Caller must free `result.tooltip`.
///
/// `file_contents` expects the contents of `/proc/mounts`.
///
/// I've tried 2 different memory models for creating tooltip text:
///
/// - Add each line of text created to an `ArrayList([]const u8)`, then move all to a final `[]u8` slice (freeing each allocated line immediately after it's copied), and return owned slice. This involves a little more code.
///
/// - Append each line as *bytes* directly to an `ArrayList(u8)` (using `.appendSlice`), and return owned slice of its `.items` (skip the intermediate list).
///
/// The second option results in a slightly higher PEAK heap usage towards end of run, but for most of runtime, total usage is lower. Requires tracking allocations in a second list of slices to be freed, if not using arena.
///
/// I've chosen to stick with #2, for simplicity. But also because I don't feel like re-writing it again. ;)
///
/// TODO: Separate into smaller functions
pub fn parseMnts(allocator: mem.Allocator, file_contents: []const u8, options: *Options, w: *Io.Writer.Allocating) !OutputWaybar {
    var tooltip_bytes: ArrayList(u8) = .empty;
    errdefer tooltip_bytes.deinit(allocator);

    // 1.) Maintain references to output lines that still need freed after being copied to `tooltip_bytes`
    var need_freed: ArrayList([]const u8) = .empty;
    defer need_freed.deinit(allocator);
    // 2.) and free them:
    defer for (need_freed.items) |line| {
        allocator.free(line[0..]);
    };

    // Percentage used of root mount (`/`).
    var root_used_pcent: u8 = 0;

    // This doesn't need to be a named block, but it's easier to read and helps infer scope.
    parse_entries: {
        const line_1_fmt = "{s} on {s}\r";
        const line_2_fmt = "\tSize: {d:.2} GiB\r";

        var stat: c_sys.struct_statvfs = .{};

        var lines_iter = mem.tokenizeScalar(u8, file_contents, '\n');

        while (lines_iter.next()) |line| {
            // NOTE: This might break if mount point contains spaces
            var words_iter = mem.tokenizeScalar(u8, line, ' ');

            const dev_name = words_iter.next() orelse break; // fs_spec (dev name - if null, reached end)

            const mount_point = words_iter.next().?; // 2nd "word"
            const mount_point_z = try allocator.dupeZ(u8, mount_point);
            defer allocator.free(mount_point_z);

            assert(mount_point.len <= fs.max_path_bytes);
            for (mount_point) |c| assert(std.ascii.isPrint(c));

            const fs_type_fallback = words_iter.next() orelse continue; // 3rd word

            // TODO: Parse flags and keep important ones to display in tooltip
            // const flags = words_iter.next().?; // 4th word - mount flags

            // Call `statvfs` on the mount point
            const rc = c_sys.statvfs(mount_point_z.ptr, &stat);
            if (rc != 0) continue; // 0 = Failure, skip to next entry

            // Check if `f_type` is in `ignored_ftypes` enum, and if so, skip to next iteration
            // If `struct_statvfs.f_type` field doesn't exist, fall back to fs type from `/proc/mounts`
            var to_skip = false;
            if (stat_has_ftype) {
                const f_type: c_uint = stat.f_type;
                if (ignored_ftypes.fromCInt(f_type) != null) to_skip = true;
            } else {
                if (ignored_ftypes.hasField(fs_type_fallback)) to_skip = true;
            }
            if (to_skip) continue;

            // Calculate total usage of this filesystem
            const total: c_ulong = stat.f_blocks * stat.f_frsize;
            if (total == 0) continue; // Skip to next entry if zero size (most vfs entries).
            const free: c_ulong = stat.f_bfree * stat.f_frsize;
            const used: c_ulong = total - free;

            const used_pcent: f32 = (@as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(total))) * 100;

            assert(0 <= used_pcent and used_pcent <= 100); // Percentage calculated incorrectly

            // Save root mount (`/`) used %, when we come across its entry.
            if (mem.eql(u8, mount_point_z, "/")) {
                root_used_pcent = @intFromFloat(used_pcent); // Rounded towards zero
                assert(0 <= root_used_pcent and root_used_pcent <= 100); // Percentage calculated incorrectly
            }

            append_tooltip: {

                // ## Assemble tooltip paragraph for this filesystem, line by line, appending each to `tooltip_bytes`

                // Line 1 - dev name + mountpoint
                try w.writer.print(line_1_fmt, .{ dev_name, mount_point_z });
                const ln_1 = try w.toOwnedSlice();
                errdefer allocator.free(ln_1);

                try tooltip_bytes.appendSlice(allocator, ln_1);
                try need_freed.append(allocator, ln_1);

                // Line 2 - total size
                // Only include if format=.normal -- Skip if .compact
                if (options.*.tooltip_fmt == .normal) {
                    try w.writer.print(line_2_fmt, .{@as(f32, @floatFromInt(total)) / gibi});
                    const ln_2 = try w.toOwnedSlice();
                    errdefer allocator.free(ln_2);

                    try tooltip_bytes.appendSlice(allocator, ln_2);
                    try need_freed.append(allocator, ln_2);
                }

                // Line 3 - Used amount
                switch (options.*.tooltip_fmt) {
                    .compact => try w.writer.print("\tUsed: {d:.2} GiB of {d:.2} GiB ({d:.1}%)\r", .{ @as(f32, @floatFromInt(used)) / gibi, @as(f32, @floatFromInt(total)) / gibi, used_pcent }),
                    .normal => try w.writer.print("\tUsed: {d:.2} GiB ({d:.1}%)\r\r", .{ @as(f32, @floatFromInt(used)) / gibi, used_pcent }),
                }
                const ln_3 = try w.toOwnedSlice();
                errdefer allocator.free(ln_3);

                try tooltip_bytes.appendSlice(allocator, ln_3);
                try need_freed.append(allocator, ln_3);

                // Line 4 - Flags
                // TODO: For future usage
                // if (options.*.tooltip_fmt == .normal) {
                //     try w.writer.print("\tFlags: {s}\r\r", .{flags});
                //     const ln_4 = try w.toOwnedSlice();
                //     errdefer allocator.free(ln_4);

                //     try tooltip_bytes.appendSlice(allocator, ln_4);
                //     try need_freed.append(allocator, ln_4);
                // }

                break :append_tooltip;
            }
        }

        assert(tooltip_bytes.items.len > 0); // Failed reading or parsing mounts

        break :parse_entries;
    }

    const css_class: CssClass = switch (root_used_pcent) {
        0...49 => .low,
        50...74 => .medium,
        75...89 => .high,
        90...100 => .critical,
        else => unreachable,
    };

    const css_class_str: []const u8 = css_class.asSlice();

    // Trim trailing whitespace
    // Number of bytes depends on value of `line_3` in `parse_entries` block of `parseMnts()`, which ends with 1 or 2 newlines depending on chosen tooltip format.
    const n_whitespace_bytes: usize = switch (options.*.tooltip_fmt) {
        .normal => 2,
        .compact => 1,
    };
    tooltip_bytes.shrinkAndFree(allocator, tooltip_bytes.items.len - n_whitespace_bytes);

    const tooltip: []const u8 = try tooltip_bytes.toOwnedSlice(allocator);

    return OutputWaybar{
        .tooltip = tooltip,
        .class = css_class_str,
        .percentage = root_used_pcent,
    };
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
const CssClass = enum {
    low,
    medium,
    high,
    critical,
    err,

    fn asSlice(self: CssClass) []const u8 {
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

/// Command line options
pub const Options = struct {
    tooltip_fmt: TooltipFmt = .normal,
    lang: Lang = .en,

    const Self = @This();

    /// Read command line options and adjust values accordingly
    pub fn read(self: *Self) error{InvalidOption}!void {
        var args = process.args();
        _ = args.next() orelse return; // Discard program name

        // Parse tooltip format
        const arg_1: [:0]const u8 = args.next() orelse return; // Abort if not given
        const tooltip_fmt_str: []const u8 = mem.span(arg_1.ptr);
        self.*.tooltip_fmt = meta.stringToEnum(TooltipFmt, tooltip_fmt_str) orelse return error.InvalidOption;

        // Parse language
        // TODO: Implement translation(s)
        const arg_2: [:0]const u8 = args.next() orelse return; // Abort if not given
        const lang_str: []const u8 = mem.span(arg_2.ptr);
        self.*.lang = meta.stringToEnum(Lang, lang_str) orelse return error.InvalidOption;

        return;
    }

    const TooltipFmt = enum(u8) {
        normal = 0,
        compact = 1,
    };

    const Lang = enum(u8) {
        en = 0,
        de = 1,
    };
};

/// Magic numbers for filesystem types we don't care about, i.e. vfs etc
///
/// TODO: It might be easier to instead keep a list of types we DO want.
///
/// For a list of magic numbers, see: https://man7.org/linux/man-pages/man2/statfs.2.html
const ignored_ftypes = enum(c_uint) {
    autofs = 0x0187,
    binfmtfs = 0x42494e4d,
    binfmt_misc, // Dupe of binfmtfs - for compatibility with `.hasField()` fallback method
    bpf = 0xcafe4a11,
    cgroup = 0x27e0eb,
    cgroup2 = 0x63677270,
    configfs = 0x62656570,
    debugfs = 0x64626720,
    devfs = 0x1373,
    devpts = 0x1cd1,
    devtmpfs, // Dupe of tmpfs - for compatibility with `.hasField()` fallback
    efivarfs = 0xde5e81e4,
    fusectl = 0x65735543,
    hugetlbfs = 0x958458f6,
    mqueue = 0x19800202,
    proc = 0x9fa0,
    pstore = 0x6165676c,
    securityfs = 0x73636673,
    sysfs = 0x62656572,
    tmpfs = 0x01021994,
    tracefs = 0x74726163,

    /// If given `f_type` magic number is a member of this enum, return its enum value; else, return null.
    /// `f_type` is the value of field `.f_type` in the result of `statvfs()` call.
    fn fromCInt(f_type: c_uint) ?ignored_ftypes {
        return enums.fromInt(ignored_ftypes, f_type) orelse null;
    }

    /// Check if field `name` is a member of this enum.
    /// Fallback for systems where `struct_statvfs` does not include `.f_type` field and thus can't use `.fromCInt()`.
    ///
    /// This is inefficient; prefer to use `.fromCInt()` when possible.
    fn hasField(name: []const u8) bool {
        inline for (meta.fields(ignored_ftypes)) |field| {
            if (mem.eql(u8, field.name, name))
                return true;
        }
        return false;
    }
};

test "ignored_ftypes" {
    try std.testing.expect(ignored_ftypes.fromCInt(@as(c_uint, 1)) == null);
    try std.testing.expect(ignored_ftypes.fromCInt(@as(c_uint, 16914836)) == .tmpfs);
    try std.testing.expect(ignored_ftypes.fromCInt(@as(c_uint, 3730735588)) == .efivarfs);

    try std.testing.expect(ignored_ftypes.hasField("tmpfs"));
    try std.testing.expect(ignored_ftypes.hasField("nonexistent") == false);
}

// /// Deprecated
// const ignored_types = &[_][]const u8{
//     "-",
//     "autofs",
//     "binfmtfs",
//     "binfmt_misc",
//     "bpf",
//     "cgroup",
//     "cgroup2",
//     "configfs",
//     "debugfs",
//     "devfs",
//     "devpts",
//     "devtmpfs",
//     "efivarfs",
//     "fuse.portal",
//     "fusectl",
//     "hugetlbfs",
//     "mqueue",
//     "proc",
//     "pstore",
//     "securityfs",
//     "sys",
//     "sysfs",
//     "tmpfs",
//     "tracefs",
// };
