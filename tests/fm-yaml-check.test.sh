#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for bin/fm-yaml-check.sh.
#
# The script is the single owner of the skill-frontmatter sweep. These tests are
# hermetic: they build temp fixture surfaces and assert parse outcomes, exit
# codes, and output shape without touching real skill directories.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-yaml-check.sh"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 unavailable; cannot test fm-yaml-check"
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  fail "python3 yaml module unavailable; cannot test fm-yaml-check"
fi

make_surface() {  # <name> -> subdir under the suite temp root
  mkdir -p "$TMP_ROOT/$1"
  printf '%s\n' "$TMP_ROOT/$1"
}

TMP_ROOT=$(fm_test_tmproot fm-yaml-check-tests)

GOOD_SKILL='---
name: good-skill
description: "quoted value with: inner colon is fine"
version: 1.0.0
---

body
'

BAD_COLON_SKILL='---
name: bad-skill
description: unquoted value with: inner colon breaks parsing
---

body
'

UNTERMINATED_SKILL='---
name: unterminated
description: no closing fence

body
'

NO_FRONTMATTER_SKILL='# Just A Heading

body with no frontmatter at all
'

write_skill() {  # <path-without-or-with-subdirs> <content>
  mkdir -p "$(dirname "$1/SKILL.md")"
  printf '%s' "$2" > "$1/SKILL.md"
}

# --- happy path: clean surface passes --------------------------------------

test_clean_surface_exits_zero() {
  local surf out rc
  surf=$(make_surface clean) || fail "make_surface"
  write_skill "$surf" "$GOOD_SKILL"
  out=$(bash "$CHECK" "$surf" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "clean surface should exit 0, got $rc: $out"
  printf '%s' "$out" | grep -q "1 SKILL.md files scanned, 0 broken" ||
    fail "summary line wrong: $out"
}

# --- broken colon value is caught -------------------------------------------

test_broken_colon_value_caught() {
  local surf out rc
  surf=$(make_surface badcolon) || fail "make_surface"
  write_skill "$surf/good" "$GOOD_SKILL"
  write_skill "$surf/bad" "$BAD_COLON_SKILL"
  out=$(bash "$CHECK" "$surf" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "broken frontmatter should exit 1, got $rc: $out"
  printf '%s' "$out" | grep -q "BROKEN: $surf/bad/SKILL.md" ||
    fail "should name the broken file: $out"
  printf '%s' "$out" | grep -qi "nested\|mapping" ||
    fail "should carry the yaml error line: $out"
  printf '%s' "$out" | grep -q "2 SKILL.md files scanned, 1 broken" ||
    fail "summary counts wrong: $out"
}

# --- unterminated fence is caught -------------------------------------------

test_unterminated_fence_caught() {
  local surf out rc
  surf=$(make_surface unterm) || fail "make_surface"
  write_skill "$surf" "$UNTERMINATED_SKILL"
  out=$(bash "$CHECK" "$surf" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "unterminated fence should exit 1, got $rc: $out"
  printf '%s' "$out" | grep -q "unterminated frontmatter" ||
    fail "should report unterminated fence: $out"
}

# --- no frontmatter is skipped, not failed ----------------------------------

test_no_frontmatter_skipped() {
  local surf out rc
  surf=$(make_surface nofm) || fail "make_surface"
  write_skill "$surf" "$NO_FRONTMATTER_SKILL"
  out=$(bash "$CHECK" "$surf" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "no-frontmatter file should be skipped, got $rc: $out"
  printf '%s' "$out" | grep -q "1 SKILL.md files scanned, 0 broken" ||
    fail "scan count wrong: $out"
}

# --- nested surfaces and multiple args ---------------------------------------

test_nested_and_multi_surface() {
  local a b out rc
  a=$(make_surface multiA) || fail "make_surface a"
  b=$(make_surface multiB) || fail "make_surface b"
  mkdir -p "$a/nested/deep"
  write_skill "$a/nested/deep" "$BAD_COLON_SKILL"
  write_skill "$b" "$GOOD_SKILL"
  out=$(bash "$CHECK" "$a" "$b" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "multi-surface broken file should exit 1, got $rc: $out"
  printf '%s' "$out" | grep -q "BROKEN: $a/nested/deep/SKILL.md" ||
    fail "recursive glob missed nested file: $out"
  printf '%s' "$out" | grep -q "2 SKILL.md files scanned, 1 broken" ||
    fail "cross-surface counts wrong: $out"
}

test_clean_surface_exits_zero
test_broken_colon_value_caught
test_unterminated_fence_caught
test_no_frontmatter_skipped
test_nested_and_multi_surface

pass "fm-yaml-check behavior tests passed"
