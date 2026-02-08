# Alpha Release Checklist

First public alpha of Capacitor — a native macOS dashboard for Claude Code.

**Scope:** Observe-only sidecar for Claude Code projects. No workstreams, no idea capture, no project details view. Simple, polished, reliable.

---

## 1. Feature Gating — Hide What's Not Shipping

These features exist in the codebase but are **out of scope** for alpha.

- [x] **Hide Workstreams/Worktrees** — Remove or gate `WorkstreamsPanel` from UI; remove "Create Workstream" actions from project cards and detail views
- [x] **Hide Idea Capture** — Remove `⌘+I` shortcut, idea capture button on project cards, `IdeaQueueView`, `IdeaDetailModal`, and `IdeaCaptureOverlay`
- [x] **Hide Project Details View** — Remove navigation to `ProjectDetailView` (info button on cards, detail push); cards should be action-only (open terminal, pause, remove)
- [x] **Hide Project Creation (NewIdeaView)** — Remove `ActivityPanel`, `NewIdeaView`, and any "create project from idea" flows
- [x] **Hide LLM-powered features** — Description generation, idea enrichment/sensemaking — none of these ship in alpha
- [x] **Hide Debug menu items** — Ensure debug panels/views are stripped from release builds

---

## 2. Core Features — Must Work Reliably

### Claude Code Support
- [ ] Session state detection works end-to-end (Working, Ready, Waiting, Compacting, Idle)
- [x] Stale session detection (>24hr in ready state) displays correctly
- [ ] State change animations (flashing/pulsing indicators) are smooth
- [x] Ready chime plays correctly when a session becomes ready

### Terminal Support (Ghostty, iTerm2, Terminal.app only)
- [ ] **Ghostty** — One-click activation, tab selection works
- [ ] **iTerm2** — One-click activation, AppleScript tab selection works
- [ ] **Terminal.app** — One-click activation, AppleScript tab selection works
- [x] **Hide/remove other terminals from UI** — Alacritty, kitty, Warp, IDE terminals should not appear as options in alpha (or at minimum, mark as unsupported)
- [x] Terminal activation gracefully fails if target terminal isn't running

### Project Management
- [x] **Browse to add** — "Link Project" via `NSOpenPanel` works, validates project directory
- [x] **Drag-and-drop to add** — Drop folder onto app window to add project
- [x] **Remove project** — "Remove from HUD" action works cleanly
- [x] **Project validation** — Rejects invalid paths, handles edge cases (already tracked, dangerous paths, suggest parent)
- [x] Projects persist across app restarts

### Project Card Reordering
- [x] Drag-to-reorder within active projects works with visual feedback
- [x] Order persists across app restarts (UserDefaults)
- [x] Reordering only applies to active (non-paused) projects

### Pause / Revive
- [x] "Pause" action on project card moves it to Paused section
- [x] Paused section appears/collapses correctly
- [x] "Revive" button moves project back to In Progress
- [x] Pause state persists across app restarts

### Keyboard Shortcuts
- [x] `⌘1` — Vertical layout
- [x] `⌘2` — Dock layout
- [x] `⌘⇧T` — Toggle floating mode
- [x] `⌘⇧P` — Toggle always-on-top
- [x] `⌘⇧?` — Open help (GitHub README)
- [x] `ESC` — Back navigation (if applicable after details view is hidden)
- [x] Audit for any shortcuts tied to hidden features (⌘+I idea capture) — remove them

### Dock Mode
- [x] Horizontal strip layout renders correctly
- [x] Pagination works with page indicators
- [x] Project cards display session state in compact form
- [x] One-click terminal activation from dock cards
- [x] Window constraints (min/max width/height) feel right for dock use

---

## 3. Onboarding — Streamline for Alpha

The current `WelcomeView` is step-by-step with hook installation + shell setup. Needs to feel polished for first-time users.

- [ ] **Audit current flow** — Walk through WelcomeView end-to-end, note friction points
- [x] **Simplify requirements checks** — Hook install + shell integration should feel like 1-2 steps, not a checklist
- [x] **Basic project detection** — After setup, auto-detect projects with `.claude/` or `CLAUDE.md` and offer to add them
- [x] **Clear error states** — If something fails, the user knows exactly what to do
- [x] **Transparency about hooks/daemon** — Setup explains what changes are made + what metadata is captured
- [x] **Setup card in project list** — Should only appear when hooks are genuinely broken, not as a first-run artifact
- [x] **Copy-to-clipboard shell instructions** — Must work perfectly for zsh (primary), bash, fish
- [x] **Test the "Fix All" auto-repair path** — Should handle common hook breakage gracefully

---

## 4. Window & Chrome

### Pin Window Option
- [x] Always-on-top toggle works (`⌘⇧P`)
- [x] Visual indicator when pinned (subtle UI cue so user knows state)
- [x] Persists across app restarts

### About Window
- [x] Shows app icon, name, version
- [x] Version reads from Info.plist / VERSION file correctly
- [x] Accessible via menu: "About Capacitor"

### Help Menu
- [x] "Capacitor Help" links to GitHub README
- [x] `⌘⇧?` shortcut works
- [x] Consider adding: "Report a Bug" → GitHub Issues link

---

## 5. Distribution & Updates

### Sparkle Auto-Updates
- [ ] SUFeedURL configured in Info.plist with valid appcast URL
- [ ] SUPublicEDKey set for signature verification
- [ ] "Check for Updates..." menu item works
- [ ] Automatic update check on launch (configurable in Settings)
- [ ] Test full update cycle: publish appcast → app detects → downloads → installs

### Build & Signing
- [ ] App is code-signed for distribution
- [ ] App is notarized for macOS Gatekeeper
- [ ] DMG or ZIP artifact for download
- [ ] Release tagged in git

### Easy Sharing
- [ ] **Landing page or GitHub release** — A single URL someone can visit to download
- [x] **README has clear install instructions** — Download → drag to Applications → launch
- [ ] Consider: brew cask formula (stretch goal, not required for alpha)

---

## 6. README & Branding

- [x] **App icon / logomark** finalized and included in assets
- [x] **README rewrite for public audience** — Current README is developer-facing; alpha README should be user-facing
  - [ ] Hero section with screenshot/gif
  - [x] Clear value proposition (1-2 sentences)
  - [x] Feature list matching alpha scope (no workstreams, no ideas, no details)
  - [x] Supported terminals (Ghostty, iTerm2, Terminal.app)
  - [x] System requirements (Apple Silicon, macOS 14+)
  - [x] Installation instructions
  - [x] Setup guide (hook installation, shell integration)
  - [x] Keyboard shortcuts reference
  - [x] Known limitations / alpha caveats
  - [x] Link to report issues
- [x] **Remove references to hidden features** from README (workstreams, ideas, project creation)

---

## 7. Quality & Polish

### Testing
- [ ] Fresh install test — clone repo, build, launch, full onboarding → add project → verify state tracking
- [ ] Test with 1, 5, 10, 20+ projects — performance and layout
- [ ] Test with no projects — empty state is helpful, not broken
- [ ] Test dock mode at various screen widths
- [ ] Test floating mode positioning and drag behavior
- [ ] Kill/restart daemon — app recovers gracefully
- [ ] Test with Claude Code actually running sessions — state transitions are accurate

### Edge Cases
- [x] Project directory deleted while tracked — app handles gracefully
- [x] Terminal app not installed — activation fails gracefully with useful message
- [ ] Multiple monitors — window positioning works correctly
- [ ] App launched at login — doesn't crash or hang

### Performance
- [ ] Polling intervals are reasonable (not hammering CPU)
- [ ] Memory usage stays stable over hours of use
- [ ] Animations are smooth at 120Hz (ProMotion)
- [ ] App launches quickly (<2 seconds to usable state)

---

## 8. Pre-Launch Cleanup

- [x] Remove any hardcoded dev paths or test data (runtime code clean; only tests/docs include example paths)
- [x] Audit `print()` / `NSLog` statements — remove or guard behind DEBUG
- [x] Verify version number is set correctly for alpha (e.g., `0.2.0-alpha.1`)
- [ ] Create GitHub release with changelog
- [ ] Tag release in git
- [ ] Test download → install → launch cycle from a clean Mac (or as close as possible)

---

## Out of Scope (Explicitly Not Shipping)

- Workstreams / git worktrees
- Idea capture & queue
- Project details view
- LLM-powered features (description generation, idea enrichment)
- Project creation from ideas
- Statistics / token usage display
- Session history / timeline
- Non-Claude-Code AI tool support
- Alacritty, kitty, Warp, IDE terminal support (may work, but unsupported)
