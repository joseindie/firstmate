# Crew Workspace Notes (operator-private, gitignored)

Local operational notes for `~/crew` (renamed from `~/kun-agent-workspace` on 2026-07-19).
This directory is the FirstMate home. Pi becomes FirstMate here; crewmates are Pi spawned
into Herdr panes via Treehouse worktrees.

## Topology (faithful to Kun Chen's design, Option A)
```
operator (captain)
  └─ WezTerm → Herdr (prefix Ctrl+B)
        ├─ pane w5:p1  → Pi running AS FirstMate (supervisor; holds session lock)
        └─ spawned panes → Pi crewmates (harness=pi) in Treehouse worktrees
              └─ models pulled via CPAMC (http://127.0.0.1:8317/v1) → Antigravity/Gemini
```
- FirstMate (FM) is the SOLE orchestrator. It is Pi in supervisor mode (reads AGENTS.md).
- Crewmates are spawned BY FM via fm-spawn.sh. They are also Pi (harness=pi), or claude/codex/
  opencode/grok per crew-dispatch.json rules.
- AGY (Antigravity) is the MODEL SOURCE only — powers crewmates through CPAMC. It is NOT a
  peer orchestrator pane (do not run agy alongside FM as a second boss; that creates a
  dual-supervisor conflict over the crew lock).

## Critical gotchas (learned 2026-07-19)
1. **Herdr prefix = Ctrl+B.** Alt+Space does NOT bind on this Mac (macOS/terminal eats
   Option+Space before Herdr sees it). `prefix_key = "alt+space"` in config.toml BROKE the
   default ctrl+b and a reload could NOT undo it — required full `herdr server stop` + relaunch.
   NEVER write a prefix_key variant without a hard restart to verify.
2. **Restart Pi after any path change to reload extensions.** The two FirstMate extensions
   (~/crew/.pi/extensions/fm-primary-*.ts) load at Pi launch based on the trusted path. After
   renaming the dir, rewrite `~/.pi/agent/trust.json` key to the new absolute path, then relaunch
   Pi from the new dir. Verify via fm-session-start.sh (PI_WATCH_EXTENSION reminder should be gone).
3. **CPAMC models must be declared in Pi models.json.** The cliproxyapi provider block lists the
   live CPAMC models; if it's stale/incomplete the /model selector only shows a few. Keep it in sync
   with `curl -s http://127.0.0.1:8317/v1/models`. Set compat.supportsReasoningEffort=true so the
   effort tiers (High/Medium/Low) are selectable.
4. **Primary Pi model** is openrouter/tencent/hy3:free (operator choice, until ~21 July). If
   OpenRouter credits die, Pi primary 503s but crewmates (on CPAMC) stay up. Flip Pi primary to
   cliproxyapi/gemini-3-flash-agent if that happens.

## Durable config
- `config/backend` = `herdr` (FM_BACKEND explicit; avoids relying on HERDR_ENV autodetect).
- `config/crew-harness` = `pi`.
- `config/crew-dispatch.json` = rules[]+default schema (default model gemini-3-flash-agent, High).
  Tiers: extra-low/low = Gemini 3.5 Flash Low; -low = Medium; -agent = High; gemini-pro-agent =
  Pro High; claude-opus-4-6-thinking = max reasoning (sparingly, token-scarce).

## Trust
- `~/.pi/agent/trust.json` key `/Users/jose/crew` = true (was /Users/jose/kun-agent-workspace).

## Launch sequence
```
cd ~/crew
herdr            # prefix Ctrl+B; release before action key
# in primary pane:
pi               # loads as FirstMate, extensions auto-load from trusted ~/crew
> Ahoy. Run the FirstMate session startup... (verify toolchain)
```

## Verified working (2026-07-19)
- Toolchain: git/gh/jq/curl/tmux, treehouse, no-mistakes v1.40.0, tasks-axi, node — all present.
- gh auth: joseindie.
- Herdr v0.7.4 protocol 16, server live, backend smoke tests PASS.
- fm_watch_arm_pi armed.
- Guarded --backend herdr spawn smoke PASSED (isolated lab, gemini-3-flash-agent, clean teardown).
- CPAMC 11 models declared in cliproxyapi block; High/Medium/Low tiers selectable.

## AGY patches to Pi TUI (2026-07-19, by AGY CLI task-320)
AGY diagnosed + patched the Pi TUI so /model shows friendly names and /reload re-reads models.json live.
These are HAND EDITS to Pi's compiled dist bundles — NON-DURABLE.

Patch locations (re-verify after any `pi update --self`):
- /opt/zerobrew/prefix/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/agent-session.js:2056
  → added `await this._modelRuntime.reloadConfig();` inside /reload so models.json edits load without restart.
- /opt/zerobrew/prefix/lib/node_modules/@earendil-works/pi-coding-agent/dist/modes/interactive/components/model-selector.js:217,223
  → list items render `item.model.name ?? item.id` (friendly name primary, id fallback). This is what makes
  the selector show "Gemini 3.5 Flash (High)" instead of the raw id.

Durability warning:
- `pi update --self` OVERWRITES these dist files → patches vanish, selector reverts to id-only, /reload stops
  re-reading models.json. Re-apply both edits after any Pi update.
- Root-cause note: a FRESH `pi --new-session` already read all 11 models (empirically proven). The "old 5" was a
  resumed stale session. AGY's /reload patch is a bonus, not the only fix.

## Zsh auto_activate_venv warning (fixed 2026-07-19, by AGY)
- ~/.zshrc auto_activate_venv() now guards `deactivate` with `whence deactivate &>/dev/null` (~line 237).
- Warning `auto_activate_venv:20: command not found: deactivate` eliminated on new shells.

## Session handoff artifact (AGY)
- AGY committed a diagnostics handoff to NEXUS git: _CONTROL/Session_Logs/2026/07/Session_Handoff_2026-07-19_2130_pi_diagnostics.md
- Detailed findings: /Users/jose/.gemini/antigravity-cli/brain/614a9848-bd19-4d9e-a6ee-75fc01fa307b/findings.md
