# Swift App Projects View - Feature Parity Plan

## Overview

Bring the Swift app's Projects view to feature parity with the Tauri implementation. This focuses exclusively on the Projects tab - Artifacts will be addressed later.

**Current State:** Basic project list with static cards and status pills (no interactions, no animations)
**Target State:** Full-featured Projects view matching Tauri's functionality and polish

---

## Feature Gap Analysis

| Feature | Tauri | Swift | Priority |
|---------|:-----:|:-----:|:--------:|
| Card click → launch terminal | ✅ | ❌ | **P0** |
| Info button → detail view | ✅ | ❌ | **P0** |
| Recent/Dormant sections | ✅ | ❌ | **P1** |
| Blocker message (red text) | ✅ | ❌ | **P1** |
| Status breathing animation | ✅ | ❌ | **P1** |
| Flash on state change | ✅ | ❌ | **P1** |
| Compact card for dormant | ✅ | ❌ | **P2** |
| Relative time display | ✅ | ❌ | **P2** |
| Staggered list animations | ✅ | ❌ | **P2** |
| Left accent bar | ✅ | ❌ | **P3** |
| Search/filter | ✅ | ❌ | **P3** |
| Focused project indicator | ✅ | ❌ | **P3** |
| Shimmer effect | ✅ | ❌ | **P3** |

---

## Implementation Plan

### Step 1: Make Cards Interactive (P0)

**Goal:** Cards respond to clicks and navigate

**Files to modify:**
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`
- `apps/swift/Sources/ClaudeHUD/Models/AppState.swift`

**Changes:**

1. **Add terminal launch action to AppState:**
```swift
func launchTerminal(for project: Project) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", """
        SESSION="\(project.name)"
        if tmux has-session -t "$SESSION" 2>/dev/null; then
            tmux switch-client -t "$SESSION"
        else
            tmux new-session -d -s "$SESSION" -c "\(project.path)"
            tmux switch-client -t "$SESSION"
        fi
        osascript -e 'tell application "Terminal" to activate'
    """]
    try? process.run()
}
```

2. **Wrap ProjectCardView in Button:**
```swift
Button(action: { appState.launchTerminal(for: project) }) {
    // existing card content
}
.buttonStyle(.plain)
```

3. **Add info button with navigation:**
```swift
Button(action: { appState.selectedProject = project }) {
    Image(systemName: "info.circle")
}
```

4. **Add ProjectView enum for navigation:**
```swift
enum ProjectView {
    case list
    case detail(Project)
    case add
}
@Published var projectView: ProjectView = .list
```

---

### Step 2: Add Blocker Display (P1)

**Goal:** Show blocker messages in red below summary

**Files to modify:**
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`
- `apps/swift/Sources/ClaudeHUD/Models/AppState.swift` (add projectStatuses)

**Changes:**

1. **Add projectStatuses to AppState:**
```swift
@Published var projectStatuses: [String: ProjectStatus] = [:]

func refreshProjectStatuses() {
    for project in projects {
        if let status = engine?.getProjectStatus(projectPath: project.path) {
            projectStatuses[project.path] = status
        }
    }
}
```

2. **Display blocker in ProjectCardView:**
```swift
if let blocker = projectStatus?.blocker {
    Text(blocker)
        .font(.system(size: 10))
        .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
        .lineLimit(1)
}
```

---

### Step 3: Breathing Status Dot Animation (P1)

**Goal:** Status dot pulses smoothly at 120Hz

**Files to create:**
- `apps/swift/Sources/ClaudeHUD/Views/Components/BreathingDot.swift`

**Files to modify:**
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`

**Implementation:**
```swift
struct BreathingDot: View {
    @State private var isAnimating = false
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(isAnimating ? 0.85 : 1.0)
            .opacity(isAnimating ? 0.6 : 1.0)
            .animation(
                .easeInOut(duration: 1.25)
                .repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear { isAnimating = true }
    }
}
```

Replace static circle in StatusPillView with BreathingDot.

---

### Step 4: Recent/Dormant Sections (P1)

**Goal:** Split projects into "Recent" and "Dormant" sections

**Files to modify:**
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`

**Logic:**
```swift
var recentProjects: [Project] {
    projects.filter { project in
        let state = appState.getSessionState(for: project)
        // Active state OR activity within 24h
        if let s = state?.state, ["working", "ready", "compacting"].contains(s.rawValue) {
            return true
        }
        if let lastActive = project.lastActive,
           let date = ISO8601DateFormatter().date(from: lastActive),
           Date().timeIntervalSince(date) < 86400 {
            return true
        }
        return false
    }
}

var dormantProjects: [Project] {
    projects.filter { !recentProjects.contains($0) }
}
```

**Section header styling:**
```swift
Text("RECENT")
    .font(.system(size: 10, weight: .semibold))
    .tracking(1.5)
    .foregroundColor(.white.opacity(0.4))
```

---

### Step 5: Flash Animation on State Change (P1)

**Goal:** Cards flash when state changes to ready/waiting/compacting

**Files to modify:**
- `apps/swift/Sources/ClaudeHUD/Models/AppState.swift`
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`

**State tracking:**
```swift
@Published var flashingProjects: [String: SessionState] = [:]
private var previousSessionStates: [String: SessionState] = [:]

func checkForStateChanges() {
    for (path, state) in sessionStates {
        let current = state.state
        if let previous = previousSessionStates[path], previous != current {
            if current != .working {
                flashingProjects[path] = current
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    self.flashingProjects.removeValue(forKey: path)
                }
            }
        }
        previousSessionStates[path] = current
    }
}
```

**Flash overlay in card:**
```swift
.overlay(
    RoundedRectangle(cornerRadius: 10)
        .stroke(flashColor, lineWidth: 2)
        .opacity(isFlashing ? 1 : 0)
        .animation(.easeOut(duration: 1.4), value: isFlashing)
)
```

---

### Step 6: Compact Cards for Dormant (P2)

**Goal:** Dormant projects use smaller, simpler cards

**Files to create:**
- `apps/swift/Sources/ClaudeHUD/Views/Projects/CompactProjectCardView.swift`

**Layout:**
```
┌─────────────────────────────────────────┐
│ Project Name                    3h  (i) │
│ Working on context...                   │
└─────────────────────────────────────────┘
```

**Styling:**
- Padding: 10px × 12px (vs 12px × 12px for full)
- Font size: 11px for name (vs 15px)
- No status pill
- Relative time instead of status
- Info button appears on hover

---

### Step 7: Relative Time Display (P2)

**Goal:** Show "3h", "2d", "1w" for last activity

**Files to create:**
- `apps/swift/Sources/ClaudeHUD/Utils/TimeFormatting.swift`

```swift
func relativeTime(from dateString: String?) -> String {
    guard let dateString,
          let date = ISO8601DateFormatter().date(from: dateString) else {
        return "—"
    }
    let seconds = Date().timeIntervalSince(date)
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds/60))m"
    case ..<86400: return "\(Int(seconds/3600))h"
    case ..<604800: return "\(Int(seconds/86400))d"
    case ..<2592000: return "\(Int(seconds/604800))w"
    default: return "\(Int(seconds/2592000))mo"
    }
}
```

---

### Step 8: List Entry Animations (P2)

**Goal:** Cards animate in with staggered timing

**Implementation:**
```swift
ForEach(Array(recentProjects.enumerated()), id: \.element.path) { index, project in
    ProjectCardView(project: project, ...)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        ))
        .animation(
            .spring(response: 0.4, dampingFraction: 0.8)
            .delay(Double(index) * 0.03),
            value: recentProjects.count
        )
}
```

---

### Step 9: Left Accent Bar (P3)

**Goal:** Subtle vertical bar on left side of cards

**Implementation:**
```swift
.overlay(alignment: .leading) {
    Rectangle()
        .fill(Color.white.opacity(isHovered ? 0.4 : 0.15))
        .frame(width: 2)
        .padding(.vertical, 12)
}
```

---

### Step 10: Search Filter (P3)

**Goal:** Filter projects by name

**Files to modify:**
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`

```swift
@State private var searchText = ""

var filteredProjects: [Project] {
    guard !searchText.isEmpty else { return projects }
    return projects.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
    }
}

// In body:
TextField("Search projects...", text: $searchText)
    .textFieldStyle(.plain)
    .padding(8)
    .background(Color.white.opacity(0.05))
    .cornerRadius(6)
```

---

## Files Summary

### New Files
- `apps/swift/Sources/ClaudeHUD/Views/Components/BreathingDot.swift`
- `apps/swift/Sources/ClaudeHUD/Views/Projects/CompactProjectCardView.swift`
- `apps/swift/Sources/ClaudeHUD/Utils/TimeFormatting.swift`

### Modified Files
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`
- `apps/swift/Sources/ClaudeHUD/Models/AppState.swift`
- `apps/swift/Sources/ClaudeHUD/Theme/Colors.swift` (add flash colors)

---

## Verification

After each step, verify in the running Swift app:

1. **Step 1:** Click card → terminal opens with tmux session. Click info → navigates.
2. **Step 2:** Projects with blockers show red text.
3. **Step 3:** Status dots pulse smoothly (check 120Hz in Instruments).
4. **Step 4:** Projects split into Recent/Dormant sections correctly.
5. **Step 5:** Change a project's state → card flashes briefly.
6. **Step 6:** Dormant projects use compact layout.
7. **Step 7:** Compact cards show relative time ("3h ago").
8. **Step 8:** Open app → cards animate in with stagger.
9. **Step 9:** Cards have subtle left accent bar.
10. **Step 10:** Type in search → filters projects.

**Build commands:**
```bash
# Rebuild Rust library (if needed)
cd /Users/petepetrash/Code/claude-hud && cargo build --release

# Build and run Swift app
cd /Users/petepetrash/Code/claude-hud/apps/swift && swift run
```

---

## Design Reference

### Color Palette (from Tauri)
```swift
// Status colors (HSB)
ready:      hue: 145°, sat: 75%, bright: 70%  // Green
working:    hue: 45°,  sat: 65%, bright: 75%  // Orange
waiting:    hue: 85°,  sat: 70%, bright: 80%  // Yellow-green
compacting: hue: 55°,  sat: 55%, bright: 70%  // Tan

// Flash glow colors (with opacity)
readyFlash:     same as ready, 25% opacity
waitingFlash:   same as waiting, 25% opacity
compactingFlash: same as compacting, 20% opacity
```

### Typography Scale
```swift
projectName:     17px, semibold
compactName:     11px, semibold
sessionSummary:  13px, regular
blocker:         10px, regular (red)
statusPill:      9px, bold, uppercase
sectionHeader:   10px, semibold, uppercase, 1.5px tracking
relativeTime:    10px, regular, 40% opacity
```

### Animation Timing
```swift
breathing:    1.25s ease-in-out, infinite
flash:        1.4s ease-out, once
listStagger:  30ms between items
spring:       response 0.4, damping 0.8
```
