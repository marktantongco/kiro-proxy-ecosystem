#!/usr/bin/env bash
# mem-monitor — track the Freebuff TUI's memory over time to verify the V8
# heap cap (NODE_OPTIONS in ~/.profile) is working and catch growth.
#
# Usage:
#   mem-monitor                one sample now
#   mem-monitor --log          append timestamped sample to the history file
#   mem-monitor --report       show last 12 samples (growth trend)
#
# The TUI is auto-detected by its binary path (the owner file also records it).

OWNER_FILE="$HOME/.config/manicode/freebuff-instance-owner.json"
LOG="$HOME/.config/manicode/freebuff-mem.log"
TUI_BIN="$HOME/.config/manicode/freebuff"

now() { date '+%Y-%m-%d %H:%M:%S'; }

find_tui_pid() {
  # 1) owner file pid, 2) pgrep fallback
  PID=$(python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d.get("pid",0))
except Exception:
    print(0)
' "$OWNER_FILE" 2>/dev/null)
  [ -n "$PID" ] && [ "$PID" != "0" ] && kill -0 "$PID" 2>/dev/null && { echo "$PID"; return; }
  pgrep -f 'manicode/freebuff' 2>/dev/null | head -1
}

sample() {
  PID=$(find_tui_pid)
  if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "$(now) TUI_NOT_RUNNING"
    return 1
  fi
  RSS=$(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null | head -1)
  SW=$(awk '/VmSwap/{print $2}' /proc/$PID/status 2>/dev/null | head -1)
  PSS=$(awk '/Pss:/{print $2}' /proc/$PID/smaps_rollup 2>/dev/null | head -1)
  RSS=${RSS:-0}; SW=${SW:-0}; PSS=${PSS:-0}
  echo "$(now) pid=$PID rss=$((RSS/1024))MB pss=$((PSS/1024))MB swap=$((SW/1024))MB"
}

case "${1:-}" in
  --log)   sample >> "$LOG" 2>/dev/null; tail -1 "$LOG";;
  --report) echo "last 12 samples ($LOG):"; tail -12 "$LOG" 2>/dev/null || echo "  (no history yet — run with --log)";;
  *)       sample;;
esac
