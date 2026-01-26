# Parallel Workstreams

**Date:** 2026-01-25
**Status:** Brainstorm complete, ready for planning

## What We're Building

A way to work on multiple things at once in the same project without mental overhead. Capacitor becomes the control center for spawning and managing parallel workstreams—each backed by a git worktree for real file isolation.

### Core User Flow

1. **Create:** Click a single button in Capacitor → worktree created with auto-generated name
2. **Work:** Claude session runs in the worktree, Capacitor tracks its state like any project
3. **Finish:** Commit and push from that workstream, create PR if desired
4. **Cleanup:** Explicit destroy button removes the worktree when done

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Isolation mechanism | Git worktrees | Real file isolation, git just works, no conflicts |
| Naming | Auto-generate (workstream-1, etc.) | Zero friction; rename later if you care |
| UI surface | Dedicated workstreams view | Focused panel, not cluttering the main project cards |
| Lifecycle end | Manual cleanup only | No magic deletion; explicit user control |
| Worktree location | `~/.capacitor/workstreams/{project}/{name}/` | Predictable, outside the main repo |

## Why This Approach

**Problem:** When juggling exploration and implementation in the same project, it's visually confusing which terminal is doing what. Starting a parallel workstream takes mental effort.

**Solution:** One-click worktree creation. Each workstream is physically isolated, appears as its own tracked entity in Capacitor, and has an explicit lifecycle (create → work → destroy).

**Why worktrees over alternatives:**
- **vs. Same directory + session tags:** No file isolation means edits can conflict. Can't create clean PRs from one workstream.
- **vs. Temporary clones:** More disk space, separate git history complications.
- **vs. Hybrid approach:** Adds a "should I tag or isolate?" decision. Violates the "brainless" goal.

## The Experience

### Creation (one click)
```
[+ New Workstream] → Creates worktree → Opens terminal in that directory
```

Capacitor:
1. Runs `git worktree add ~/.capacitor/workstreams/capacitor/workstream-1 -b workstream-1`
2. Registers the workstream internally
3. Opens a new terminal (iTerm tab? integrated?) at that path
4. Workstream immediately appears in the dedicated view with "Idle" state

### Working

Each workstream shows in the dedicated panel:
- Name (workstream-1, or custom if renamed)
- Session state (Working/Ready/Idle)
- Branch name
- Quick actions: Open terminal, Destroy

When Claude runs in a worktree, Capacitor's existing path-based tracking just works—the worktree has its own path, so it appears as its own entity.

### Cleanup

Destroy button:
1. Confirms if session is active ("Claude is running here. Destroy anyway?")
2. Runs `git worktree remove ~/.capacitor/workstreams/capacitor/workstream-1`
3. Optionally deletes the branch (`git branch -D workstream-1`)
4. Removes from Capacitor's workstream registry

## Open Questions

1. **Terminal integration:** How to open a terminal in the worktree? iTerm AppleScript? Open in Cursor? VSCode? Need to pick a default and possibly allow customization.

2. **Main branch base:** When creating a worktree, should it branch from `main`, current branch, or ask? (YAGNI says: always branch from main, simplest mental model.)

3. **Visibility of worktrees in main dock:** Should worktrees for the "active" project appear subtly in the dock, or only in the dedicated view?

4. **Rename flow:** If someone wants to rename "workstream-1" to "exploration", does that also rename the branch? (Probably not—branch name is git's concern, display name is Capacitor's.)

5. **What if worktree already exists?** Just open it instead of creating a new one.

## Scope Boundaries

### In Scope
- Create worktree with one click
- Track worktree session state (reuses existing path-based tracking)
- Dedicated workstreams view for the active project
- Destroy worktree with explicit action
- Auto-generated naming with optional rename

### Out of Scope (for now)
- PR creation from Capacitor
- Merge flow automation
- Worktree templates ("exploration" vs "bugfix" presets)
- Multiple projects' worktrees in one view
- Syncing worktrees across machines

## Next Steps

Run `/workflows:plan` to design implementation phases.
