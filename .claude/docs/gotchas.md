# Gotchas Reference

Detailed implementation gotchas for Capacitor development. See CLAUDE.md for the most common ones.

For multi-step debugging procedures, see [debugging-guide.md](debugging-guide.md).

## Rust

### Formatting Required
CI enforces `cargo fmt`. Pre-commit hook catches this.

### dylib Copy After Rebuilds
After Rust rebuilds: `cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/`

### hud-hook Symlink (Not Copy)
Copying adhoc-signed Rust binaries to `~/.local/bin/` triggers macOS Gatekeeper SIGKILL (exit 137). Use symlink instead:
```bash
ln -s target/release/hud-hook ~/.local/bin/hud-hook
```
See `scripts/sync-hooks.sh`.

### hud-hook Must Point to Dev Build
During development, `~/.local/bin/hud-hook` must symlink to `target/release/hud-hook` (not app bundle) to pick up changes. After Rust changes: rebuild, verify symlink target. Stale hooks lead to stale daemon state and missing events.

### Logging Guard Must Be Held
`logging::init()` returns `Option<WorkerGuard>` which must be held in `main()` scope. Using `std::mem::forget()` prevents log flushing. See `logging.rs` and `main.rs:70`.

### UniFFI Bindings Must Be Regenerated
After adding/changing fields in FFI types (e.g., `ShellEntryFfi`), regenerate Swift bindings:
```bash
cargo build -p hud-core --release  # Must build release first
cargo run --bin uniffi-bindgen generate \
    --library target/release/libhud_core.dylib \
    --language swift --out-dir apps/swift/bindings
cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/
```
Symptom without this: Swift compile error "extra argument 'fieldName' in call".

### Tmux Multi-Client Detection
Use `tmux display-message -p "#{client_tty}"` (not `list-clients`) to get the current client's TTY. `list-clients` returns clients in arbitrary order—wrong when multiple terminals are attached to the same session.

**Efficient pattern:** Combine queries into single call:
```rust
// Instead of two calls for session + tty:
run_tmux_command(&["display-message", "-p", "#S\t#{client_tty}"])
// Then split on '\t'
```

## Swift

### OSLog Not Captured for Debug Builds

Swift's `Logger` (OSLog) doesn't output for unsigned debug builds via `swift run`. Use stderr or `DebugLog.write(...)` for debugging. See [debugging-guide.md](debugging-guide.md#debug-logs-for-debug-builds) for capture instructions.

### NSImage Tinting Compositing Order

Draw image first with `.copy`, then apply color with `.sourceAtop`:
```swift
self.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
color.set()
rect.fill(using: .sourceAtop)  // Colors only where image has content
```
Wrong order (fill first, then draw) results in blank image.

### SwiftUI Hit Testing: Conditional Rendering vs Hidden Views

`opacity(0)` with `allowsHitTesting(false)` still creates dead zones that block window dragging. Use conditional rendering (`if`) to fully remove views from the hierarchy instead.

### SwiftUI Gestures Block NSView Events

`onTapGesture(count: 2)` intercepts `mouseDown` events, preventing `NSWindow.performDrag(with:)`. Solutions: use `NSViewRepresentable` with `mouseDown` checking `event.clickCount`, remove the gesture, or apply it only to non-draggable areas.

### SwiftUI GeometryReader Constraint Loops

Reading `@ObservedObject`/`@Observable` inside `GeometryReader` triggers infinite constraint update loops (`EXC_BREAKPOINT`). Capture observable values into `let` bindings **before** entering `GeometryReader`:
```swift
let spacing = glassConfig.cardSpacingRounded  // Before GeometryReader
GeometryReader { geometry in
    LazyHStack(spacing: spacing) { ... }
}
```
**Rule:** Same applies to `scrollTransition` and similar layout callbacks.

### TimelineView + Material Blur Crashes WindowServer

`TimelineView(.animation)` at 120fps + `.ultraThinMaterial` overwhelms WindowServer, causing macOS logout. Use `@State` + `withAnimation(.linear.repeatForever)` instead—Core Animation interpolates without re-evaluating view body or invalidating blur cache.

```swift
// BAD: re-renders blur 120x/sec
TimelineView(.animation) { ... }

// GOOD: Core Animation interpolates
@State private var phase: CGFloat = 0
shape.strokeBorder(style: StrokeStyle(dashPhase: phase))
    .onAppear {
        withAnimation(.linear(duration: 0.35).repeatForever(autoreverses: false)) {
            phase = 10
        }
    }
```

### ScrollView Fade Mask Without Masking Scrollbars

Applying `.mask` to `ScrollView` also masks scroll indicators. Fix: split mask horizontally—gradient for content, solid white strip for scrollbar area using `NSScroller.scrollerWidth(...)`.

### SwiftUI Rapid State Changes Cause Recursive Layout Crashes

Multiple overlapping `objectWillChange.send()` calls during rapid state changes (e.g., killing multiple sessions) crash with `EXC_BREAKPOINT`. Fix: debounce `objectWillChange.send()` at ~16ms (one frame). See `AppState.swift:216-235`.

### Multi-Source Version Detection

| Context | Version Source |
|---------|---------------|
| Release build | `Info.plist` (set by `build-distribution.sh`) |
| Dev build (`swift run`) | `VERSION` file in project root |
| Unknown | Hardcoded fallback (updated by `bump-version.sh`) |

Check `Info.plist` first → `VERSION` file → hardcoded fallback. SPM debug builds don't get correct Info.plist values.

### CI Smoke Test Fallbacks
When scripts need resources from full builds, check `$CI` to provide fallbacks. GitHub Actions sets `$CI=true` automatically.

### Never Use Bundle.module
Use `ResourceBundle.url(forResource:withExtension:)` instead—crashes in distributed builds.

### SwiftUI View Reuse
Use `.id(uniqueValue)` to force fresh instances for toasts/alerts.

### Swift 6 Concurrency
Views initializing `@MainActor` types need `@MainActor` on the view struct.

### Rust↔Swift Timestamps
Use custom decoder with `.withFractionalSeconds`. See `ShellStateStore.swift`.

### UniFFI Task Shadows Swift Task
UniFFI bindings define a `Task` type shadowing Swift's `_Concurrency.Task`. Always use `_Concurrency.Task` explicitly. Symptom: "cannot specialize non-generic type 'Task'" errors.

### Swift Incremental Build Stale Binary

If no `.swift` files changed, `swift build` produces no new binary. Use `--force` flag:
```bash
./scripts/dev/restart-app.sh --force  # Touches App.swift to force recompilation
```
Common when: Rust-only changes, interrupted builds, or interleaved IDE/CLI builds.

## Terminal Activation

### Rust Activation Resolver Is Sole Path
Terminal activation uses a single path: Rust decides (`engine.resolveActivation()`), Swift executes (`executeActivationAction()`). All decision logic lives in `core/hud-core/src/activation.rs` (50+ unit tests).

### TTY Discovery Before Ghostty-Specific Handling
In `activateHostThenSwitchTmux`, always try TTY discovery first. Without this, Ghostty gets activated even when tmux is running in iTerm. Order: TTY discovery → if not found AND Ghostty running → Ghostty window-count strategy → fallback.

### Shell Selection: Tmux Priority When Client Attached
> **Daemon-only note (2026-02):** Shell selection uses the daemon shell snapshot (`get_shell_state`).

Priority order in `find_shell_at_path()`: live beats dead → tmux beats non-tmux (when client attached) → most recent timestamp. Without tmux priority, a recent non-tmux cd causes `ActivateByTty` instead of `ActivateHostThenSwitchTmux`.

### Shell Selection: Known Parent Beats Unknown
Shells with known `parent_app` rank ahead of unknown before timestamp tie-breakers. Unknown parent forces TTY discovery which fails for Ghostty. See `activation.rs`, test `test_known_terminal_beats_newer_unknown_shell`.

### Shell Selection: HOME Excluded from Parent Matching
HOME is excluded from parent-child path matching (monorepo support). Without this, a shell at HOME matches all projects. See `paths_match_excluding_home()` in `activation.rs`.

### Tmux Context: "Has Client" Means ANY Client
`hasAttachedClient` must mean "any tmux client exists anywhere" NOT "client attached to this specific session." If ANY client exists, we can `tmux switch-client`. Only launch new terminal when NO clients exist.

### Query Fresh Client TTY at Activation Time
Daemon shell records include `tmux_client_tty` captured at hook time, which becomes stale when users reconnect. Always query fresh TTY at activation time with `tmux display-message -p '#{client_tty}'`. See `TerminalLauncher.swift:activateHostThenSwitchTmux`.

### Shell Escaping for Injection Prevention
Use `shellEscape()` (single-quote) and `bashDoubleQuoteEscape()` (double-quote) from `TerminalLauncher.swift` when interpolating user-controlled values into shell commands.

For terminal activation debugging procedures, see [debugging-guide.md](debugging-guide.md#terminal-activation-not-working-wrong-window-focused).

## Tmux

### Use `new-session -A` for Idempotent Session Creation
Use `tmux new-session -A -s 'session'` instead of `tmux attach-session -t 'session'`. The `-A` flag creates if missing, attaches if exists. Note: `-c '/path'` only affects creation, not existing sessions.

## State & Focus

### Focus Override Behavior
Manual override persists until clicking different project OR navigating to directory with active session. Navigating to project without session keeps focus (prevents timestamp racing). See `ActiveProjectResolver.swift`.

## Hooks

### Async Hooks Need Both Fields
Claude Code requires BOTH `"async": true` AND `"timeout": 30`. Missing either causes validation failure. Check `~/.claude/settings.json` for malformed entries. See `setup.rs:422-426`.

### Testing Unhealthy Hook States
App auto-repairs hooks at startup. To test SetupStatusCard visibility:
1. Remove both `~/.local/bin/hud-hook` AND `apps/swift/.build/.../hud-hook` to prevent auto-repair, OR
2. Add `disableAllHooks: true` to `~/.claude/settings.json`

Heartbeat check allows a short grace window when an active daemon session exists. See `check_hook_health()` in `engine.rs`.

## Activity Tracking

Activity entries are now derived and stored by the daemon (`core/daemon/src/activity.rs`) and queried over IPC. No file-based ActivityStore is used in daemon-only mode.
