#!/usr/bin/env sh
# Launch Waybar with only this module, for testing
# Usage: (from base dir) `./example-configs/waybarloop.sh`

waybar -c ./example-configs/waybarloop.conf -s ./example-configs/bar.style.css --bar 42
