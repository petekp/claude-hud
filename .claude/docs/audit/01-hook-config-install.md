# Subsystem Audit: Hook Config + Install

**Files reviewed**
- `core/hud-core/src/setup.rs`

**Purpose**
Manages hook binary verification and installs/updates Claude Code hook registrations in `~/.claude/settings.json`.

**Notes**
- Atomic writes used for settings updates (temp + rename).
- Policy flags (`disableAllHooks`, `allowManagedHooksOnly`) block installation as expected.
- Tests cover registration behavior, matcher handling, and corrupt JSON preservation.

**Findings**
No issues found in this subsystem.

