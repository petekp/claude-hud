---
title: "feat: Structured Status Chips for Project Cards"
type: feat
date: 2026-01-26
brainstorm: docs/brainstorms/2026-01-26-project-context-signals-brainstorm.md
---

# Structured Status Chips for Project Cards

Replace prose project summaries with scannable status chips (State + Recency), with progressive disclosure on hover to reveal the full summary.

## Problem

The current prose summary isn't being used. Users need **scannable signals** for rapid context-switching, not paragraphs to read. Additionally, the summary data pipeline is broken—`latestSummary` only loads at startup and never refreshes.

## Solution

**Default view:** 2-3 compact chips showing structured signals
```
🟢 Ready · 2h ago        (active session, recently touched)
⚪ Idle · 3d ago         (no session, getting stale)
🟡 Waiting · 5m ago      (needs user action)
```

**Hover/expand:** Reveals the prose summary for deeper context

**Dock mode:** Minimal—just state dot + recency text

## Acceptance Criteria

- [x] Create `RelativeTimeFormatter` utility for human-friendly recency ("just now", "2h ago", "3d ago")
- [x] Create `StatusChip` component with state color + label + recency
- [x] Replace `ProjectCardContent` prose display with chip layout
- [x] Add hover state that reveals prose summary below chips
- [x] Adapt `DockProjectCard` to show minimal chip variant
- [x] Fix stats refresh: call `loadDashboard()` periodically or on JSONL file changes
- [x] Remove redundant `StaleBadge` (recency chip replaces it)
- [x] Respect `@Environment(\.prefersReducedMotion)` for animations

## Key Design Decisions

| Decision | Choice |
|----------|--------|
| Chip content | State label + Recency (skip Progress for v1) |
| State colors | Reuse existing `Color.statusColor(for:)` palette |
| Recency thresholds | <1m: "now", <1h: "Xm", <24h: "Xh", <7d: "Xd", else: date |
| Stale threshold | Keep existing 24h, but express via muted chip color |
| Detail on hover | Inline expansion below chips (not popover) |
| Empty state | Show "Idle · Never" chip for projects with no session |

## Implementation Phases

### Phase 1: Foundation
1. Create `RelativeTimeFormatter.swift` in `Utils/`
2. Standardize timestamp parsing (use ISO8601 with fractional seconds everywhere)
3. Add stats refresh to the 1-second timer (throttled to every 30s)

### Phase 2: Chip Components
4. Create `StatusChip.swift` component with `.normal` and `.compact` style variants
5. Create `RecencyChip.swift` component
6. Create `StatusChipsRow.swift` container that arranges chips horizontally

### Phase 3: Card Integration
7. Update `ProjectCardView` to use chips instead of prose
8. Add hover-triggered prose expansion with spring animation
9. Update `DockProjectCard` with compact chip variant
10. Remove `StaleBadge` usage (recency chip replaces it)

### Phase 4: Polish
11. Add accessibility labels for chips
12. Test reduced motion fallbacks
13. Verify dark glass + solid backgrounds both work

## File Changes

| File | Change |
|------|--------|
| `Utils/RelativeTimeFormatter.swift` | **NEW** — relative time formatting |
| `Views/Projects/StatusChip.swift` | **NEW** — state chip component |
| `Views/Projects/StatusChipsRow.swift` | **NEW** — chip layout container |
| `Views/Projects/ProjectCardView.swift` | Replace prose with chips, add hover expansion |
| `Views/Projects/ProjectCardComponents.swift` | Remove `StaleBadge`, update `ProjectCardContent` |
| `Views/Projects/DockProjectCard.swift` | Use compact chip variant |
| `Models/AppState.swift` | Add throttled stats refresh to timer |

## Edge Cases

- **No session state:** Show `Idle · Never` chip
- **No prose summary:** Hover shows "No summary available" placeholder
- **Very old recency (>30d):** Show date like "Dec 15" instead of "32d ago"
- **Blocker present:** Keep blocker row below chips (unchanged)

## References

- Brainstorm: `docs/brainstorms/2026-01-26-project-context-signals-brainstorm.md`
- Existing patterns: `StaleBadge` at `ProjectCardComponents.swift:372-392`
- Status colors: `Color.statusColor(for:)` in `Theme/Colors.swift`
- Hover pattern: `PeekCaptureButton` at `ProjectCardView.swift:353-438`
- Time parsing gotcha: Use `.withFractionalSeconds` for Rust timestamps (CLAUDE.md)
