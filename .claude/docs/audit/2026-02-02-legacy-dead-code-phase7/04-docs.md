# Subsystem 4: Docs / ADRs

### [Docs] Finding 1: ADR-002 still describes lock-file matching as current

**Severity:** Medium
**Type:** Stale docs
**Location:** `docs/architecture-decisions/002-state-resolver-matching-logic.md:7-183`

**Problem:**
ADR-002 describes lock-file based resolver logic as current (“HUD resolver matches session state records with lock files”). With daemon-only architecture and lock-holder removal, this ADR now documents behavior that no longer exists.

**Recommendation:**
Mark ADR-002 as superseded by the daemon ADR (ADR-005) or add a top note: “Historical; lock-based resolver removed in daemon migration.”

---

### [Docs] Finding 2: Migration/legacy docs still read as active guidance

**Severity:** Medium
**Type:** Stale docs
**Location:**
- `docs/architecture-decisions/004-simplify-state-storage.md:17-70` (already superseded but still reads like current baseline)
- `docs/plans/daemon-lock-deprecation-plan.md`
- `AGENT_CHANGELOG.md` entries referencing lock-holder as active signal

**Problem:**
Several docs still describe lock files, lock holders, and file-based state as active systems. Even when superseded, the lack of explicit “historical only” banners makes it easy to misinterpret during future work.

**Recommendation:**
Add clear superseded/historical banners at the top of these docs, and cross-link to the daemon architecture plan as the source of truth. If the lock deprecation plan is complete, move it to an “archived” section or add a DONE header.
