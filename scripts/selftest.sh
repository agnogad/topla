#!/usr/bin/env bash
# Checks that yt-dlp is reachable through the real IPC bridge under Xvfb.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
N=${DISPLAY_NUM:-67}
Xvfb ":$N" -screen 0 1280x800x24 >/dev/null 2>&1 &
XV=$!
sleep 1.5
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE DISPLAY=":$N" GDK_BACKEND=x11 \
  WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 \
  TOPLA_SELFTEST=1 "$ROOT/zig-out/bin/topla" >/tmp/topla-selftest.log 2>&1 &
APP=$!
sleep 6
kill $APP 2>/dev/null
kill $XV 2>/dev/null
grep -E 'TOPLA SELFTEST|CONSOLE JS ERROR' /tmp/topla-selftest.log
grep -q 'TOPLA SELFTEST PASS' /tmp/topla-selftest.log
