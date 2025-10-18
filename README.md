# disk-usage-monitor-waybar

A storage monitoring Waybar module. Displays a summary of disk usage for each mounted fs.

Reads currently mounted filesystems from `/proc/mounts`, and outputs a summary in a Waybar-compatible JSON format.
Updates every 20sec.

### Demo:

![Demo](/screenshots/demo.png)

# Build

Requires Zig `0.15.x`.

Depends on libc for `sys/statvfs.h`.

```sh
zig build -Doptimize=ReleaseFast
```

I prefer `ReleaseFast` since it's running as part of my desktop, though you can use whatever safety mode you prefer.

## Build for development/testing

I've added a `no-bin` option in `build.zig` to enable incremental build/filesystem watching *without* emitting a binary, to catch compiler errors immediately upon file save:

```sh
zig build -Dno-bin -fincremental --watch --debounce 100
```

Build for valgrind/massif:

```sh
zig build -Doptimize=ReleaseFast -Dcpu=baseline
```
Then run under i.e. massif:
```sh
valgrind --tool=massif ./zig-out/bin/disk-usage-monitor-waybar
```

Note: You must use the `std.heap.c_allocator` (or `heap.raw_c_allocator`) to profile a Zig executable under valgrind/massif, otherwise massif will report zero heap usage/incorrect leak results.

Executable comes out to ~380KiB depending on target. Peak heap usage around 13KiB with ~10 mounted filesystems.

# Usage

After compiling, place the executable somewhere that's in Waybar's `PATH`, I prefer to create a `bin` directory at either `~/bin/` or `~/.config/bin/` - wherever you put your dotfile-related executables is fine.

## Config

First, add it to your waybar config and configure however you want it. An example is included in `example-configs/bar.conf`.

```jsonc
"modules-right": [
    "custom/disk-usage"
],

// Can name it whatever you want, as long as you use the same name everywhere (including CSS)
"custom/disk-usage": {
        "exec": "/path/to/bin/disk-usage-monitor-waybar", 
        "return-type": "json",
        "format": "{icon} {text} {percentage}%",
        "restart-interval": 30,
        // This optional `format-icons` config will display warning icon if `percentage` is >75%, otherwise the HDD icon:
        "format-icons": {
            "default": [
                "🖴",
                "🖴",
                "🖴",
                "⚠️"
            ],
        }
    },
```

## Styling

Module output includes some CSS class modifiers that Waybar will pull, so you can optionally style the widget with i.e. different colors based on level of disk usage - `.low`, `.medium`, `.high`, and `.critical`.

Example stylesheet applying various colors mapped to usage level:

```css
/* Default color */
#custom-disk-usage {
    color: @darkForeground1;
}
#custom-disk-usage.low {
    color: @darkStrongGreen;
}
#custom-disk-usage.medium {
    color: @darkStrongYellow;
}
#custom-disk-usage.high {
    color: @darkMutedRed;
}
#custom-disk-usage.critical, #custom-disk-usage.err {
    color: @darkStrongRed;
}
```
