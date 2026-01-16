# Layout-Specific Animation Tuning Plan

## Goal
Allow separate tuning of animations for vertical layout vs dock layout in the Glass Tuning Panel.

---

## Current Architecture

### GlassConfig (`Theme/GlassConfig.swift`)
- Singleton with 52 `@Published` properties
- Properties grouped into 9 categories:
  - Panel Background (8 props)
  - Card Background (6 props)
  - Material (2 props)
  - Status Colors (13 props)
  - **Ready Ripple (9 props)** ← animations we want to split
  - **Border Glow (7 props)** ← animations we want to split
  - Status Text (4 props)
  - Preview State (1 prop)

### GlassTuningPanel (`GlassTuningPanel.swift`)
- 4-tab structure: Glass, Colors, Effects, Preview
- Effects tab contains Ready Ripple and Border Glow sliders
- No layout awareness currently

### Consumers
- `ProjectCardView.swift` (vertical layout) - uses `ripple*` and `borderGlow*` properties
- `DockProjectCard.swift` (dock layout) - uses same properties via `ProjectCardModifiers`

---

## Implementation Plan

### Step 1: Add Dock-Specific Properties to GlassConfig

Add 16 new properties mirroring the effect properties with `dock` prefix:

```swift
// MARK: - Dock Ready Ripple
@Published var dockRippleMinScale: Double = 0.85
@Published var dockRippleMaxScale: Double = 1.15
@Published var dockRippleMinOpacity: Double = 0.0
@Published var dockRippleMaxOpacity: Double = 0.4
@Published var dockRippleRingCount: Int = 3
@Published var dockRippleRingSpacing: Double = 8.0
@Published var dockRippleBlur: Double = 8.0
@Published var dockRippleDuration: Double = 2.0
@Published var dockRippleEnabled: Bool = true

// MARK: - Dock Border Glow
@Published var dockBorderGlowOpacity: Double = 0.25
@Published var dockBorderGlowBlur: Double = 12.0
@Published var dockBorderGlowWidth: Double = 2.0
@Published var dockBorderGlowPulseMin: Double = 0.6
@Published var dockBorderGlowPulseMax: Double = 1.0
@Published var dockBorderGlowDuration: Double = 1.5
@Published var dockBorderGlowEnabled: Bool = true
```

**File:** `apps/swift/Sources/ClaudeHUD/Theme/GlassConfig.swift`

### Step 2: Add Layout Selector to Effects Tab

Add a segmented picker at the top of the Effects tab:

```swift
@State private var effectsLayoutMode: LayoutMode = .vertical

Picker("Layout", selection: $effectsLayoutMode) {
    Text("Vertical").tag(LayoutMode.vertical)
    Text("Dock").tag(LayoutMode.dock)
}
.pickerStyle(.segmented)
```

Show different sliders based on selection.

**File:** `apps/swift/Sources/ClaudeHUD/Views/Tuning/GlassTuningPanel.swift`

### Step 3: Update Consumers to Use Layout-Aware Properties

Create helper methods or computed properties that return the appropriate values:

```swift
// In GlassConfig
func rippleMaxScale(for layout: LayoutMode) -> Double {
    layout == .dock ? dockRippleMaxScale : rippleMaxScale
}
```

Or pass layout mode to the card modifiers and select properties there.

**Files:**
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardModifiers.swift`
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardGlow.swift`

### Step 4: Update Dock Card to Pass Layout Context

Ensure `DockProjectCard` passes layout information so modifiers know to use dock-specific values.

**File:** `apps/swift/Sources/ClaudeHUD/Views/Projects/DockProjectCard.swift`

---

## Files to Modify

| File | Changes |
|------|---------|
| `Theme/GlassConfig.swift` | Add 16 dock-specific properties |
| `Views/Tuning/GlassTuningPanel.swift` | Add layout selector, conditional sliders |
| `Views/Projects/ProjectCardModifiers.swift` | Layout-aware property access |
| `Views/Projects/ProjectCardGlow.swift` | Layout-aware property access |
| `Views/Projects/DockProjectCard.swift` | Pass layout context if needed |

---

## Verification

1. Build and run: `cd apps/swift && swift build && swift run`
2. Open Glass Tuning Panel (Shift+G in DEBUG)
3. Go to Effects tab
4. Toggle between Vertical and Dock layout selector
5. Adjust ripple/glow parameters for each layout
6. Verify vertical cards use vertical settings
7. Switch to dock mode (⌘2) and verify dock cards use dock settings
8. Confirm parameters persist independently
