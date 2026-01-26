# Project Context Signals Brainstorm

**Date:** 2026-01-26
**Status:** Ready for planning

## Problem Statement

The current project summary feature isn't being used. Investigation revealed:

1. **Technical issues:** The three-tier fallback (`workingOn` → `lastKnownSummary` → `latestSummary`) is broken—tier 1 is never populated by hooks, and tier 3 only loads at startup.

2. **Design issues:** Even if working, prose summaries may be the wrong format. The user imagined value in "efficiently re-establishing context during rapid context switching" but found themselves not actually looking at the summaries.

## Key Insight

The real need is **scannable signals**, not prose narratives.

When context-switching across intellectually demanding tasks, you want to glance at a card and instantly know:
- **State:** Is this blocked? Active? Idle?
- **Recency:** How long since I touched this?
- **Progress:** How far along am I? (optional)

A 1-2 line prose summary requires reading and parsing. Structured signals are instant.

## What We're Building

**Structured Status Chips** — Replace prose summaries with scannable signals:

### Default View (Compact)
- 2-3 small chips: `State` + `Recency` + optional `Progress`
- Example: `🟡 Waiting` · `2h ago` · `3/7`

### Expanded View (Hover/Click)
- Reveals the prose summary (from JSONL) for deeper context
- Any user-added notes (future enhancement)

### Dock Mode
- Minimal: just state indicator (colored dot/icon)

### Data Sources (Auto-Inferred)
- **State:** Already tracked via hooks (Ready, Working, Waiting, etc.)
- **Recency:** Derive from `updated_at` in session state or file mtime
- **Progress:** Parse from todo list if present in session, or omit

## Why This Approach

1. **Aligns with actual use case:** Rapid scanning before context-switching
2. **No new data capture needed:** State and timestamps already exist
3. **Progressive disclosure:** Compact by default, detail on demand
4. **Layout-aware:** Different density for dock vs vertical mode
5. **Respects sidecar philosophy:** Passive observation, no Claude integration required

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary display | Structured chips | Scannable > readable for rapid switching |
| Data source | Auto-inferred from existing signals | No new hooks or manual input required |
| Prose summary | Still available on hover/expand | Preserves existing value for deeper context |
| Visual approach | Progressive disclosure | Minimal by default, rich on demand |
| Layout variance | Yes, dock mode is more minimal | Different contexts need different density |

## Open Questions

1. **What constitutes "stale"?** 1 hour? 1 day? Should this be user-configurable?
2. **Progress indicator:** Is parsing todo lists reliable enough? Should we skip this for v1?
3. **State vocabulary:** Current states are (Ready, Working, Waiting, Compacting, Idle). Are these the right user-facing labels?
4. **Color coding:** What palette for state chips? Need to work in both light themes and dark frosted glass.

## Out of Scope (for now)

- User-driven "parking notes" (could be a future enhancement)
- AI-generated structured metadata (adds complexity, may not be needed)
- Real-time `workingOn` from hooks (Claude doesn't emit this data)

## Next Steps

Run `/workflows:plan` to design the implementation:
1. Fix the existing `latestSummary` refresh bug (stats not reloading)
2. Add recency signal derivation
3. Replace prose display with chip layout
4. Implement progressive disclosure (hover/expand)
5. Adapt for dock mode

---

*Brainstorm conducted with user via collaborative dialogue.*
