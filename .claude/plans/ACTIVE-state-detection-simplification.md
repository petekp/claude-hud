# State Detection Simplification Plan

> **⚠️ Status Update (2026-01):** Phase 1 (move locks to `~/.capacitor/`) is COMPLETE. The "Current State" section below describes the OLD architecture for historical context. See `CLAUDE.md` for actual current paths.

## Goal

Simplify Claude HUD's state detection while maintaining the adapter abstraction for multi-agent support. The adapter interface stays unchanged—we're simplifying ClaudeAdapter's internals.

## Guiding Principles

1. **Sidecar purity:** Read from agent namespaces, write only to `~/.capacitor/`
2. **Adapter abstraction:** Each agent encapsulates its own detection strategy
3. **Graceful degradation:** Rich signals → fine-grained state; minimal signals → coarse state
4. **Single responsibility:** Hooks write state, Rust reads state

## Current State

```
Hooks write to:
├── ~/.capacitor/sessions.json     ✓ Our namespace
└── ~/.claude/sessions/*.lock/     ✗ Claude's namespace (violation!)

Rust reads from:
├── ~/.capacitor/sessions.json     (state records)
├── ~/.claude/sessions/*.lock/     (liveness via PID)
└── Cross-references both          (complex resolution logic)
```

**Problems:**
- Lock directories pollute Claude's namespace
- Two-layer resolution adds complexity
- Fresh record fallback is a workaround for race conditions we created

## Target State

```
Hooks write to:
└── ~/.capacitor/
    └── sessions/
        └── {session_id}/
            ├── lock          (empty file, existence = alive)
            ├── state.json    (current state)
            └── meta.json     (path, timestamps)

Rust reads from:
└── ~/.capacitor/sessions/*/
    (one directory per session, lock + state co-located)
```

**Benefits:**
- Pure sidecar: `~/.claude/` is read-only
- Unified location: lock and state in same directory
- Simpler resolution: directory exists + lock held = session active

## Phases

### Phase 1: Move Locks to Our Namespace

**Goal:** Stop writing to `~/.claude/sessions/`

**Changes:**

Hook script (`hud-state-tracker.sh`):
```bash
# Before
LOCK_DIR="$HOME/.claude/sessions"

# After
LOCK_DIR="$HOME/.capacitor/sessions"
```

Rust (`state/lock.rs`):
```rust
// Before
fn get_sessions_dir() -> PathBuf {
    dirs::home_dir().unwrap().join(".claude/sessions")
}

// After
fn get_sessions_dir() -> PathBuf {
    dirs::home_dir().unwrap().join(".capacitor/sessions")
}
```

**Migration:**
- Clean up existing locks in `~/.claude/sessions/`
- New sessions use `~/.capacitor/sessions/`

**Tests:** All 256 Rust tests + 18 hook tests must pass

---

### Phase 2: Co-locate State with Locks

**Goal:** Eliminate separate `sessions.json`, write state per-session

**New directory structure:**
```
~/.capacitor/sessions/{session_id}/
├── lock              # Empty file held by background process (flock)
├── state.json        # { state, cwd, project_dir, updated_at, ... }
└── meta.json         # { created_at, session_id }
```

**Hook changes:**
```bash
# Before: update central sessions.json with jq
update_state() {
    jq --arg state "$STATE" '.sessions[$SID].state = $state' \
        ~/.capacitor/sessions.json > tmp && mv tmp ~/.capacitor/sessions.json
}

# After: write to session directory
update_state() {
    local session_dir="$HOME/.capacitor/sessions/$SESSION_ID"
    cat > "$session_dir/state.json" <<EOF
{
    "state": "$STATE",
    "cwd": "$CWD",
    "updated_at": "$TIMESTAMP"
}
EOF
}
```

**Rust changes:**
- Delete `state/store.rs` (no central state file)
- Simplify `state/resolver.rs`:
  ```rust
  pub fn resolve(project: &Path) -> Option<SessionState> {
      let sessions = scan_session_dirs()?;
      let matching = sessions.iter()
          .filter(|s| is_lock_held(&s.path))
          .find(|s| path_matches(project, &s.project_path))?;

      read_state(&matching.path.join("state.json"))
  }
  ```

**Estimated deletions:** ~300 lines (store.rs, complex resolution logic)

---

### Phase 3: Simplify Lock Mechanism

**Goal:** Replace `spawn_lock_holder` with file locking

**Current approach:**
```bash
spawn_lock_holder() {
    # Fork a background process that does `sleep infinity`
    # Write its PID to lock directory
    # Rust checks if PID is alive
}
```

**New approach:**
```bash
acquire_lock() {
    local lock_file="$HOME/.capacitor/sessions/$SESSION_ID/lock"
    exec 9>"$lock_file"
    flock -n 9 || return 1  # Non-blocking lock
    # Lock held for lifetime of this shell
}
```

**Benefits:**
- No orphan processes to clean up
- OS handles lock release on process death
- No PID verification needed in Rust

**Rust side:**
```rust
fn is_session_alive(session_dir: &Path) -> bool {
    let lock_file = session_dir.join("lock");
    // Try to acquire exclusive lock
    // If we can't, someone else has it → session alive
    match File::open(&lock_file) {
        Ok(f) => f.try_lock_exclusive().is_err(), // Locked = alive
        Err(_) => false,
    }
}
```

---

### Phase 4: Rust Binary for State Updates (Optional)

**Goal:** Unify bash and Rust into single codebase

**New binary:** `hud-state`
```rust
fn main() {
    match args.command {
        Command::Update { session_id, state, cwd, event } => {
            let dir = get_session_dir(&session_id);
            write_state(&dir, state, cwd, event)?;
        }
        Command::Query { project } => {
            let state = resolve(project)?;
            println!("{}", serde_json::to_string(&state)?);
        }
        Command::Cleanup => {
            cleanup_stale_sessions()?;
        }
    }
}
```

**Hook becomes thin wrapper:**
```bash
#!/bin/bash
~/.capacitor/bin/hud-state update \
    --session-id "$SESSION_ID" \
    --state "$STATE" \
    --cwd "$CWD" \
    --event "$EVENT"
```

**Benefits:**
- Single type definitions (no drift between bash JSON and Rust structs)
- Testable state updates
- Same binary for read and write

---

## File Changes Summary

| File | Phase | Change |
|------|-------|--------|
| `scripts/hud-state-tracker.sh` | 1, 2, 3 | Update paths, simplify state writes, use flock |
| `core/hud-core/src/state/lock.rs` | 1, 3 | Update paths, simplify to flock check |
| `core/hud-core/src/state/store.rs` | 2 | Delete (no central state file) |
| `core/hud-core/src/state/resolver.rs` | 2 | Simplify to ~30 lines |
| `core/hud-core/src/state/types.rs` | 2 | Simplify (remove unused fields) |
| `core/hud-core/src/bin/hud-state.rs` | 4 | New binary (optional) |

## Rollout

1. **Phase 1 first** — minimal risk, just path changes
2. **Phase 2 after Phase 1 stable** — bigger refactor, more testing
3. **Phase 3 after Phase 2 stable** — changes lock semantics
4. **Phase 4 optional** — nice-to-have, not required

## Success Criteria

- [ ] All locks in `~/.capacitor/`, none in `~/.claude/`
- [ ] No `sessions.json` file (state per-session)
- [ ] Resolver under 50 lines
- [ ] All 256 Rust tests pass
- [ ] All 18 hook tests pass
- [ ] Swift app works correctly

## Multi-Agent Implications

This simplification is internal to ClaudeAdapter. The adapter interface remains:

```rust
pub trait AgentAdapter {
    fn detect_session(&self, project_path: &str) -> Option<AgentSession>;
    fn all_sessions(&self) -> Vec<AgentSession>;
    // ...
}
```

Other adapters (Codex, Aider, etc.) will use their own detection strategies—reading their native files, checking process lists, etc. They won't share Claude's state infrastructure.
