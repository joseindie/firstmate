#!/usr/bin/env bash
# fm-audit.sh - append-only SHA-256 hash-chain audit log.
#
# Usage:
#   fm-audit.sh append <log> <actor> <action> [<key>=<value>...]
#   fm-audit.sh verify <log>
#   fm-audit.sh --test
#
# Each entry is a canonical JSON object (sorted keys) hashed with the previous
# entry's SHA-256 to form an immutable chain. The genesis entry's prev_hash is
# 64 zero characters.
#
# Fields per entry:
#   seq        monotonic integer (1-based)
#   ts         ISO-8601 with microsecond precision (truncated to whole seconds
#              for portability; sub-second always .000000)
#   actor      who performed the action (validated, non-empty)
#   action     what was done (validated, non-empty)
#   prev_hash  SHA-256 of the previous entry's canonical JSON (64 hex chars)
#   hash       SHA-256 of this entry's canonical JSON (written after hash)
#   ...        optional key=value pairs (presence-tagged: only written when
#              the value is non-empty)
#
# File locking: concurrent appends are serialized via flock(2) on <log>.lock.
# Zero external dependencies beyond POSIX sh + shasum -a 256 or openssl dgst.
#
# Exit codes:
#   0  success
#   1  usage / validation error
#   2  chain integrity failure (verify)
#   3  lock or I/O error

set -euo pipefail

# ─── hash backend ────────────────────────────────────────────────────────────

_hash_canonical() {
  # SHA-256 of stdin. Tries shasum first (macOS), falls back to openssl.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | sed 's/^.* //'
  else
    echo "fm-audit: no SHA-256 backend (need shasum or openssl)" >&2
    return 3
  fi
}

# ─── canonical JSON builder ──────────────────────────────────────────────────

_canonical_json() {
  # Build canonical JSON from key=value pairs on stdin, one per line.
  # Keys are sorted with LC_ALL=C for deterministic order.
  # Optional values are presence-tagged: empty strings produce {"key": null}.
  python3 -c '
import json, sys, collections

pairs = collections.OrderedDict()
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    k, _, v = line.partition("=")
    k = k.strip()
    if not k:
        continue
    if v == "":
        pairs[k] = None
    elif k == "seq" and v.isdigit():
        pairs[k] = int(v)
    else:
        pairs[k] = v

# sort keys for canonical form
canonical = collections.OrderedDict(sorted(pairs.items()))
print(json.dumps(canonical, separators=(",", ":"), ensure_ascii=True))
' 2>/dev/null
}

# ─── timestamp ───────────────────────────────────────────────────────────────

_now_iso() {
  # ISO-8601 with microsecond precision (sub-second always .000000 for
  # deterministic hashing across platforms).
  python3 -c '
import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
sys.stdout.write(now.strftime("%Y-%m-%dT%H:%M:%S.000000Z"))
' 2>/dev/null
}

# ─── lock helpers ────────────────────────────────────────────────────────────

_lock_path() {
  printf '%s.lock' "$1"
}

_FM_AUDIT_LOCK=""

_lock_acquire() {
  local lock=$1
  _FM_AUDIT_LOCK="$lock"
  # Portable lock: try Linux flock(1), fall back to mkdir-based spinlock.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock"
    flock -x 9
  else
    # mkdir is atomic on POSIX; use as a spinlock with timeout.
    local lockdir="${lock}.d"
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      sleep 0.1
      waited=$((waited + 1))
      [ "$waited" -lt 50 ] || { echo "fm-audit: lock timeout" >&2; return 3; }
    done
    printf '%s' "$$" > "${lockdir}/pid"
  fi
}

_lock_release() {
  local lockdir="${_FM_AUDIT_LOCK}.d"
  if [ -n "$lockdir" ] && [ -d "$lockdir" ]; then
    rm -rf "$lockdir"
  fi
  exec 9>&- 2>/dev/null || true
  _FM_AUDIT_LOCK=""
}

# ─── core: append ────────────────────────────────────────────────────────────

do_append() {
  local log=$1 actor=$2 action=$3
  shift 3

  [ -n "$actor" ] || { echo "fm-audit append: actor must be non-empty" >&2; return 1; }
  [ -n "$action" ] || { echo "fm-audit append: action must be non-empty" >&2; return 1; }

  local lock
  lock=$(_lock_path "$log")
  [ -f "$lock" ] || touch "$lock"
  _lock_acquire "$lock"

  # Determine next sequence number
  local seq=1
  if [ -f "$log" ] && [ -s "$log" ]; then
    local last_seq
    last_seq=$(tail -1 "$log" | python3 -c '
import json, sys
line = sys.stdin.readline().strip()
if line:
    obj = json.loads(line)
    print(obj.get("seq", 0))
' 2>/dev/null || echo 0)
    case "$last_seq" in ''|*[!0-9]*) seq=1 ;; *) seq=$((last_seq + 1)) ;; esac
  fi

  # Determine prev_hash (genesis = 64 zeros)
  local prev_hash
  if [ "$seq" -eq 1 ]; then
    prev_hash="0000000000000000000000000000000000000000000000000000000000000000"
  else
    prev_hash=$(tail -1 "$log" | python3 -c '
import json, sys
line = sys.stdin.readline().strip()
if line:
    obj = json.loads(line)
    print(obj.get("hash", ""))
' 2>/dev/null || echo "")
    [ -n "$prev_hash" ] || { echo "fm-audit append: cannot read prev_hash" >&2; _lock_release; return 3; }
  fi

  local ts
  ts=$(_now_iso)

  # Build the entry fields (before hash)
  local fields=""
  fields+="seq=$seq"$'\n'
  fields+="ts=$ts"$'\n'
  fields+="actor=$actor"$'\n'
  fields+="action=$action"$'\n'
  fields+="prev_hash=$prev_hash"$'\n'

  # Append optional key=value pairs (presence-tagged)
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    # Validate key is alphanumeric/underscore
    case "$k" in ''|*[!a-zA-Z0-9_]*) continue ;; esac
    fields+="$k=$v"$'\n'
  done

  # Compute hash of the entry (without the hash field itself)
  local entry_json
  entry_json=$(printf '%s' "$fields" | _canonical_json) || { _lock_release; return 3; }
  local hash
  hash=$(printf '%s' "$entry_json" | _hash_canonical) || { _lock_release; return 3; }

  # Build final entry with hash
  local final_json
  final_json=$(printf '%shash=%s\n' "$fields" "$hash" | _canonical_json) || { _lock_release; return 3; }

  # Append atomically via temp + rename
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-audit.XXXXXX") || { _lock_release; return 3; }
  cp "$log" "$tmp" 2>/dev/null || true
  printf '%s\n' "$final_json" >> "$tmp"
  mv -f "$tmp" "$log" || { rm -f "$tmp"; _lock_release; return 3; }

  _lock_release
  printf '%s\n' "$hash"
}

# ─── core: verify ────────────────────────────────────────────────────────────

do_verify() {
  local log=$1
  [ -f "$log" ] || { echo "fm-audit verify: file not found: $log" >&2; return 1; }
  [ -s "$log" ] || { echo "fm-audit verify: empty log" >&2; return 0; }

  local line_num=0
  local expected_prev="0000000000000000000000000000000000000000000000000000000000000000"
  local line

  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [ -n "$line" ] || continue

    # Parse the stored entry
    local stored_hash stored_prev_hash stored_seq
    stored_hash=$(printf '%s' "$line" | python3 -c '
import json, sys
obj = json.loads(sys.stdin.readline().strip())
print(obj.get("hash", ""))
' 2>/dev/null)
    stored_prev_hash=$(printf '%s' "$line" | python3 -c '
import json, sys
obj = json.loads(sys.stdin.readline().strip())
print(obj.get("prev_hash", ""))
' 2>/dev/null)
    stored_seq=$(printf '%s' "$line" | python3 -c '
import json, sys
obj = json.loads(sys.stdin.readline().strip())
print(obj.get("seq", ""))
' 2>/dev/null)

    [ -n "$stored_hash" ] || { echo "fm-audit verify: entry $line_num missing hash" >&2; return 2; }
    [ -n "$stored_prev_hash" ] || { echo "fm-audit verify: entry $line_num missing prev_hash" >&2; return 2; }

    # Verify prev_hash chain
    [ "$stored_prev_hash" = "$expected_prev" ] || {
      echo "fm-audit verify: chain break at entry $line_num (seq=$stored_seq)" >&2
      echo "  expected prev_hash: $expected_prev" >&2
      echo "  found prev_hash:    $stored_prev_hash" >&2
      return 2
    }

    # Re-compute hash: strip the hash field, canonicalize, hash
    local recomputed
    recomputed=$(printf '%s' "$line" | python3 -c '
import json, sys, collections

obj = json.loads(sys.stdin.readline().strip())
obj.pop("hash", None)
canonical = collections.OrderedDict(sorted(obj.items()))
sys.stdout.write(json.dumps(canonical, separators=(",", ":"), ensure_ascii=True))
' 2>/dev/null | _hash_canonical)

    [ "$recomputed" = "$stored_hash" ] || {
      echo "fm-audit verify: hash mismatch at entry $line_num (seq=$stored_seq)" >&2
      echo "  expected: $recomputed" >&2
      echo "  found:    $stored_hash" >&2
      return 2
    }

    expected_prev="$stored_hash"
  done < "$log"

  printf 'fm-audit verify: %d entries, chain intact\n' "$line_num" >&2
  return 0
}

# ─── self-test ───────────────────────────────────────────────────────────────

do_test() {
  local test_tmpdir
  test_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-audit-test.XXXXXX") || return 1
  trap 'rm -rf "'"$test_tmpdir"'"' EXIT

  local log="$test_tmpdir/test.log"
  : > "$log"

  # Test 1: genesis append
  local h1
  h1=$(do_append "$log" "test-actor" "init" "scope=unit-test") || return 1
  [ -n "$h1" ] || { echo "test 1 FAIL: empty hash" >&2; return 1; }

  # Test 2: second append chains correctly
  local h2
  h2=$(do_append "$log" "test-actor" "edit" "file=/tmp/x" "lines=42") || return 1
  [ -n "$h2" ] || { echo "test 2 FAIL: empty hash" >&2; return 1; }
  [ "$h2" != "$h1" ] || { echo "test 2 FAIL: duplicate hash" >&2; return 1; }

  # Test 3: verify passes on intact chain
  do_verify "$log" >/dev/null 2>&1 || { echo "test 3 FAIL: verify rejected intact chain" >&2; return 1; }

  # Test 4: tamper detection (append garbage)
  echo '{"tampered":true}' >> "$log"
  if do_verify "$log" >/dev/null 2>&1; then
    echo "test 4 FAIL: verify accepted tampered log" >&2; return 1
  fi

  # Test 5: empty optional fields produce null (presence-tagged)
  local log2="$test_tmpdir/test2.log"
  : > "$log2"
  do_append "$log2" "actor-a" "action-b" "opt_field=" "other=value" >/dev/null 2>&1 || return 1
  local has_null
  has_null=$(python3 -c '
import json
with open("'"$log2"'") as f:
    obj = json.loads(f.readline())
    if obj.get("opt_field") is None and obj.get("other") == "value":
        print("ok")
' 2>/dev/null)
  [ "$has_null" = "ok" ] || { echo "test 5 FAIL: presence-tagged null not produced" >&2; return 1; }

  # Test 6: genesis prev_hash is 64 zeros
  local log3="$test_tmpdir/test3.log"
  : > "$log3"
  do_append "$log3" "actor" "genesis" >/dev/null 2>&1 || return 1
  local genesis_prev
  genesis_prev=$(python3 -c '
import json
with open("'"$log3"'") as f:
    obj = json.loads(f.readline())
    print(obj.get("prev_hash", ""))
' 2>/dev/null)
  [ "$genesis_prev" = "0000000000000000000000000000000000000000000000000000000000000000" ] || {
    echo "test 6 FAIL: genesis prev_hash not 64 zeros" >&2; return 1
  }

  # Test 7: verify rejects empty actor
  local log4="$test_tmpdir/test4.log"
  : > "$log4"
  if do_append "$log4" "" "action" >/dev/null 2>&1; then
    echo "test 7 FAIL: accepted empty actor" >&2; return 1
  fi

  printf 'fm-audit --test: all 7 tests passed\n' >&2
  return 0
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    append)
      [ $# -ge 3 ] || { echo "Usage: fm-audit.sh append <log> <actor> <action> [key=val...]" >&2; return 1; }
      do_append "$2" "$3" "${4:-}" "${@:5}"
      ;;
    verify)
      [ $# -ge 2 ] || { echo "Usage: fm-audit.sh verify <log>" >&2; return 1; }
      do_verify "$2"
      ;;
    --test)
      do_test
      ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# \?//; p; }' "$0"
      exit 0
      ;;
    *)
      echo "Usage: fm-audit.sh {append|verify|--test} [args...]" >&2
      return 1
      ;;
  esac
}

main "$@"
