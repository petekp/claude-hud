# Subsystem 05: Scripts + Top-level Docs

## Findings

### [DOCS] Finding 1: CLAUDE.md still documents JSON/lock fallbacks

**Severity:** Medium
**Type:** Stale docs
**Location:** `CLAUDE.md:57-67`

**Problem:**
`CLAUDE.md` still lists `sessions.json`, lock directories, and `shell-cwd.json` as fallbacks with lock-based resolution. This conflicts with the daemon-only architecture and “no back-compat” stance.

**Evidence:**
State tracking section lists JSON/lock fallbacks (`CLAUDE.md:59-67`).

**Recommendation:**
Rewrite the section to describe daemon-only flow and remove fallback/lock references.

---

### [DOCS] Finding 2: README still references stale locks and legacy files

**Severity:** Medium
**Type:** Stale docs
**Location:** `README.md:252-276`

**Problem:**
README describes stale locks as a resolver concern and enumerates legacy files under `~/.capacitor/` even though they are deprecated in daemon-only mode.

**Evidence:**
- “Crashed sessions (stale locks with dead PIDs)” (`README.md:252-255`).
- Data storage list includes `sessions.json`, `sessions/`, `shell-cwd.json`, `shell-history.jsonl` (`README.md:266-276`).

**Recommendation:**
Update README to reflect daemon-only state and remove legacy entries.

---

### [DOCS/SCRIPTS] Finding 3: reset-for-testing comments describe removed files

**Severity:** Low
**Type:** Stale docs
**Location:** `scripts/dev/reset-for-testing.sh:60-68`

**Problem:**
Comment block claims `~/.capacitor/` contains `sessions.json`, lock directories, and `file-activity.json`. These are no longer produced in daemon-only mode.

**Evidence:**
Comment lines list obsolete files (`reset-for-testing.sh:63-67`).

**Recommendation:**
Update comment to list daemon-era artifacts (daemon.sock, daemon/state.db, logs).

