---
name: claude-hud-swiftui
description: Project-specific SwiftUI patterns learned from building Claude HUD. Use when working on animations, drag-and-drop, window interactions, or modal transitions in this codebase.
---

# Claude HUD SwiftUI Patterns

Hard-won patterns specific to this macOS SwiftUI app. These address edge cases and pitfalls discovered during development.

## NSViewRepresentable Window Dragging

**Problem:** `Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)` wrapped in NSViewRepresentable breaks layout—`maxHeight: .infinity` propagates through NSHostingView differently than pure SwiftUI.

**Solution:** Use native macOS window dragging, surgically disable on specific elements.

```swift
// In App.swift / WindowGroup configuration
window.isMovableByWindowBackground = true

// Only prevent on elements that need drag-and-drop
final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct PreventWindowDrag<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NonDraggableHostingView<Content> {
        NonDraggableHostingView(rootView: content)
    }

    func updateNSView(_ nsView: NonDraggableHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
}

extension View {
    func preventWindowDrag() -> some View {
        PreventWindowDrag(content: self)
    }
}

// Usage on draggable cards
ProjectCardView(...)
    .preventWindowDrag()
```

**Rule:** Don't fight macOS—use native `isMovableByWindowBackground` and surgically disable on specific elements.

## Hero Transitions with matchedGeometryEffect

**Problem:** Applying `matchedGeometryEffect` to entire view hierarchies with different content structures causes jittery animations—SwiftUI can't interpolate between incompatible layouts.

**Solution:** Match only the container shape, crossfade the content.

```swift
@Namespace private var namespace
@State private var isExpanded = false

ZStack(alignment: .topLeading) {
    // Background shape morphs (position, size, corner radius)
    RoundedRectangle(cornerRadius: isExpanded ? 12 : 10, style: .continuous)
        .fill(isExpanded ? Color.card : Color.white.opacity(0.05))
        .matchedGeometryEffect(id: "container", in: namespace)

    // Content crossfades (no matchedGeometryEffect)
    if isExpanded {
        expandedContent
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    } else {
        collapsedContent
            .transition(.opacity)
    }
}
.animation(.spring(response: 0.4, dampingFraction: 0.85), value: isExpanded)
```

**Why:** The background shape has consistent geometry (just different sizes), so SwiftUI interpolates smoothly. Content with incompatible structures simply crossfades.

## Origin-Based Modal Animation

Animate a modal expanding from (and collapsing to) a specific trigger location.

**Key challenges solved:**
- `onChange(of:)` doesn't fire on initial mount—need `onAppear` for initial state
- Conditional rendering (`if isPresented`) removes view immediately—no exit animation
- Nested `scaleEffect` with different anchors conflict

```swift
// 1. Named coordinate space at container level
ContentView()
    .coordinateSpace(name: "container")

// 2. Capture trigger frame in that space
Button(action: { action(buttonFrame) }) { ... }
    .background(GeometryReader { geo in
        Color.clear.preference(key: FramePreferenceKey.self,
                               value: geo.frame(in: .named("container")))
    })
    .onPreferenceChange(FramePreferenceKey.self) { buttonFrame = $0 }

// 3. Modal: separate visibility state from animation state
@State private var isVisible = false    // Tree presence
@State private var animatedIn = false   // Animation driver

var anchorPoint: UnitPoint {
    guard let origin = originFrame, origin != .zero else { return .center }
    return UnitPoint(x: origin.midX / containerSize.width,
                     y: origin.midY / containerSize.height)
}

var body: some View {
    ZStack {
        if isVisible {
            content
                .scaleEffect(animatedIn ? 1 : 0.3, anchor: anchorPoint)
                .opacity(animatedIn ? 1 : 0)
        }
    }
    .onAppear {
        if isPresented {
            isVisible = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                animatedIn = true
            }
        }
    }
    .onChange(of: isPresented) { _, show in
        if show {
            isVisible = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                animatedIn = true
            }
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                animatedIn = false
            } completion: {
                isVisible = false
            }
        }
    }
}
```

**Why:** `isVisible` keeps view in tree during exit animation. `animatedIn` provides state that changes (unlike `isPresented` already true on mount). `completion:` sequences removal after animation finishes.

## Blur and Clip Modifier Order

**Problem:** Content with blur applied extends beyond rounded corners.

**Why:** Gaussian blur samples neighboring pixels, expanding rendered area beyond original bounds. Clip applied *before* blur constrains input, but blur output still extends past boundary.

```swift
// Wrong - blur extends beyond clip
.clipShape(RoundedRectangle(cornerRadius: 22))
.blur(radius: 8)

// Correct - blur output is trimmed
.blur(radius: 8)
.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
```

**Caveat:** `.ignoresSafeArea()` can override ancestor clip shapes. Check for safe area modifiers on child views if content still pokes out corners.

## Overlay Technique for Drag-and-Drop Reordering

**Problem:** SwiftUI's `.animation()` modifier conflicts with imperative `DragGesture` control. Both systems fight—causing jitter, bouncing, erratic behavior.

**Solution:** Render dragged item in separate overlay layer, isolated from list's animation system.

```swift
@State private var draggingId: String?
@State private var dragPosition: CGPoint = .zero
@State private var containerFrame: CGRect = .zero
@State private var isAnimatingRelease = false

var body: some View {
    ZStack(alignment: .topLeading) {
        // Layer 1: The list (items animate freely)
        listContent
            .background(GeometryReader { geo in
                Color.clear.onAppear { containerFrame = geo.frame(in: .global) }
            })

        // Layer 2: Dragged item overlay (follows cursor directly)
        if let item = draggingItem {
            ItemRow(item: item)
                .frame(height: rowHeight)
                .scaleEffect(isAnimatingRelease ? 1.0 : 1.03)
                .shadow(color: .black.opacity(isAnimatingRelease ? 0 : 0.3),
                        radius: isAnimatingRelease ? 0 : 12, y: 4)
                .position(x: containerFrame.width / 2,
                          y: dragPosition.y - containerFrame.minY)
                .animation(.spring(response: 0.3, dampingFraction: 1.0), value: dragPosition)
                .allowsHitTesting(false)
        }
    }
}

private var listContent: some View {
    VStack(spacing: rowSpacing) {
        ForEach(items) { item in
            ItemRow(item: item)
                .opacity(draggingId == item.id ? 0 : 1)  // Hide original
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { handleDrag(item: item, position: $0.location) }
                    .onEnded { _ in handleDragEnd() })
        }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: items.map(\.id))
}

private func handleDragEnd() {
    guard let id = draggingId else { return }
    let targetIndex = items.firstIndex { $0.id == id } ?? 0
    let targetY = containerFrame.minY + (CGFloat(targetIndex) * (rowHeight + rowSpacing)) + (rowHeight / 2)

    isAnimatingRelease = true
    dragPosition = CGPoint(x: dragPosition.x, y: targetY)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        draggingId = nil
        dragPosition = .zero
        isAnimatingRelease = false
    }
}
```

**Why:** List items use `.animation()` (declarative). Overlay item uses `.position()` following cursor (imperative). No conflict because they're in separate layers.

**macOS caveat:** When `window.isMovableByWindowBackground = true`, wrap draggable content with the `PreventWindowDrag` modifier from above.
