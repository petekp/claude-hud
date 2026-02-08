# Onboarding — Slices

## Slice Summary

| # | Slice | Mechanism (Parts) | Demo |
|---|-------|-------------------|------|
| V1 | Setup card only on real failures | A4 | “After first run with idle hooks, no setup card appears.” |
| V2 | Simplified WelcomeView flow | A1, A2 | “Onboarding is 1–2 steps with clear action and errors.” |
| V3 | Post-setup project detection | A3 | “After setup, app suggests existing projects to add.” |
| V4 | Shell instructions reliability pass | A2 | “Copy/auto-install works for zsh/bash/fish with clear messaging.” |

---

## V1: Setup card only on real failures

**Status:** ✅ COMPLETE

**Changes**
- `HookDiagnosticReport.shouldShowSetupCard` no longer shows on first-run idle/not-firing.

**Demo**
- First run with hooks installed but no heartbeat: no setup card in project list.

---

## V2: Simplified WelcomeView flow

**Status:** ✅ COMPLETE

**Changes**
- Collapse checklist into a compact flow: primary hook install + optional shell step.
- Consolidate error messaging with direct actions (Install, Retry, Open instructions).
- Add transparency copy about hook/daemon modifications + metadata capture.

**Demo**
- Onboarding feels like 1–2 steps; user can finish in under a minute.

---

## V3: Post-setup project detection

**Status:** ✅ COMPLETE

**Changes**
- Use `HudEngine.getSuggestedProjects()` (from `~/.claude/projects`) to surface likely projects.
- Present add/dismiss actions in the empty state after setup completes.

**Demo**
- App offers to add detected projects immediately after setup.

---

## V4: Shell instructions reliability pass

**Status:** ✅ COMPLETE

**Changes**
- Verify copy-to-clipboard for zsh/bash/fish; improve failure messaging.
- Confirm auto-install handles missing config directories gracefully.
- Treat "already installed" as success; add snippet tests for zsh/bash/fish.

**Demo**
- Copy/install flows are predictable and reliable for each shell.
