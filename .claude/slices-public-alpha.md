# Public Alpha — Feature Gating Slices

## Slice Summary

| # | Slice | Mechanism (Parts) | Demo |
|---|-------|-------------------|------|
| V1 | No details / no ideas | A1, A2, A3 | “In alpha, project cards show no Info/Capture buttons and no detail view can open.” |
| V2 | No project creation | A1, A2, A3 | “Activity panel is gone and New Idea view cannot be opened.” |
| V3 | No workstreams / no LLM surfaces | A1, A2 | “In alpha, workstreams + description generation are absent.” |
| V4 | Shortcut/menu cleanup | A4 | “No hidden-feature shortcuts or menu items remain in alpha.” |

---

## V1: No details / no ideas

**Status:** ✅ COMPLETE (feature-flag defaults already enforced + UI entrypoints gated)

**Affordances removed or gated**
- U1 (Info button), U2 (Capture Idea button) on project cards
- P2 (Project Detail View), P3 (Idea Detail Modal), P4 (Idea Capture Modal)

**Code changes (mechanism)**
- FeatureFlags defaults for alpha: `projectDetails = false`, `ideaCapture = false` (already true for alpha; keep as explicit behavior)
- Guard UI entrypoints in `ProjectsView`, `DockLayoutView`, `ProjectCardView` and navigation in `NavigationContainer`
- Guard `AppState.showProjectDetail`, `AppState.showIdeaCaptureModal`, and any idea capture actions (already guarded; ensure all entrypoints respect flags)

**Demo**
- Set channel to alpha: no Info/Capture buttons, no detail navigation, no idea capture overlay

---

## V2: No project creation

**Status:** ✅ COMPLETE

**Affordances removed or gated**
- U4 (ActivityPanel), P5 (New Idea View)

**Code changes (mechanism)**
- Add `projectCreation` (or `newIdea`) feature flag
- Gate `ActivityPanel` rendering in `ProjectsView`
- Gate `NewIdeaView` in `NavigationContainer` and any `showNewIdea()` calls
- Ensure creation actions are blocked in `AppState.createProjectFromIdea`

**Demo**
- In alpha: no Activity section, no New Idea screen reachable

---

## V3: No workstreams / no LLM surfaces

**Status:** ✅ COMPLETE

**Affordances removed or gated**
- U6–U8 (WorkstreamsPanel), description generation in ProjectDetailView

**Code changes (mechanism)**
- Add `workstreams` and `llmFeatures` flags (or similar)
- Gate `WorkstreamsPanel` and `DescriptionSection` in `ProjectDetailView`

**Demo**
- In alpha: workstreams + description generation never appear

---

## V4: Shortcut/menu cleanup

**Status:** ✅ COMPLETE (audit found no hidden-feature shortcuts/menus outside DEBUG)

**Affordances removed or gated**
- Any keyboard shortcuts or menu commands tied to hidden features (e.g., idea capture)

**Code changes (mechanism)**
- Audit commands and keyboard handlers; remove or gate those tied to hidden features

**Demo**
- In alpha: keyboard shortcuts and menus only reference in-scope features
