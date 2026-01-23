# Claude HUD Vision — January 2026

## The Problem

When you have many Claude Code projects in flight simultaneously, context-switching is expensive. You lose track of what you were working on, what the next step was, and whether you're blocked. The cognitive load of "remembering where everything is at" limits how many projects you can realistically push forward.

## The Insight

Claude already knows what you were doing in each project. A HUD can surface that context automatically — so you don't have to maintain a separate system or hold it all in your head.

## Current State

The app today is a windowed dashboard. Its primary value is the **notification sound** — alerting you when a Claude session needs attention. The visual display and Resume button are secondary because users with enough screen real estate can already see their terminal windows.

This suggests the windowed app form factor may be limiting. The "HUD" name implies something it isn't yet delivering: **persistent, ambient, glanceable**.

## The Vision: A True HUD

An always-visible side strip that:
- Shows project states at a glance (name + state indicator)
- Auto-focuses the right terminal when clicked
- Expands into a detail panel for context, summaries, and todos
- Is always present but never in the way

### Form Factor

- **Vertical side strip** — narrow (40-60px collapsed), positioned on left or right screen edge
- **Progressive disclosure** — collapsed shows mini project cards; click expands detail panel
- **Draggable** — user positions it on whichever screen edge works for their setup

### What It Shows (Collapsed)

Per project:
- Project name (truncated)
- State indicator (your turn / working / idle / compacting)
- Maybe: context % usage

### What It Shows (Expanded Detail Panel)

- Full project name and path
- Working on / next step
- Todo backlog (ideas to capture, work in progress)
- Session history / summaries
- Quick actions (Resume, Open Folder, etc.)

## Key Principles

1. **Performance is non-negotiable** — if the HUD adds latency, it defeats the purpose
2. **Start simple** — focus on highest-leverage features, resist creep
3. **Mac-only for now** — no cross-platform complexity
4. **Avoid notification fatigue** — sounds/alerts must be meaningful
5. **Discovery phase** — stay flexible, iterate based on usage

## User Modes

The HUD should support multiple modes of use:

1. **"What should I work on next?"** — prioritization at a glance
2. **"Where did I leave off on X?"** — quick context retrieval
3. **"What's the state of everything?"** — portfolio health check
4. **"Is anything blocked?"** — triage mode

## Open Questions

1. **Todo management** — emerging workflow (capture ideas → batch → execute → review → tie off). Core feature or later addition?
2. **Quick project creation** — nice-to-have, but 80% of usage is existing projects. Maybe a "Sandbox" tier for throwaway experiments?
3. **Auto-focus behavior** — should clicking a project auto-focus the terminal, or just show details?
4. **Multiple sessions per project** — how to handle if user has multiple terminals for same project?

## First Step: Panel Form Factor

Evolve the current app toward the HUD vision:

1. **Remove sidebar navigation** — current sidebar doesn't fit narrow panel model
2. **Add top tabs** — compact navigation that works in a narrow vertical layout
3. **Resize window** — make default dimensions resemble a single narrow panel
4. **Test docking** — verify app can be dragged to screen edge and stay there comfortably

This gets us a usable narrow-panel app that can be positioned like a HUD, without needing to build custom overlay/always-on-top behavior yet.

## Future Explorations

- Always-on-top / overlay mode (true HUD)
- Click-to-focus auto-navigation to correct terminal
- Live terminal thumbnails
- Cross-project todo view
- Project templates / quick creation
- "Coach" features (detect suboptimal Claude Code setups)

---

*Plan created: January 8, 2026*
*Status: Discovery phase*
