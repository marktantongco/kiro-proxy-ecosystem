#!/bin/bash
# freebuff-owner-guard: enforces session protection configured in
# ~/.config/manicode/session-protect.conf — this session may NOT be taken
# over by another freebuff instance while its pid is alive.
#
# Mechanism (from the freebuff binary's ownership protocol):
#   freebuff-instance-owner.json records {instanceId, pid} of the active
#   session. A new instance auto-claims only when the recorded pid is dead
#   (or it prompts the user for takeover confirmation). If another process
#   overwrites the file while our session is alive, restore it.
#
# The protected session is auto-detected: the freebuff TUI (the binary at
# ~/.config/manicode/freebuff attached to a tty, NOT the --terminal-command-
# broker helper). The instanceId is adopted from whatever the CLI itself
# writes, so the guard survives session restarts.
#
# Consumed as a systemd USER service (Restart=always):
#   ~/.config/systemd/user/freebuff-owner-guard.service
#
# Logs: ~/.config/manicode/freebuff-owner-guard.log

CONF="$HOME/.config/manicode/session-protect.conf"
OWNER_FILE="$HOME/.config/manicode/freebuff-instance-owner.json"
LOG="$HOME/.config/manicode/freebuff-owner-guard.log"
GUARD_SCRIPT="/usr/local/bin/freebuff-owner-guard.sh"

# Cooldown after a restore to avoid write storms from a fighting writer.
COOLDOWN_SECS=10
# Keep trying for a session to appear (systemd Restart= handles crashes).
MAX_STARTUP_WAIT_SECS=600

log() { printf '%s\n' "[$(date '+%F %T')] $*" >> "$LOG"; }

conf_enabled() {
  [ -f "$CONF" ] || return 1
  grep -q '^PROTECT_FROM_TAKEOVER=1' "$CONF" 2>/dev/null || return 1
  grep -q '^BLOCK_AUTOUPDATE=1' "$CONF" 2>/dev/null || return 1
}

# Locate the live freebuff TUI: the manicode/freebuff binary attached to a
# tty (pts/*, tty*), excluding the --terminal-command-broker helper which has
# no tty. Returns the pid, or empty if none is currently running.
find_session_pid() {
  ps -eo pid,tty,args 2>/dev/null | \
    grep -E '[.]config/manicode/freebuff( |$)' | \
    grep -v 'grep' | \
    grep -v 'terminal-command-broker' | \
    awk '$2 ~ /^(pts|tty)/ {print $1}' | head -1
}

read_owner() {
  [ -f "$OWNER_FILE" ] || { printf ' \n'; return; }
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("instanceId", ""), d.get("pid", 0))
except Exception:
    print("")
' "$OWNER_FILE" 2>/dev/null
}

write_owner() { # $1 instanceId  $2 pid
  printf '{\n  "instanceId": "%s",\n  "pid": %s\n}\n' "$1" "$2" > "$OWNER_FILE" 2>/dev/null
}

main() {
  log "guard start (conf=$CONF)"

  if ! conf_enabled; then
    log "protection disabled in config — exiting (no takeover guard)"
    exit 0
  fi

  # Wait (bounded) for a freebuff TUI session to appear.
  deadline=$(( $(date +%s) + MAX_STARTUP_WAIT_SECS ))
  session_pid=""
  while [ -z "$session_pid" ]; do
    session_pid=$(find_session_pid)
    [ -n "$session_pid" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "no freebuff TUI session found within ${MAX_STARTUP_WAIT_SECS}s — exiting"
      exit 0
    fi
    sleep 5
  done
  log "protecting session pid=$session_pid"

  last_restore=0
  while :; do
    session_pid=$(find_session_pid)
    if [ -z "$session_pid" ]; then
      log "session pid gone — stopping guard (session ended)"
      exit 0
    fi

    read -r owner_iid owner_pid <<< "$(read_owner)"

    # If the file is missing or empty, (re)assert ownership with the CLI's
    # instanceId if we can read it, otherwise leave it for the CLI to write.
    if [ -z "$owner_iid" ]; then
      now=$(date +%s)
      if [ $((now - last_restore)) -ge "$COOLDOWN_SECS" ]; then
        log "owner file missing/empty — asserting pid=$session_pid"
        write_owner "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("instanceId",""))' "$OWNER_FILE" 2>/dev/null || echo unknown)" "$session_pid"
        last_restore=$now
      fi
    elif [ "$owner_pid" != "$session_pid" ]; then
      # The file points at a DIFFERENT pid while our session is alive.
      # Only restore if the recorded pid is dead (stale) OR it is a foreign
      # live claim — either way our live session must stay the owner.
      if [ "$owner_pid" != "0" ] && kill -0 "$owner_pid" 2>/dev/null; then
        now=$(date +%s)
        if [ $((now - last_restore)) -ge "$COOLDOWN_SECS" ]; then
          log "FOREIGN owner pid=$owner_pid alive — RESTORED to pid=$session_pid"
          write_owner "$owner_iid" "$session_pid"
          last_restore=$now
        fi
      else
        now=$(date +%s)
        if [ $((now - last_restore)) -ge "$COOLDOWN_SECS" ]; then
          log "stale owner pid=$owner_pid dead — RESTORED to pid=$session_pid"
          write_owner "$owner_iid" "$session_pid"
          last_restore=$now
        fi
      fi
    fi
    sleep 3
  done
}

main "$@"
