# Subsystem 5: Activity File Pipeline

**Files analyzed:**
- `core/hud-hook/src/handle.rs`
- `core/hud-core/src/activity.rs`

## Summary

The hook now writes the native `activity` format (with `project_path`) and migrates any legacy `files` arrays on write. `ActivityStore` remains backward-compatible and will still convert older hook-format files when encountered.

## Findings

### [ACTIVITY] Finding 1: Dual Activity Formats Create Ongoing Conversion Overhead

**Severity:** Medium
**Type:** Design flaw
**Location:**
- `core/hud-hook/src/handle.rs:430-521`
- `core/hud-core/src/activity.rs:108-199`

**Problem (pre-fix):**
The hook wrote `files[]` entries while `ActivityStore` expected `activity[]` entries with `project_path`. Every load had to detect hook format and convert it using boundary detection, adding overhead and drift risk.

**Evidence:**
- Hook writes `session["files"]` entries with `file_path` only.
- `ActivityStore::load()` includes explicit hook-format parsing and conversion.

**Recommendation:**
Unify the format written by the hook and read by the engine. Options:
- Move boundary attribution into the hook (write native format), or
- Extract a shared conversion helper and have the hook write native format without boundary detection.

---

## Update (2026-01-29)

- The hook now writes native `activity` entries with `project_path` and migrates legacy `files` arrays on write. `ActivityStore::load()` remains backward-compatible for older files.
