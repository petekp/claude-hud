# Daemon Legacy/Dead Code Audit Summary (2026-02-02)

## Findings by severity
- **Critical:** 0
- **High:** 0
- **Medium:** 8
- **Low:** 7

## Top 5 issues (recommended fix order)
1. **Remove legacy lock-holder cleanup + unused cleanup stats** (hud-core) — daemon-only mode should not run legacy process cleanup or export stale counters.
2. **Remove or rewire ShellHistoryStore** (Swift) — `shell-history.jsonl` has no writer; feature is dead.
3. **Drop `shell-cwd.json` setup checks** (Swift) — setup UI still treats deprecated file as a signal.
4. **Delete or rewrite legacy tests** — lock-based resolver integration tests + tombstone bats tests no longer match daemon architecture.
5. **Update primary docs (CLAUDE.md + README)** — still describe fallback files and lock-based resolution.

## Recommended action order
1. Purge legacy cleanup + legacy stats in hud-core (and update Swift logging).
2. Remove/rework ShellHistoryStore; decide whether to back it with daemon event history.
3. Update setup UI to rely on daemon shell state / snippet detection only.
4. Remove or rewrite obsolete tests to daemon IPC.
5. Update top-level docs and dev scripts to reflect daemon-only storage.

## Notes
- No critical or high severity issues found.
- Remaining low-severity items are stale comments and unused helpers; address opportunistically during cleanup.

