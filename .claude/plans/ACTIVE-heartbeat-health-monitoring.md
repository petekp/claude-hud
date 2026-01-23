# Heartbeat-Based Hook Health Monitoring

**Status:** ✅ Implemented
**Goal:** Detect when hooks stop firing mid-session and alert users before they encounter stale state

## Problem

Hooks can silently stop working during a session due to:
- Binary killed by macOS (SIGKILL on unsigned code)
- Binary crashes or corruption
- Claude Code process anomalies

Currently, there's no runtime detection—users only discover the problem when they see stale state in the HUD.

## Solution: Three-Layer Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Hook Binary   │ ──► │    Rust Core    │ ──► │   Swift Client  │
│  (writes file)  │     │ (reads/interprets)    │  (displays UI)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

1. **Hook Binary** — Touches heartbeat file on every event
2. **Rust Core** — Exposes `check_hook_health()` API, interprets staleness
3. **Swift Client** — Displays warning banner when unhealthy

## Implementation

### Phase 1: Hook Binary (hud-hook)

**File:** `core/hud-hook/src/handle.rs`

Add heartbeat file touch at start of `handle_event()`:

```rust
use std::fs::OpenOptions;
use std::io::Write;

fn touch_heartbeat() {
    let heartbeat_path = dirs::home_dir()
        .map(|h| h.join(".capacitor/hud-hook-heartbeat"))
        .unwrap_or_default();

    // Create/update file to refresh mtime
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&heartbeat_path)
    {
        let _ = writeln!(file, "{}", chrono::Utc::now().timestamp());
    }
}

pub fn handle_event(event: &HookEvent) -> Result<(), HookError> {
    touch_heartbeat();  // First thing on every event
    // ... existing logic
}
```

**Heartbeat file:** `~/.capacitor/hud-hook-heartbeat`
- Contains Unix timestamp of last update
- Mtime used for staleness detection

### Phase 2: Rust Core Types

**File:** `core/hud-core/src/types.rs`

```rust
#[derive(Debug, Clone, uniffi::Enum)]
pub enum HookHealthStatus {
    /// Hooks are firing normally (heartbeat within threshold)
    Healthy,
    /// No heartbeat file exists (hooks never fired or file deleted)
    Unknown,
    /// Heartbeat is stale (hooks stopped firing)
    Stale { last_seen_secs: u64 },
    /// Heartbeat file exists but can't be read
    Unreadable { reason: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HookHealthReport {
    pub status: HookHealthStatus,
    pub heartbeat_path: String,
    pub threshold_secs: u64,
    pub last_heartbeat_age_secs: Option<u64>,
}
```

### Phase 3: Rust Core Engine

**File:** `core/hud-core/src/engine.rs`

```rust
const HOOK_HEALTH_THRESHOLD_SECS: u64 = 60;

impl HudEngine {
    pub fn check_hook_health(&self) -> HookHealthReport {
        let heartbeat_path = self.capacitor_dir.join("hud-hook-heartbeat");
        let threshold_secs = HOOK_HEALTH_THRESHOLD_SECS;

        let (status, age) = match std::fs::metadata(&heartbeat_path) {
            Ok(meta) => {
                match meta.modified() {
                    Ok(mtime) => {
                        let age_secs = mtime
                            .elapsed()
                            .map(|d| d.as_secs())
                            .unwrap_or(0);

                        let status = if age_secs <= threshold_secs {
                            HookHealthStatus::Healthy
                        } else {
                            HookHealthStatus::Stale { last_seen_secs: age_secs }
                        };
                        (status, Some(age_secs))
                    }
                    Err(e) => (
                        HookHealthStatus::Unreadable { reason: e.to_string() },
                        None
                    ),
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                (HookHealthStatus::Unknown, None)
            }
            Err(e) => (
                HookHealthStatus::Unreadable { reason: e.to_string() },
                None
            ),
        };

        HookHealthReport {
            status,
            heartbeat_path: heartbeat_path.display().to_string(),
            threshold_secs,
            last_heartbeat_age_secs: age,
        }
    }
}
```

**UniFFI export:** Add to `core/hud-core/src/lib.rs`:
```rust
pub use types::{HookHealthStatus, HookHealthReport};
```

### Phase 4: Swift Client

**New file:** `apps/swift/Sources/ClaudeHUD/Views/Components/HookHealthBanner.swift`

```swift
import SwiftUI

struct HookHealthBanner: View {
    let health: HookHealthReport
    let onRetry: () -> Void

    var body: some View {
        switch health.status {
        case .healthy:
            EmptyView()

        case .unknown:
            EmptyView()  // Don't warn if no session started yet

        case .stale(let lastSeenSecs):
            WarningBanner(
                icon: "exclamationmark.triangle.fill",
                message: "Hooks stopped responding \(formatAge(lastSeenSecs)) ago",
                action: ("Retry", onRetry)
            )

        case .unreadable(let reason):
            WarningBanner(
                icon: "exclamationmark.triangle.fill",
                message: "Can't check hook health: \(reason)",
                action: nil
            )
        }
    }

    private func formatAge(_ secs: UInt64) -> String {
        if secs < 120 { return "\(secs)s" }
        let mins = secs / 60
        return "\(mins)m"
    }
}

private struct WarningBanner: View {
    let icon: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.orange)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if let (label, handler) = action {
                Button(label, action: handler)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }
}
```

**Integration in AppState.swift:**

```swift
@Observable
final class AppState {
    // ... existing properties
    private(set) var hookHealth: HookHealthReport?

    func checkHookHealth() {
        hookHealth = engine.checkHookHealth()
    }
}
```

**Integration in ProjectsView.swift** (or main content view):

```swift
var body: some View {
    VStack(spacing: 0) {
        // Show banner at top when unhealthy
        if let health = appState.hookHealth {
            HookHealthBanner(health: health) {
                Task { await appState.refreshSessions() }
            }
        }

        // ... existing content
    }
    .task {
        appState.checkHookHealth()
    }
}
```

### Phase 5: Periodic Health Check

Add to AppState's polling loop:

```swift
// Check health every 30 seconds when there are active sessions
private func startHealthMonitoring() {
    Timer.publish(every: 30, on: .main, in: .common)
        .autoconnect()
        .sink { [weak self] _ in
            guard let self, self.hasActiveSessions else { return }
            self.checkHookHealth()
        }
        .store(in: &cancellables)
}
```

## File Changes Summary

| File | Change |
|------|--------|
| `core/hud-hook/src/handle.rs` | Add `touch_heartbeat()` call |
| `core/hud-core/src/types.rs` | Add `HookHealthStatus`, `HookHealthReport` |
| `core/hud-core/src/engine.rs` | Add `check_hook_health()` method |
| `core/hud-core/src/lib.rs` | Export new types |
| `apps/swift/.../HookHealthBanner.swift` | New component |
| `apps/swift/.../AppState.swift` | Add health check integration |
| `apps/swift/.../ProjectsView.swift` | Display banner |

## Testing Strategy

1. **Unit test** `check_hook_health()` with mock heartbeat files
2. **BATS test** heartbeat file creation in `tests/hud-hook/`
3. **Manual test**:
   - Kill hook binary, verify banner appears within 60s
   - Restart hooks, verify banner disappears

## Threshold Rationale

**60 seconds** chosen because:
- Long enough to avoid false positives during tool-free text generation
- Short enough to catch problems before users notice stale state
- Matches existing session staleness heuristics

## Future Enhancements

- Add "last healthy" timestamp to report for diagnostics
- Consider exponential backoff on retry button
- Emit system notification if hooks stale for >5 minutes
