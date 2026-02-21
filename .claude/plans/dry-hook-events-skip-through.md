# DRY Hook Events: Skip-Through Category

## Problem

Adding a new "skip" hook event (like WorktreeCreate, ConfigChange) requires touching **7 match arms across 5 files**. Most of these are identical boilerplate: `=> Skip`.

## Approach: Default Catch-All in Reducers + Handlers

Instead of listing every skip event explicitly, use a catch-all `_` arm in the match sites that currently enumerate skip variants. The exhaustive matches that **do** need explicit arms for every variant (like the `event_type_for_hook` mapping) stay exhaustive — the compiler will still force us to add new variants there.

### What changes

**1. `daemon-protocol/src/lib.rs` — EventType validation match**

The validation match currently lists every variant explicitly. Add a catch-all for the "just needs session fields" group:

```rust
// Before (explicit listing):
EventType::SubagentStart
| EventType::SubagentStop
| EventType::TeammateIdle
| EventType::WorktreeCreate
| EventType::WorktreeRemove
| EventType::ConfigChange
| EventType::PreCompact => {
    require_session_fields(self)?;
}

// After (catch-all):
// Variants with custom validation are matched above.
// Everything else requires standard session fields.
_ => {
    require_session_fields(self)?;
}
```

This works because `ShellCwd`, `Notification`, `Stop`, `SessionEnd` all have their own explicit arms above the catch-all. Any new variant that needs session fields (the common case) falls through automatically.

**2. `daemon/src/reducer.rs` — `reduce_session()` match**

```rust
// Before:
EventType::SubagentStart
| EventType::SubagentStop
| EventType::TeammateIdle
| EventType::WorktreeCreate
| EventType::WorktreeRemove
| EventType::ConfigChange => SessionUpdate::Skip,
...
EventType::ShellCwd => SessionUpdate::Skip,

// After: remove the explicit skip arm, add catch-all at the end
_ => SessionUpdate::Skip,
```

This is safe because every state-changing variant (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, etc.) is matched explicitly above. New skip-only variants fall through.

**3. `hud-hook/src/handle.rs` — `process_event()` match**

```rust
// Before:
HookEvent::SubagentStart | HookEvent::SubagentStop => (Action::Skip, None, None),
HookEvent::TeammateIdle
| HookEvent::WorktreeCreate
| HookEvent::WorktreeRemove
| HookEvent::ConfigChange => (Action::Skip, None, None),

// After: single catch-all replacing both skip arms
_ => (Action::Skip, None, None),
```

Same principle — state-changing events are already matched above.

**4. `daemon/src/reducer.rs` — `adjust_tools_in_flight()` match**

Already uses `_ => current`. No change needed.

**5. `daemon/src/state.rs` — `should_evaluate_hem_shadow_for_event()`**

Uses `matches!()` with explicit positive list. No change needed (new events correctly return `false`).

### What stays exhaustive (compiler catches new variants)

These three sites remain exhaustive. When you add a new `HookEvent` or `EventType` variant, the compiler will force you to add it here:

| File | Function | Why |
|------|----------|-----|
| `hud-hook/src/daemon_client.rs` | `event_type_for_hook()` | Maps `HookEvent` → `EventType` 1:1. Must be exhaustive so we don't accidentally return `None` for a recognized event. |
| `hud-core/src/state/types.rs` | `to_event()` | String → `HookEvent` parser. Has `_` catch-all for `Unknown`, but new variants need explicit string entries. |
| `hud-core/src/setup.rs` | `HUD_HOOK_EVENTS` const | Registers hooks with Claude Code. New events must be added here to be received. |

### What adding a new skip event looks like after this change

| # | File | Change |
|---|------|--------|
| 1 | `hud-core/src/state/types.rs` | Add variant to `HookEvent` enum |
| 2 | `hud-core/src/state/types.rs` | Add string match in `to_event()` |
| 3 | `daemon-protocol/src/lib.rs` | Add variant to `EventType` enum |
| 4 | `hud-hook/src/daemon_client.rs` | Add mapping in `event_type_for_hook()` |
| 5 | `hud-core/src/setup.rs` | Add entry to `HUD_HOOK_EVENTS` |

That's **5 one-line additions** and **0 match arms to update** in handlers/reducers. Down from 7 touch points.

### Safety

- All state-changing variants remain explicitly matched above the catch-all.
- `clippy::match_wildcard_for_single_variants` won't fire because multiple variants fall through.
- The compiler still enforces exhaustiveness at the critical mapping sites.
- `deny_unknown_fields` on `EventEnvelope` serde means truly unknown events still fail at deserialization — the catch-all only covers recognized `EventType` variants.

### Not doing

- **Shared event name registry / macro**: Over-engineering for the current codebase size. The compiler already catches most misses.
- **Category enum on EventType**: Would require a method like `event_type.category()` which is just another match to maintain.
- **Adding the 3 new events to `HUD_HOOK_EVENTS`**: That's a separate concern (registering hooks with Claude Code). Leaving for a follow-up since those events work fine as `Unknown` passthrough today.
