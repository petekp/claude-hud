# Debug Tools and Commands

Use these tools early and often. Favor the smallest command that answers the question.

## Repo Scripts

- `scripts/state-snapshot.sh <project-path>` — durable snapshot: sessions, locks, transcripts, hook events.
- `scripts/test-hook-events.sh` — hook integration tests for `hud-state-tracker.sh`.
- `scripts/hud-state-tracker.sh` — hook writer; use for manual event injection when reproducing edge cases.
- `scripts/run-tests.sh` — broader test harness when changes affect multiple subsystems.

## Rust Debug Binary

- `cargo run --bin state_check -- <project-path>` — validates lock liveness and state resolution.
  - Uses `~/.claude/sessions` locks and `~/.capacitor/sessions.json`.

## Quick Command Patterns

```bash
# Snapshot for a specific project
scripts/state-snapshot.sh /path/to/project

# Tail recent hook events for a project path
tail -n 200 ~/.capacitor/hud-hook-events.jsonl | rg '/path/to/project'

# Inspect the state store
jq '.sessions | to_entries[] | {id: .key, state: .value.state, updated_at: .value.updated_at, cwd: .value.cwd}' \
  ~/.capacitor/sessions.json

# Check locks
for lock in ~/.claude/sessions/*.lock; do
  [ -f "$lock/meta.json" ] && cat "$lock/meta.json"
done | jq -s .
```

## Hook Installation Sanity Checks

- Verify hook script is executable and matches the repo version:
  - `ls -l ~/.claude/scripts/hud-state-tracker.sh`
  - Compare version header or diff against `scripts/hud-state-tracker.sh`.

## Claude Code CLI Debugging

- Use `claude --debug` and `/doctor` when CLI behavior or hook execution is suspect.
- Use `/hooks` to verify hook registration and matcher configuration.
