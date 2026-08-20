#!/bin/bash
# root-shizuku.sh — (re)start Shizuku as root over ADB.
# Needed after every watch reboot: the AOD brightness control writes the
# backlight sysfs node, which requires Shizuku's server to run as uid 0.
# Prereq: Developer options -> Rooted debugging enabled on the watch.
set -e

adb root
adb wait-for-device
STARTER=$(adb shell 'ls /data/app/*/moe.shizuku.privileged.api-*/lib/arm64/libshizuku.so' | tr -d '\r')
[[ -z "$STARTER" ]] && { echo "Shizuku app not found on device"; exit 1; }
adb shell "$STARTER"

sleep 2
if adb shell 'ps -A -o USER,NAME | grep -q "^root .*shizuku_server"'; then
    echo "OK: Shizuku server is running as root. Reopen AOD Suite on the watch."
else
    echo "WARNING: could not confirm shizuku_server running as root — check the starter output above."
    exit 1
fi
