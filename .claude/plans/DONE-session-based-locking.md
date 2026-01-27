# Session-Based Lock Architecture

**Status:** DONE
**Created:** 2026-01-26
**Issue:** Projects showing "Ready" after session ends; concurrent sessions not properly tracked

## Problem Summary

Two related bugs stem from the current path-based lock design:

1. **Lingering "Ready" State** — After killing a Claude session, the project remains "Ready" indefinitely because old session records for the same path linger in `sessions.json`, and the resolver's `find_stale_ready_record_for_path()` fallback picks them up.

2. **Concurrent Session Blindness** — When two Claude sessions run in the same directory, only one can "own" the lock (the most recent one). When that session ends, the other running session becomes invisible—the project shows "Idle" despite an active Claude session.

## Root Cause

Locks are keyed by **path hash** (`MD5(path).lock/`), creating a 1:1 relationship between paths and locks. This design cannot represent multiple concurrent sessions in the same directory.

## Solution: Session-Based Lock Keying

Change locks to be keyed by **session ID** instead of path hash:

```
Current:  ~/.capacitor/sessions/{MD5(path)}.lock/
Proposed: ~/.capacitor/sessions/{session_id}.lock/
```

This enables:
- Multiple locks per path (one per concurrent session)
- Clean lock release on SessionEnd (no stale record fallback needed)
- Accurate state for concurrent sessions

## Implementation Plan

### Phase 1: Lock System Changes (`core/hud-core/src/state/lock.rs`)

**1.1 Update lock naming scheme**

Change `create_lock()` to use session_id:

```rust
// Before
let dir_name = format!("{:x}.lock", hash);

// After
let dir_name = format!("{}.lock", session_id);
```

**1.2 Store path in lock metadata**

Add `path` field to `meta.json`:

```rust
pub struct LockMeta {
    pub created: u64,
    pub path: PathBuf,  // NEW: store the project path
    pub pid: u32,
    pub proc_started: u64,
    pub handoff_from: Option<u32>,
}
```

**1.3 Add `release_lock_by_session()`**

New function for clean session cleanup:

```rust
pub fn release_lock_by_session(session_id: &str) -> Result<bool> {
    let lock_dir = sessions_dir()?.join(format!("{}.lock", session_id));
    if lock_dir.exists() {
        std::fs::remove_dir_all(&lock_dir)?;
        Ok(true)
    } else {
        Ok(false)
    }
}
```

**1.4 Add `find_all_locks_for_path()`**

New function for concurrent session support:

```rust
pub fn find_all_locks_for_path(path: &Path) -> Result<Vec<LockInfo>> {
    let sessions_dir = sessions_dir()?;
    let mut locks = Vec::new();

    for entry in std::fs::read_dir(&sessions_dir)? {
        let entry = entry?;
        if entry.path().extension().map_or(false, |e| e == "lock") {
            if let Ok(meta) = read_lock_meta(&entry.path()) {
                if meta.path == path && is_pid_running(meta.pid) {
                    locks.push(LockInfo { session_id, meta });
                }
            }
        }
    }
    Ok(locks)
}
```

**1.5 Update `find_matching_child_lock()`**

Scan all locks and match by path relationship instead of hash lookup.

### Phase 2: Hook Handler Changes (`core/hud-hook/src/handle.rs`)

**2.1 Pass session_id to spawn_lock_holder**

```rust
// Before
spawn_lock_holder(&event.cwd);

// After
spawn_lock_holder(&event.cwd, &event.session_id);
```

**2.2 Call release_lock_by_session on SessionEnd**

In the `Action::Delete` handling:

```rust
"SessionEnd" => {
    release_lock_by_session(&event.session_id)?;
    // ... existing session record deletion
}
```

### Phase 3: Lock Holder Changes (`core/hud-hook/src/lock_holder.rs`)

**3.1 Accept session_id argument**

```rust
// Before
pub fn run_lock_holder(project_path: &Path) -> Result<()>

// After
pub fn run_lock_holder(project_path: &Path, session_id: &str) -> Result<()>
```

**3.2 Use session-based lock release**

```rust
// Before
release_lock(&project_path)?;

// After
release_lock_by_session(session_id)?;
```

### Phase 4: Resolver Changes (`core/hud-core/src/state/resolver.rs`)

**4.1 Remove stale Ready fallback**

Delete `find_stale_ready_record_for_path()` and its call in `resolve_state_with_details()`.

The fallback chain becomes:
1. Active lock with live PID → Ready
2. Fresh session record (< 5 min) → use its state
3. Otherwise → Idle

**4.2 Update lock-based resolution**

Use `find_all_locks_for_path()` to check for ANY active session:

```rust
let active_locks = find_all_locks_for_path(path)?;
if !active_locks.is_empty() {
    return Ok(StateInfo::from_lock(&active_locks[0]));
}
```

### Phase 5: Cleanup Changes (`core/hud-core/src/state/cleanup.rs`)

**5.1 Add orphaned session cleanup**

New function to remove session records that have no corresponding lock and are older than the fresh threshold:

```rust
pub fn cleanup_orphaned_sessions(store: &SessionStore) -> Result<usize> {
    let active_session_ids: HashSet<String> = get_all_lock_session_ids()?;
    let mut removed = 0;

    for (session_id, record) in store.all_sessions() {
        if !active_session_ids.contains(session_id)
           && record.is_stale()
           && record.state == "ready" {
            store.delete_session(session_id)?;
            removed += 1;
        }
    }
    Ok(removed)
}
```

**5.2 Update startup cleanup**

Add orphaned session cleanup to `run_startup_cleanup()`.

## Testing Plan

1. **Single session lifecycle**: Start → Ready, End → Idle
2. **Concurrent sessions same path**: Both show Ready, kill one → other stays Ready
3. **Session restart (`/continue`)**: Quick restart doesn't leave orphaned state
4. **Stale record cleanup**: Old Ready records don't resurrect dead sessions
5. **Lock holder crash recovery**: Orphaned locks cleaned on startup

## Migration

No migration needed. On first run after upgrade:
- Startup cleanup removes old path-based locks (dead PIDs)
- New sessions create session-based locks
- Old session records cleaned by orphaned session cleanup

## Files Modified

| File | Changes |
|------|---------|
| `core/hud-core/src/state/lock.rs` | Session-based naming, path in meta, new query functions |
| `core/hud-core/src/state/types.rs` | Add `path` to `LockMeta` |
| `core/hud-hook/src/handle.rs` | Pass session_id, call release on end |
| `core/hud-hook/src/lock_holder.rs` | Accept session_id, use session-based release |
| `core/hud-core/src/state/resolver.rs` | Remove stale fallback, use multi-lock query |
| `core/hud-core/src/state/cleanup.rs` | Add orphaned session cleanup |
