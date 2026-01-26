# Parallel Workstreams

**Date:** 2026-01-25
**Status:** Brainstorm complete, ready for planning

## What We're Building

A way to work on multiple things at once in the same project without mental overhead. Capacitor becomes the control center for spawning and managing parallel workstreams—each backed by a git worktree for real file isolation.

**Identity model:** The parent project remains the "project" (active project resolution, stats, descriptions, ideas). Workstreams are **child entities**—they have state, branch, and actions, but they don't appear as top-level projects and don't get their own pinned descriptions or stats.

### Core User Flow

1. **Create:** Click a single button in Capacitor → worktree created with auto-generated name
2. **Work:** Claude session runs in the worktree, Capacitor tracks its state like any project
3. **Finish:** Commit and push from that workstream, create PR if desired
4. **Cleanup:** Explicit destroy button removes the worktree when done

### Key Design Decisions

| Decision            | Choice                                | Rationale                                              |
| ------------------- | ------------------------------------- | ------------------------------------------------------ |
| Isolation mechanism | Git worktrees                         | Real file isolation, git just works, no conflicts      |
| Naming              | Auto-generate (workstream-1, etc.)    | Zero friction; rename later if you care                |
| UI surface          | Dedicated workstreams view            | Focused panel, not cluttering the main project cards   |
| Lifecycle end       | Manual cleanup only                   | No magic deletion; explicit user control               |
| Worktree location   | `{repo}/.capacitor/worktrees/{name}/` | Prefix matching works; easy to exclude from git status |

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

1. Ensures `.capacitor/worktrees/` exists and is excluded from git status
   - Default: write ignore rule to `.git/info/exclude` (local-only; avoids modifying a tracked `.gitignore`)
2. Runs `git worktree add .capacitor/worktrees/workstream-1 -b workstream-1`
3. Opens a new terminal at that path (uses existing `TerminalLauncher`)
4. Workstream immediately appears in the dedicated view with "Idle" state

### Working

Each workstream shows in the dedicated panel:

- Name (workstream-1, or custom if renamed)
- Session state (Working/Ready/Idle)
- Branch name
- Quick actions: Open terminal, Destroy

When Claude runs in a worktree at `.capacitor/worktrees/workstream-1/`, `ActiveProjectResolver`'s prefix matching automatically associates it with the parent project. No mapping layer needed.

Important nuance:

- Capacitor should treat the **parent project** as the active project (prefix match does that for free).
- The Workstreams view can still show **which workstream is active** by checking which worktree directory contains the active shell CWD / Claude session path.

### Cleanup

Destroy button:

1. Shows dirty/ahead indicator if worktree has uncommitted or unpushed changes
2. Confirms if session is active ("Claude is running here. Destroy anyway?")
3. Runs `git worktree remove .capacitor/worktrees/workstream-1` (fails if dirty unless forced)
4. Optionally deletes the branch (`git branch -D workstream-1`)

## Critical Architecture Decision (Added 2026-01-25)

**The brainstorm's claim that "existing path-based tracking just works" is FALSE.**

`ActiveProjectResolver.projectContaining(path:)` uses prefix matching:

```swift
if path == project.path || path.hasPrefix(project.path + "/") { return project }
```

A worktree at `~/.capacitor/workstreams/capacitor/workstream-1/` will **never** match `/Users/.../capacitor` because there's no prefix relationship.

### Decision: Worktrees Under Repo (`.capacitor/worktrees/`)

**Chosen approach:** Place worktrees at `{repo}/.capacitor/worktrees/{name}/`

| Benefit               | Why It Matters                                                                  |
| --------------------- | ------------------------------------------------------------------------------- |
| Prefix matching works | `ActiveProjectResolver` needs zero changes                                      |
| Self-contained        | Easy to exclude locally (prefer `.git/info/exclude`), doesn't pollute main tree |
| Discoverable          | Users exploring `.capacitor/` find it naturally                                 |
| Simple cleanup        | `rm -rf .capacitor/worktrees/` removes everything                               |

This trades theoretical "sidecar purity" for implementation simplicity. The sidecar philosophy is about not _replacing_ Claude Code—writing to `.capacitor/` in the repo is fine.

## Source of Truth: Discovering Workstreams

Avoid a separate "workstream registry" file if possible.

**Proposed source of truth:** `git worktree list --porcelain` (run in the repo root), filtered to entries whose `worktree` path is under `{repo}/.capacitor/worktrees/`.

**Workstream name:** The basename of the worktree path (e.g., `workstream-1` from `.capacitor/worktrees/workstream-1/`). If the user renames in Capacitor, that's display-only—store in a lightweight `~/.capacitor/workstream-names.json` mapping path → display name.

Benefits:

- No drift between Capacitor UI and git's real worktree state
- Easy recovery paths (`git worktree prune`, `git worktree repair`) if metadata gets stale

**Git edge cases to handle:**

| Scenario                                    | Detection                                      | Resolution                                                                 |
| ------------------------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------- |
| Directory already exists                    | `git worktree add` fails                       | Increment name: `workstream-2`, `workstream-3`, etc.                       |
| Branch already exists (in another worktree) | `git worktree add -b` fails                    | Use existing branch if not checked out elsewhere; otherwise increment name |
| Stale worktree (manually deleted)           | `git worktree list` shows it, but path missing | Run `git worktree prune` before listing                                    |
| Locked worktree                             | `git worktree remove` fails                    | Show "locked" indicator; offer "force unlock" as explicit action           |

### Risk Register (from external review)

| Risk                                 | Likelihood | Impact   | Mitigation                                                                                                                  | Status                                   |
| ------------------------------------ | ---------- | -------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| Project identity mismatch            | ~~HIGH~~   | ~~HIGH~~ | Place worktrees under repo                                                                                                  | ✅ Resolved by design                    |
| tmux session collisions              | LOW        | HIGH     | Pass workstream-shaped `Project` to launcher (`name` = workstream name, `path` = worktree path)                             | ✅ Resolved: no launcher changes needed  |
| Workstreams treated as real projects | LOW        | MEDIUM   | Workstreams use a separate type/view model, not `Project`. Only pass workstream-shaped `Project` to launcher, nowhere else. | Design constraint                        |
| Claude context fragmentation         | MEDIUM     | MEDIUM   | Group workstreams under parent in UI                                                                                        | Accept; each worktree is its own context |
| Unsafe destroy (dirty worktrees)     | MEDIUM     | HIGH     | Dirty indicator + no force default                                                                                          | Must implement                           |

### Kill Criteria

- ~~If active project resolution can't be made reliable~~ → Resolved: worktrees under repo
- If safe destroy requires lots of "force" paths and users can plausibly lose work
- If git worktree edge cases (locked worktrees, detached HEAD, etc.) dominate the UX

## Open Questions

1. **Terminal integration:** `TerminalLauncher.launchTerminal(for:)` takes a `Project`. For workstreams, pass a **workstream-shaped Project** where `path = worktree path` and `name = workstream name`. This gives unique tmux sessions automatically. The existing launcher doesn't need changes—just the caller's responsibility to construct the right Project.

2. **Main branch base:** When creating a worktree, should it branch from `main`, current branch, or ask? (YAGNI says: always branch from main, simplest mental model.)

3. **Visibility of worktrees in main dock:** Should worktrees for the "active" project appear subtly in the dock, or only in the dedicated view?

4. **Rename flow:** If someone wants to rename "workstream-1" to "exploration", does that also rename the branch? (Probably not—branch name is git's concern, display name is Capacitor's.)

5. **What if worktree already exists?** Just open it instead of creating a new one.

6. **Default branch detection:** Repo default isn't always `main`. Need to detect with `git symbolic-ref refs/remotes/origin/HEAD` or similar. **Fallback needed** when origin/HEAD is missing (no remote, offline, fresh repo)—probably fall back to `HEAD` (current commit).

7. **"Dirty" definition:** What triggers the dirty indicator before destroy? Options:
   - Uncommitted changes only (`git status --porcelain`)
   - Uncommitted OR local commits not on any remote branch
   - Uncommitted OR ahead of upstream (`@{u}`)

   **Recommendation:** Uncommitted changes only. "Ahead of upstream" is too noisy—users may intentionally have unpushed commits.

## Scope Boundaries

### In Scope

- Create worktree with one click (at `.capacitor/worktrees/{name}/`)
- Ensure `.capacitor/worktrees/` is excluded from git status (default: `.git/info/exclude`)
- Track worktree session state (existing path-based detection works)
- Dedicated workstreams view for the active project
- Destroy worktree with explicit action (with dirty state guardrails)
- Auto-generated naming with optional rename

### Out of Scope (for now)

- PR creation from Capacitor
- Merge flow automation
- Worktree templates ("exploration" vs "bugfix" presets)
- Multiple projects' worktrees in one view
- Syncing worktrees across machines

## Next Steps

Run `/workflows:plan` to design implementation phases.
