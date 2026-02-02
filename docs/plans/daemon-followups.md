# Daemon Follow-ups

## State heuristics parity (from manual testing)

- **Esc interrupt leaves session stuck in Working**
  - **Problem:** No hook event fires on Esc, so state never transitions.
  - **Desired fix:** Daemon-side staleness heuristic using `updated_at`, `state_changed_at`, and `is_alive`.

- **Terminate session while Working → Ready instead of Idle**
  - **Problem:** Missing “stale + no liveness → Idle” behavior from the prior resolver.
  - **Desired fix:** Apply the legacy idle fallback rules in daemon snapshot logic.

## Next validation

- Re-run manual tests after heuristics are implemented.

## Shell CWD highlight lag (manual test)

- **Observed:** After changing directories in macOS Terminal, the app highlight remained stuck on the prior project ("writing"), even though daemon shell state had updated previously.
- **Suspected:** UI not refreshing shell state or shell-cwd events not being ingested on every cd.
- **Next steps:** Verify shell-cwd events are emitted on each prompt, confirm daemon state updates, and ensure Swift ShellStateStore refresh loop is active.

- **Observed:** `hud-hook cwd` sometimes fails to update daemon shell state even when env vars are set; daemon logs show no new `Received event` entries after manual `hud-hook` invocation.
  - **Hypothesis:** `hud-hook` IPC failure is being swallowed; add explicit logging/error surfaced for shell-cwd send failures and validate socket path.

## UI hitching / frequent jank (during daemon migration)

- **Observed:** UI hitches 2–3x per second in the current debug build.
- **Hypotheses:**
  - Aggressive polling (shell state every 0.5s + staleness timer every 1s) causing frequent `objectWillChange`.
  - Debug logging/telemetry overhead during each poll/resolve cycle.
  - Repeated daemon polling while app is idle, combined with heavy logging.
- **Next steps:** Measure CPU on the debug build; temporarily increase polling interval or gate `objectWillChange` to only fire on changes; confirm if hitching disappears with logging disabled.
