# Subsystem 3: Hook Configuration & Binary Management

**Files analyzed:**
- `core/hud-core/src/setup.rs`
- `scripts/sync-hooks.sh`

## Summary

Hook configuration uses a read–modify–write cycle on `~/.claude/settings.json` with atomic temp-file renames and preserves unrelated settings via `serde(flatten)`. The hook binary is installed as a symlink to avoid Gatekeeper SIGKILL issues. Overall behavior matches documentation.

## Findings

### [CONFIG] Finding 1: TOCTOU Window Can Clobber Concurrent Settings Changes

**Severity:** Low
**Type:** Race condition
**Location:** `core/hud-core/src/setup.rs:615-690`

**Problem:**
`register_hooks_in_settings` reads `settings.json`, mutates it in-memory, then writes it back. If another process modifies `settings.json` between the read and write, those changes can be lost (classic TOCTOU).

**Evidence:**
- Read: `fs::read_to_string(&settings_path)`
- Write-back: `temp_settings.persist(&settings_path)`

**Recommendation:**
If this becomes user-visible, add file locking or detect concurrent modification (e.g., compare mtime/hash before writing and retry). Otherwise, document the limitation explicitly as a low-risk edge case.

---

## Update (2026-01-29)

- No code change for the TOCTOU window; still considered low-risk and documented.
