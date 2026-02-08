# Spike: Post-setup Project Detection

## Context
We want onboarding to offer existing projects automatically after setup. The app already has project validation/ingestion and a rust-backed API for suggested projects, but it isn’t wired into the UI.

## Goal
Identify the simplest, reliable mechanism to surface suggested projects after onboarding (WelcomeView completion) and present a quick add flow.

## Questions

| # | Question |
|---|----------|
| **X1-Q1** | Is there an existing API for suggested projects, and what data does it provide? |
| **X1-Q2** | Where should suggestions be shown (WelcomeView completion vs first visit to Projects list)? |
| **X1-Q3** | How do we filter out already-tracked projects and handle missing `CLAUDE.md`? |
| **X1-Q4** | What’s the lightest UI affordance to accept/skip suggestions? |

## Findings (so far)

- **Suggested projects API exists**: `HudEngine.getSuggestedProjects()` returns `[SuggestedProject]` with fields `path`, `displayPath`, `name`, `taskCount`, `hasClaudeMd`, `hasProjectIndicators`. (Defined in `hud_core.swift`.)
- **Project add flow exists**: `AppState.addProject(_:)` and `validateProject(_:)` handle linking + validation. `AddProjectView` already handles missing `CLAUDE.md` with “Create & Connect.”

## Acceptance
Spike is complete when we can describe:
- Where to fetch suggestions in the UI flow
- How to filter and present them
- The minimal add/skip interaction

## Resolution
- **Fetch** suggestions on the empty projects view (`EmptyProjectsView.onAppear`) via `HudEngine.getSuggestedProjects()`.
- **Present** a compact list (top 3) with name/path + sessions + CLAUDE.md badge.
- **Actions**: “Add” per suggestion (adds + toasts) and “Dismiss” to hide suggestions.
