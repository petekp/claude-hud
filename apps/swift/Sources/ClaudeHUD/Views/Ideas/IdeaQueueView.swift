import SwiftUI

struct IdeaQueueView: View {
    let ideas: [Idea]
    let isGeneratingTitle: (String) -> Bool
    var onTapIdea: ((Idea) -> Void)?
    var onReorder: (([Idea]) -> Void)?
    var onRemove: ((Idea) -> Void)?

    @State private var localIdeas: [Idea] = []

    private var queuedIdeas: [Idea] {
        localIdeas.filter { $0.status != "done" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queuedIdeas.isEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .onAppear {
            localIdeas = ideas
        }
        .onChange(of: ideas) { _, newValue in
            localIdeas = newValue
        }
    }

    private var queueList: some View {
        VStack(spacing: 8) {
            ForEach(Array(queuedIdeas.enumerated()), id: \.element.id) { index, idea in
                IdeaQueueRow(
                    idea: idea,
                    isFirst: index == 0,
                    isGeneratingTitle: isGeneratingTitle(idea.id),
                    onTap: { onTapIdea?(idea) },
                    onRemove: onRemove != nil ? { onRemove?(idea) } : nil
                )
                .onDrag {
                    NSItemProvider(object: idea.id as NSString)
                }
                .onDrop(of: [.text], delegate: IdeaDropDelegate(
                    item: idea,
                    items: $localIdeas,
                    onReorder: onReorder
                ))
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No ideas in queue")
                .font(AppTypography.body)
                .foregroundColor(.white.opacity(0.5))

            Text("Hover over the project card and click \"+ Idea\" to add one")
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ideaRowBackground(isFirst: false, isHovered: false))
    }
}

// MARK: - Queue Row

struct IdeaQueueRow: View {
    let idea: Idea
    let isFirst: Bool
    let isGeneratingTitle: Bool
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            dragHandle

            titleArea
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered && !isGeneratingTitle {
                hoverActions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ideaRowBackground(isFirst: isFirst, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(idea.title)
        .accessibilityHint(isFirst ? "Top of queue - next to work on" : "Drag to reorder")
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(isHovered ? 0.5 : 0.25))
            .frame(width: 16)
    }

    private var titleArea: some View {
        ZStack(alignment: .leading) {
            Text(idea.title)
                .font(isFirst ? AppTypography.body.weight(.medium) : AppTypography.body)
                .foregroundColor(.white.opacity(isFirst ? 0.9 : 0.7))
                .lineLimit(2)
                .opacity(isGeneratingTitle ? 0 : 1)

            if isGeneratingTitle {
                ShimmeringText(text: "Processing...")
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isGeneratingTitle)
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 6) {
            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Remove idea")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: - Row Background

@ViewBuilder
private func ideaRowBackground(isFirst: Bool, isHovered: Bool) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.hudCard.opacity(isFirst ? 1.0 : 0.7))

        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(isHovered ? 0.15 : (isFirst ? 0.1 : 0.06)),
                        .white.opacity(isHovered ? 0.08 : (isFirst ? 0.05 : 0.03))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )

        if isFirst {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.06), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Drop Delegate

private struct IdeaDropDelegate: DropDelegate {
    let item: Idea
    @Binding var items: [Idea]
    var onReorder: (([Idea]) -> Void)?

    func performDrop(info: DropInfo) -> Bool {
        onReorder?(items)
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedId = info.itemProviders(for: [.text]).first else { return }

        draggedId.loadObject(ofClass: NSString.self) { reading, _ in
            guard let id = reading as? String else { return }

            DispatchQueue.main.async {
                guard let fromIndex = items.firstIndex(where: { $0.id == id }),
                      let toIndex = items.firstIndex(where: { $0.id == item.id }),
                      fromIndex != toIndex else { return }

                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
