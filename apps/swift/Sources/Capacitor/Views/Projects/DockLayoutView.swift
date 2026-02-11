import SwiftUI
import UniformTypeIdentifiers

struct DockLayoutView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    private let glassConfig = GlassConfig.shared
    @State private var scrolledID: String?
    @State private var draggedProject: Project?

    private let cardWidth: CGFloat = 262

    private var nonPausedProjects: [Project] {
        appState.projects.filter { !appState.isManuallyDormant($0) }
    }

    var body: some View {
        // Capture layout values once at body evaluation to avoid constraint loops
        let cardSpacing = glassConfig.dockCardSpacingRounded
        let horizontalPadding = glassConfig.dockHorizontalPaddingRounded
        let sessionStates = appState.sessionStateManager.sessionStates
        let grouped = ProjectOrdering.orderedGroupedProjects(
            nonPausedProjects,
            activeOrder: appState.activeProjectOrder,
            idleOrder: appState.idleProjectOrder,
            sessionStates: sessionStates,
        )
        let activePaths = Set(grouped.active.map(\.path))
        let allProjects = grouped.active + grouped.idle

        GeometryReader { geometry in
            let cardsPerPage = calculateCardsPerPage(width: geometry.size.width, cardSpacing: cardSpacing, horizontalPadding: horizontalPadding)
            let totalPages = max(1, Int(ceil(Double(allProjects.count) / Double(cardsPerPage))))
            let currentPage = calculateCurrentPage(cardsPerPage: cardsPerPage, in: allProjects)

            VStack(spacing: 8) {
                if allProjects.isEmpty {
                    emptyState
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: cardSpacing) {
                            ForEach(allProjects, id: \.path) { project in
                                let sessionState = appState.getSessionState(for: project)
                                let projectStatus = appState.getProjectStatus(for: project)
                                let flashState = appState.isFlashing(project)
                                let isStale = SessionStaleness.isReadyStale(
                                    state: sessionState?.state,
                                    stateChangedAt: sessionState?.stateChangedAt,
                                )
                                projectCard(
                                    for: project,
                                    sessionState: sessionState,
                                    projectStatus: projectStatus,
                                    flashState: flashState,
                                    isStale: isStale,
                                    activePaths: activePaths,
                                    grouped: grouped,
                                )
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $scrolledID)

                    if totalPages > 1 {
                        PageIndicator(currentPage: currentPage, totalPages: totalPages)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project dock")
    }

    private var emptyState: some View {
        ZStack {
            if floatingMode {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .windowDraggable()
            }

            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.4))
                    Text("No active projects")
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func calculateCurrentPage(cardsPerPage: Int, in projects: [Project]) -> Int {
        guard let scrolledID,
              let index = projects.firstIndex(where: { $0.path == scrolledID })
        else {
            return 0
        }
        return index / cardsPerPage
    }

    @ViewBuilder
    private func projectCard(
        for project: Project,
        sessionState: ProjectSessionState?,
        projectStatus: ProjectStatus?,
        flashState: SessionState?,
        isStale: Bool,
        activePaths: Set<String>,
        grouped: (active: [Project], idle: [Project]),
    ) -> some View {
        let isActive = appState.activeProjectPath == project.path
        let canShowDetails = appState.isProjectDetailsEnabled
        let canCaptureIdeas = appState.isIdeaCaptureEnabled
        let group: ActivityGroup = activePaths.contains(project.path) ? .active : .idle
        let groupProjects = group == .active ? grouped.active : grouped.idle

        DockProjectCard(
            project: project,
            sessionState: sessionState,
            projectStatus: projectStatus,
            flashState: flashState,
            isStale: isStale,
            isActive: isActive,
            onTap: {
                appState.launchTerminal(for: project)
            },
            onInfoTap: canShowDetails ? { appState.showProjectDetail(project) } : nil,
            onMoveToDormant: { appState.moveToDormant(project) },
            onCaptureIdea: canCaptureIdeas ? { frame in appState.showIdeaCaptureModal(for: project, from: frame) } : nil,
            onRemove: { appState.removeProject(project.path) },
            onDragStarted: {
                draggedProject = project
                return NSItemProvider(object: project.path as NSString)
            },
            isDragging: draggedProject?.path == project.path,
        )
        .preventWindowDrag()
        .id("\(project.path)-\(appState.sessionStateRevision)")
        .zIndex(draggedProject?.path == project.path ? 999 : 0)
        .onDrop(
            of: [.text, .fileURL],
            delegate: DockDropDelegate(
                project: project,
                groupProjects: groupProjects,
                group: group,
                draggedProject: $draggedProject,
                appState: appState,
            ),
        )
        .scrollTransition { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.8)
                .scaleEffect(phase.isIdentity ? 1 : 0.95)
        }
    }

    private func calculateCardsPerPage(width: CGFloat, cardSpacing: CGFloat, horizontalPadding: CGFloat) -> Int {
        let availableWidth = width - (horizontalPadding * 2)
        let cardWithSpacing = cardWidth + cardSpacing
        return max(1, Int(availableWidth / cardWithSpacing))
    }
}

private struct PageIndicator: View {
    let currentPage: Int
    let totalPages: Int
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< totalPages, id: \.self) { page in
                Circle()
                    .fill(page == currentPage ? Color.white.opacity(0.8) : Color.white.opacity(0.3))
                    .frame(width: page == currentPage ? 8 : 6, height: page == currentPage ? 8 : 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: currentPage)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentPage + 1) of \(totalPages)")
    }
}

// MARK: - Drop Delegate

struct DockDropDelegate: DropDelegate {
    let project: Project
    let groupProjects: [Project]
    let group: ActivityGroup
    @Binding var draggedProject: Project?
    let appState: AppState

    private var isExternalFileDrag: Bool {
        draggedProject == nil
    }

    func dropEntered(info: DropInfo) {
        // External file URL drag (from Finder) → signal ContentView overlay
        if isExternalFileDrag, info.hasItemsConforming(to: [.fileURL]) {
            appState.isFileDragOverCard = true
            return
        }

        // Internal card reorder — only within same group
        guard let draggedProject,
              draggedProject.path != project.path,
              let fromIndex = groupProjects.firstIndex(where: { $0.path == draggedProject.path }),
              let toIndex = groupProjects.firstIndex(where: { $0.path == project.path })
        else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            appState.moveProject(
                from: IndexSet(integer: fromIndex),
                to: toIndex > fromIndex ? toIndex + 1 : toIndex,
                in: groupProjects,
                group: group,
            )
        }
    }

    func dropExited(info _: DropInfo) {
        if isExternalFileDrag {
            appState.isFileDragOverCard = false
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isExternalFileDrag, info.hasItemsConforming(to: [.fileURL]) {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if isExternalFileDrag, info.hasItemsConforming(to: [.fileURL]) {
            appState.isFileDragOverCard = false
            let providers = info.itemProviders(for: [.fileURL])
            appState.handleFileURLDrop(providers)
            return true
        }
        draggedProject = nil
        return true
    }
}

#Preview {
    DockLayoutView()
        .environment(AppState())
        .frame(width: 800, height: 150)
        .preferredColorScheme(.dark)
}
