#!/usr/bin/env bash
# fm-yaml-check.sh - validate YAML frontmatter of every SKILL.md across agent skill surfaces.
#
# Sweeps each surface directory for */SKILL.md files (recursive) and parses the
# frontmatter block between the leading "---" fences with Python's yaml module.
# A file whose frontmatter does not parse breaks skill loading for that runtime
# (the "[Skill conflicts]" session-start banner class of bug). The common cause
# is an unquoted scalar value containing ": ", which YAML reads as a nested key.
#
# Usage:
#   bin/fm-yaml-check.sh [surface-dir ...]
#     With no arguments this sweeps the five known default surfaces:
#       ~/.pi/agent/skills ~/.claude/skills ~/.codex/skills
#       ~/crew/.agents/skills ~/crew/skills
#
# Output: one "BROKEN: <path>" block per unparseable file, then a summary line.
# Exit codes: 0 every parsed frontmatter is valid; 1 at least one broken;
# 2 the python3 yaml module is unavailable.
# Read-only: parses files in place and never writes.
#
# First wired into the ONYX nightly maintenance read-only audit as audit step
# 3h (skill onyx-nightly-maintenance), 2026-08-23.

set -u

if [ "$#" -gt 0 ]; then
  surfaces=("$@")
else
  surfaces=(
    "$HOME/.pi/agent/skills"
    "$HOME/.claude/skills"
    "$HOME/.codex/skills"
    "$HOME/crew/.agents/skills"
    "$HOME/crew/skills"
  )
fi

python3 - "${surfaces[@]}" <<'PY'
import glob
import os
import sys

try:
    import yaml
except ImportError:
    print("fm-yaml-check: python3 yaml module not available", file=sys.stderr)
    sys.exit(2)

broken = 0
scanned = 0
for surface in sys.argv[1:]:
    pattern = os.path.join(surface, "**", "SKILL.md")
    for path in sorted(glob.glob(pattern, recursive=True)):
        scanned += 1
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        if not lines or lines[0].strip() != "---":
            continue  # no frontmatter block; nothing to validate
        end = next(
            (i for i in range(1, len(lines)) if lines[i].strip() == "---"),
            None,
        )
        if end is None:
            broken += 1
            print(f"BROKEN: {path}")
            print("  unterminated frontmatter (no closing ---)")
            continue
        try:
            yaml.safe_load("\n".join(lines[1:end]))
        except Exception as exc:
            broken += 1
            first = str(exc).splitlines()[0] if str(exc) else "unparseable"
            print(f"BROKEN: {path}")
            print(f"  {first}")

print(f"{scanned} SKILL.md files scanned, {broken} broken")
sys.exit(1 if broken else 0)
PY
