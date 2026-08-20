#!/bin/bash
# root-shizuku.sh — (re)start Shizuku as root and the AOD brightness watcher over ADB.
#
# Run this after every watch reboot. It does two things:
#   1. Restarts Shizuku's server as root (uid 0), which the app needs to write
#      secure settings and the backlight node.
#   2. Deploys and launches the AOD brightness watcher as a detached root daemon.
#
# Why the watcher lives here and not in the app: a process launched by the app
# (via the Shizuku user service) is reaped with the app's cgroup when the service
# is torn down. Launched from this adb-root context it reparents to init, lands in
# the root cgroups, and survives the app closing and every doze cycle. The app only
# writes the chosen brightness to the target file; this watcher applies it on each
# AOD entry (SystemUI resets the backlight to its doze default every time).
#
# Prereq: Developer options -> Rooted debugging enabled on the watch.
set -e

NODE=/sys/class/backlight/sprd_backlight/brightness
TARGET=/data/local/tmp/aod_suite_brightness
SCRIPT=/data/local/tmp/aod_watcher.sh
PIDFILE=/data/local/tmp/aod_watcher.pid
DOZE_DEFAULT=6

adb root
adb wait-for-device

# 1. Shizuku server as root
STARTER=$(adb shell 'ls /data/app/*/moe.shizuku.privileged.api-*/lib/arm64/libshizuku.so' | tr -d '\r')
[[ -z "$STARTER" ]] && { echo "Shizuku app not found on device"; exit 1; }
adb shell "$STARTER"

sleep 2
SPID=$(adb shell 'pgrep -f shizuku_server | head -1' | tr -d '\r')
if [[ -z "$SPID" ]]; then
    echo "WARNING: could not confirm shizuku_server running as root — check the starter output above."
    exit 1
fi

# The starter leaves shizuku_server in a per-pid cgroup (memory /apps/uid_0/pid_*),
# which Android's libprocessgroup reaps during idle/doze — that is why Shizuku "keeps
# stopping" mid-session. Move it into the root cgroups so nothing reaps it (same fix as
# the AOD watcher). This makes it persist for the rest of the boot; a reboot still needs
# this script again (a locked bootloader rules out root-on-boot).
for c in /dev/memcg /dev/cpuset /dev/stune /dev/cpuctl /dev/blkio; do
    adb shell "echo $SPID > $c/cgroup.procs 2>/dev/null" || true
done
echo "OK: Shizuku server is running as root (pid $SPID), moved to root cgroups."

# 2. AOD brightness watcher. It records its own pid to a pidfile (so we can stop it
# without `pkill -f`, which would also match this launching command line). Its first
# act is to escape into the root cgroups so the app/adb teardown can't reap it.
adb shell "cat > $SCRIPT" <<EOS
echo \$\$ > $PIDFILE
for c in /dev/memcg /dev/cpuset /dev/stune /dev/cpuctl /dev/blkio; do
  echo \$\$ > "\$c/cgroup.procs" 2>/dev/null
done
while [ -f "$TARGET" ]; do
  t=\$(cat "$TARGET" 2>/dev/null)
  v=\$(cat "$NODE" 2>/dev/null)
  if [ -n "\$t" ] && [ "\$v" = "$DOZE_DEFAULT" ] && [ "\$t" != "$DOZE_DEFAULT" ]; then
    dumpsys display 2>/dev/null | grep -q mGlobalDisplayState=DOZE && echo "\$t" > "$NODE"
  fi
  sleep 2
done
rm -f $PIDFILE
EOS

# stop any previous watcher via its pidfile, then launch a fresh detached one
adb shell "OLD=\$(cat $PIDFILE 2>/dev/null); [ -n \"\$OLD\" ] && kill \"\$OLD\" 2>/dev/null; nohup setsid sh $SCRIPT </dev/null >/dev/null 2>&1 &"
sleep 2
if adb shell "kill -0 \$(cat $PIDFILE 2>/dev/null) 2>/dev/null"; then
    echo "OK: AOD brightness watcher running (pid $(adb shell cat $PIDFILE | tr -d '\r')). Reopen AOD Suite on the watch."
else
    echo "WARNING: AOD watcher did not start."
    exit 1
fi
