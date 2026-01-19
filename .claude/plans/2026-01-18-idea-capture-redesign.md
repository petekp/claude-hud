# Idea Capture Redesign

**Date:** 2026-01-18
**Status:** Design complete, ready for implementation
**Supersedes:** `idea-capture-ui-revamp.md` (research phase)

---

## Core Insight

Separate **capture** (main view) from **management** (detail view). Ideas are fleeting thoughts that need to be captured fast before they evaporate. Organization and action come later.

---

## Part 1: Main View Capture

### Interaction

**Trigger:** Click existing idea pill (already shows count like "3 ideas")

**Popover contents:**
- Text input field (auto-focused on open)
- Save / Cancel buttons

**Keyboard shortcuts:**
- `Return` — Save and close popover
- `Shift+Return` — Save, clear input, stay open for rapid-fire capture
- `Escape` — Cancel and close

**After save:**
- Pill count updates immediately
- Background sensemaking begins (non-blocking)

### Rationale

The pill already exists and communicates "ideas live here." Making it the entry point is discoverable without adding UI clutter. The popover is minimal — no title field, no effort picker, no project selector. Just dump the thought.

---

## Part 2: Project Detail View

### Mental Model

**Playlist queue** — A simple ordered list where the top item is "next up." No status groupings, no categories, no hierarchy.

### Display

- Flat list of ideas in priority order
- Top idea is visually emphasized (first in queue)
- Each idea shows: title, description preview (from sensemaking)
- Drag handles for reordering

### Interactions

| Action | Behavior |
|--------|----------|
| Drag and drop | Reorder priority |
| Click idea | Expand to see full description |
| Start working | Future: explicit action to begin, agent tracks completion |
| Complete | Future: agent auto-detects, idea disappears from queue |

### What's Removed

- Status sections (OPEN / IN PROGRESS / DONE)
- Manual status toggles
- The "Done" archive

### Rationale

Status is implicit:
- In the queue = open
- Being worked on = in progress (future: detected by agent)
- Disappeared = done

This eliminates cognitive overhead of managing status while preserving the underlying data model.

---

## Part 3: Background Sensemaking

### Purpose

Turn raw brain dumps into structured, actionable ideas without user effort.

### Trigger

Runs asynchronously after each capture. Non-blocking — user sees "Saving idea..." shimmer, then title updates when ready.

### Adaptive Depth

The model assesses signal level and adjusts expansion accordingly:

| Input Quality | Model Output |
|---------------|--------------|
| Vague ("that auth thing") | Full expansion: clean title, 1-2 sentence description, inferred files/context |
| Moderate ("fix timeout in auth flow") | Clean title, brief description |
| Specific ("In auth.ts:42, handle 401") | Pass-through with normalized formatting |

### Context Provided

**Always include (~75 tokens):**
- Raw idea text
- Project name
- 3-5 most recently touched file paths

**Include during active session (~75 more tokens):**
- Last commit message
- Current branch name
- Brief session summary ("User was working on authentication")

**Cached and reused (amortized):**
- Project summary (regenerate weekly or on significant changes)

**Deferred (expensive, save for batch ops):**
- Other ideas in project (for clustering, dedup, relationships)

### Output Schema

```json
{
  "title": "string — clean, actionable title",
  "description": "string — 1-3 sentences expanding the idea",
  "confidence": "number 0-1 — how confident the model is in its interpretation",
  "inferred_context": {
    "likely_files": ["array of file paths"],
    "related_to": "string — what this seems connected to"
  }
}
```

### Error Handling

| Scenario | Behavior |
|----------|----------|
| Model timeout (>10s) | Save with raw text as title, retry later |
| Low confidence (<0.3) | Flag for user review, don't auto-expand |
| Model unavailable | Save raw, queue for background processing |

---

## Part 4: Deferred Features

These require the foundation above to be working first:

### "Work On This" Flow
- Explicit action to begin working on an idea
- Agent watches session to detect completion
- Completed ideas disappear from queue

### Clustering
- Once ideas are structured via sensemaking, LLM can identify patterns
- User-triggered, not auto-imposed
- Clusters as optional views, not permanent structure

### Cross-Project Intelligence
- Spot patterns across projects ("these 3 ideas touch auth")
- Requires structured ideas + multiple active projects

### Dependency Graphing
- LLM identifies which ideas depend on others
- Auto-sequencing suggestions
- Requires structured ideas with enough detail

---

## Implementation Sequence

### Phase 1: Capture Flow
1. Add popover to idea pill click
2. Implement text input with keyboard shortcuts
3. Wire up to existing `capture_idea()` Rust function
4. Update pill count on save

### Phase 2: Detail View Simplification
1. Replace `IdeasListView` status sections with flat queue
2. Add drag-and-drop reordering
3. Persist order (new field in ideas.local.md or separate ordering)
4. Remove status UI, keep status in data model

### Phase 3: Background Sensemaking
1. Design prompt for signal assessment + adaptive expansion
2. Implement async title/description generation after capture
3. Add context gathering (recent files, session info)
4. Handle errors gracefully

### Phase 4: Polish
1. Animate queue reordering
2. Add "top idea" reminder on project cards (main view)
3. Age indicators for stale ideas

---

## Technical Notes

### Files to Modify

| Component | File | Changes |
|-----------|------|---------|
| Idea pill popover | `Views/Projects/ProjectCardView.swift` | Add popover trigger |
| Capture popover | New: `Views/Ideas/IdeaCapturePopover.swift` | Text input + shortcuts |
| Detail view queue | `Views/Ideas/IdeasListView.swift` | Replace with flat queue |
| Drag reordering | `Views/Ideas/IdeasListView.swift` | Add `onMove` handler |
| Order persistence | `core/hud-core/src/ideas.rs` | Add order field or separate file |
| Sensemaking | `apps/sdk-bridge/` or new service | Async LLM calls |

### Data Model Changes

Current idea structure in `ideas.local.md`:
```markdown
### [#idea-ULID] Title
- **Added:** timestamp
- **Effort:** unknown
- **Status:** open
- **Triage:** pending
- **Related:** None

Description text
```

Add:
```markdown
- **Order:** 1
- **Description:** LLM-generated expansion (distinct from raw input)
```

Or: Store order separately to avoid churning the markdown on every reorder.

---

## Success Criteria

1. **Capture in <2 seconds** — Click pill, type thought, Enter. Done.
2. **Ideas feel alive** — Sensemaking transforms dumps into clear items
3. **Queue is obvious** — Top = next, drag = reprioritize, done = gone
4. **Zero status management** — No clicking checkboxes or moving between columns

---

## Open Questions

1. **Order persistence format** — Inline in markdown vs. separate JSON?
2. **Sensemaking model** — Haiku for speed, or Sonnet for quality?
3. **Completion detection** — How does the agent know when you're done? (Deferred)

---

*Design session: 2026-01-18*
