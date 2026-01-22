# State Detection Module

Determines whether Claude Code is running and what it's doing for a given project.

**For detailed documentation, see the inline comments in each module file.** The Rust doc comments are the authoritative source and stay in sync with the code.

## Quick Reference

| File | Purpose |
|------|---------|
| [`mod.rs`](mod.rs) | Module overview, architecture diagram |
| [`resolver.rs`](resolver.rs) | Resolution algorithm, two-layer detection |
| [`store.rs`](store.rs) | State file format, path matching rules |
| [`lock.rs`](lock.rs) | Lock structure, PID verification |
| [`types.rs`](types.rs) | Data structures, state machine reference |

## Key Concepts

- **Sidecar pattern**: Hook script writes, Rust reads
- **Two-layer detection**: Locks (primary) + fresh records (fallback)
- **30-second TTL**: Trust records without locks if updated recently

## Debugging

```bash
# Watch hook events
tail -f ~/.claude/hud-hook-debug.log

# View session states
cat ~/.capacitor/sessions.json | jq .

# Check locks
ls ~/.claude/sessions/*.lock/
```

Run `cargo doc -p hud-core --open` to browse the full API documentation.
