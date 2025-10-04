//! A Waybar module for displaying storage usage info.
//! Gives a summary of total usage of each mounted filesystem.
//! Zig 0.15.1

const std = @import("std");
const heap = std.heap;
const Io = std.Io;
const Thread = std.Thread;
const time = std.time;

const lib = @import("disk-usage-monitor-waybar"); // root.zig

const MOUNTS_PATH: []const u8 = "/proc/mounts";
const UPDATE_INTERVAL: u64 = 20 * time.ns_per_s;

pub fn main() !void {
    const c_allocator = heap.raw_c_allocator;

    // Parse command line options
    var options = lib.Options{};
    try options.read();

    while (true) {
        analyze: {
            var tmp_arena: heap.ArenaAllocator = .init(c_allocator);
            defer tmp_arena.deinit();
            var allocator = tmp_arena.allocator();

            var w: Io.Writer.Allocating = .init(allocator);
            defer w.deinit();

            // Read `/proc/mounts` contents, as bytes
            const file_contents: []const u8 = try lib.readFileBytes(allocator, MOUNTS_PATH);
            defer allocator.free(file_contents);

            // Parse contents to get the data we're interested in
            const output_parts: lib.OutputWaybar = try lib.parseMnts(allocator, file_contents, &options, &w);
            defer allocator.free(output_parts.tooltip);

            // Format final output
            const output: []const u8 = try output_parts.jsonify(allocator, &w);
            defer allocator.free(output);

            try lib.bufferedPrint(output);

            break :analyze;
        }

        update: {
            const pid = try lib.getPidByName("waybar");
            if (pid) |p| {
                @branchHint(.likely);
                try lib.rtSig(p, 16);
            }

            break :update;
        }

        Thread.sleep(UPDATE_INTERVAL);
    }
}
