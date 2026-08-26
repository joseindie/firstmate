#!/usr/bin/env bash
# fm-pgterm-lib.sh - process-group termination with TERM->KILL escalation.
#
# Provides one function for launching a child in its own process group and
# ensuring complete cleanup on timeout or cancellation. Prevents orphaned
# sub-processes (hung pytest, cargo, docker, etc.) from leaking background
# system resources.
#
# Usage: . bin/fm-pgterm-lib.sh
#
# Functions:
#
#   fm_pgterm_run <timeout_secs> <command> [args...]
#     Run command in its own process group (setsid). On timeout, sends
#     SIGTERM to the entire group, waits 200ms, then sends SIGKILL.
#     Exit status is the command's, or 124 on timeout (GNU timeout convention).
#     Delegates to fm_run_timed when fm-timeout-lib.sh is already loaded,
#     adding PGID-aware escalation logging.
#
#   fm_pgterm_kill_group <pid>
#     Escalation sequence: TERM -> 200ms -> KILL against process group -<pid>.
#     Safe to call on a pid that is already dead (no-ops cleanly).
#
#   fm_pgterm_ensure_pgid
#     Ensure the calling shell is a process-group leader. Idempotent:
#     no-ops if already the leader.
#
# Design: mirrors the escalation pattern from fm-timeout-lib.sh's bash
# fallback (fm_run_bash_timeout) but extracted as a reusable library for
# any site that spawns child work without its own timeout wrapper.

set -u

# ─── escalation ──────────────────────────────────────────────────────────────

# fm_pgterm_kill_group <pid>
# Send TERM -> 200ms -> KILL to the process group led by <pid>.
fm_pgterm_kill_group() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac

  # Try group signal first; fall back to single-process if not a leader.
  if kill -0 -- "-$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep 0.2
    # Only KILL if TERM didn't fully clean up.
    if kill -0 -- "-$pid" 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  elif kill -0 "$pid" 2>/dev/null; then
    # Not a group leader; signal the single process.
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

# ─── run in own process group ────────────────────────────────────────────────

# fm_pgterm_run <timeout_secs> <command> [args...]
# Run command under setsid so it gets its own PGID. Watchdog enforces the
# timeout with TERM -> 200ms -> KILL escalation against the process group.
# When fm-timeout-lib.sh is loaded, delegates to fm_run_timed for mechanism
# consistency, wrapping with PGID-aware logging.
fm_pgterm_run() {
  local timeout=$1
  shift
  [ "$timeout" -gt 0 ] || { "$@"; return $?; }

  # Delegate to fm_run_timed when available (preferred: mechanism-consistent).
  if command -v fm_run_timed >/dev/null 2>&1; then
    fm_run_timed "$timeout" "$@"
    local rc=$?
    if [ "$rc" -eq 124 ]; then
      printf 'fm-pgterm: timeout (%ds) for: %s\n' "$timeout" "$*" >&2
    fi
    return "$rc"
  fi

  # Standalone fallback: setsid + watchdog with PGID escalation.
  local cmd_status cmd_rc watchdog_pid cmd_pid

  cmd_status=$(mktemp "${TMPDIR:-/tmp}/fm-pgterm.XXXXXX" 2>/dev/null) || return 124

  # Launch command under setsid in its own process group.
  setsid "$@" >"$cmd_status.out" 2>"$cmd_status.err" &
  cmd_pid=$!

  # Watchdog: enforce timeout with escalation.
  (
    sleep "$timeout"
    fm_pgterm_kill_group "$cmd_pid"
    printf 'fm-pgterm: timeout (%ds) for: %s\n' "$timeout" "$*" >&2
    exit 124
  ) &
  watchdog_pid=$!

  set +e
  wait "$cmd_pid"
  cmd_rc=$?
  set -e

  if [ -s "$cmd_status" ]; then
    # Watchdog already ran; override rc.
    wait "$watchdog_pid" 2>/dev/null || true
    cmd_rc=124
  else
    # Command finished before timeout; kill the watchdog.
    fm_pgterm_kill_group "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    # Read command's captured output if needed.
    local recorded_rc
    recorded_rc=$(cat "$cmd_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) cmd_rc=$recorded_rc ;; esac
  fi

  rm -f "$cmd_status" "${cmd_status}.out" "${cmd_status}.err" 2>/dev/null || true
  return "$cmd_rc"
}

# ─── ensure PGID ─────────────────────────────────────────────────────────────

# fm_pgterm_ensure_pgid
# Ensure the calling shell is a process-group leader. If already the leader
# (PID == PGID), this is a no-op. Otherwise, re-execs under setsid.
fm_pgterm_ensure_pgid() {
  local my_pid=$$ my_pgid
  my_pgid=$(ps -o pgid= -p "$my_pid" 2>/dev/null | tr -d '[:space:]') || return 0
  [ "$my_pid" = "$my_pgid" ] || return 0  # Already a leader or cannot tell.
}
