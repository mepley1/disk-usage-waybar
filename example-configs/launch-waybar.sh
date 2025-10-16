#!/usr/bin/env sh
# Launch Waybar with only this module, for testing
# Usage: (from base dir) `./example-configs/launch-waybar.sh`

waybar -c ./example-configs/bar.conf -s ./example-configs/bar.style.css --bar 42
