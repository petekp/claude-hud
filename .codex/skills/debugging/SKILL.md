---
name: debugging
description: Debugging and incident triage for Claude HUD. Use when investigating state detection, hook behavior, lock or PID liveness, session/UI mismatches, log analysis, or when the user says "let's debug", "investigate", "why is it stuck", "ready while busy", "hooks not firing", or similar.
---

# Debugging

## Overview

Debug Claude HUD by collecting durable artifacts, analyzing hook/state/lock signals, and cross-checking docs and code paths before proposing fixes.

## Debugging Workflow

1. Scope the symptom
   - Ask for project path, observed state vs expected state, time window, and whether the issue is in CLI, HUD UI, or both.
   - Capture the exact phrase or notification type when the state changed (if known).

2. Capture durable artifacts early
   - Run `scripts/state-snapshot.sh <project-path>` and keep the output path.
   - Pull focused slices of `~/.capacitor/hud-hook-events.jsonl`, `~/.capacitor/sessions.json`, and `~/.claude/sessions/*.lock`.
   - Prefer `jq`, `rg`, `tail`, and `stat` to avoid dumping full logs.

3. Use the core debug tools
   - Run `scripts/test-hook-events.sh` when hook logic is in question.
   - Run `cargo run --bin state_check -- <project-path>` to validate lock and resolver behavior.
   - Compare repo hook script vs installed hook script (executable + version header).
   - See `references/tools.md` for the full tool list and usage patterns.

4. Cross-check authoritative docs
   - Start with `.claude/docs/state-detection-map.md` and `.claude/docs/hook-operations.md`.
   - Use `docs/claude-code/hooks.md` for the official hook payload schema.
   - See `references/docs-index.md` for a full doc map and drift notes.

5. Trace code paths
   - State pipeline: `scripts/hud-state-tracker.sh`, `core/hud-core/src/state/*.rs`, `core/hud-core/src/sessions.rs`.
   - Adapter/UI: `core/hud-core/src/agents/claude.rs`, `apps/swift/Sources/ClaudeHUD/Models/SessionStateManager.swift`.
   - Cross-check with snapshots and the hook event log for exact transitions.

6. Report findings and next steps
   - Provide a concrete timeline, evidence, root cause, and a targeted fix.
   - Include verification steps (tests, commands, or repro procedure).

## Data Handling

- Avoid printing or storing prompt bodies, tool_input/tool_response, or full transcript contents.
- Treat `~/.claude/projects/*.jsonl` as sensitive; extract only metadata needed for diagnosis.
- Prefer sanitized HUD logs and snapshots whenever possible.

## References

- `references/logs-and-artifacts.md` for log locations and artifact paths.
- `references/docs-index.md` for relevant internal and Claude Code docs.
- `references/tools.md` for repo scripts and debug commands.
