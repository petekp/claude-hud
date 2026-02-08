import AppKit
import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @ObservedObject private var glassConfig = GlassConfig.shared
    @State private var pausedCollapsed = true
    @State private var draggedProject: Project?
    #if DEBUG
        @AppStorage("debugShowProjectListDiagnostics") private var debugShowProjectListDiagnostics = true
    #endif

    private var orderedProjects: [Project] {
        appState.orderedProjects(appState.projects)
    }

    private var activeProjects: [Project] {
        orderedProjects.filter { project in
            !appState.isManuallyDormant(project)
        }
    }

    private var pausedProjects: [Project] {
        orderedProjects.filter { project in
            appState.isManuallyDormant(project)
        }
    }

    private func isStale(_ project: Project) -> Bool {
        let state = appState.getSessionState(for: project)
        return SessionStaleness.isReadyStale(state: state?.state, stateChangedAt: state?.stateChangedAt)
    }

    var body: some View {
        // Capture layout values once at body evaluation to avoid constraint loops
        // (same pattern as DockLayoutView crash fix)
        let cardListSpacing = glassConfig.cardListSpacingRounded
        let listHorizontalPadding = glassConfig.listHorizontalPaddingRounded
        let contentTopPadding: CGFloat = floatingMode ? 56 : 12
        let contentBottomPadding: CGFloat = floatingMode ? 64 : 8
        let edgeFadeHeight: CGFloat = floatingMode ? 30 : 0
        let topFade = contentTopPadding + edgeFadeHeight
        let bottomFade = contentBottomPadding + edgeFadeHeight

        let preferredScrollbarWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        let expandedScrollbarWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let maskScrollbarWidth = ScrollMaskLayout.scrollbarMaskWidth(
            preferredWidth: preferredScrollbarWidth,
            expandedWidth: expandedScrollbarWidth,
        )
        let contentTrailingPadding = ScrollMaskLayout.contentTrailingPadding(
            basePadding: listHorizontalPadding,
            scrollbarMaskWidth: maskScrollbarWidth,
        )
        let scrollbarInset = floatingMode ? WindowCornerRadius.value(floatingMode: floatingMode) : 0

        ScrollView {
            ScrollViewReader { scrollProxy in
                LazyVStack(spacing: cardListSpacing) {
                    #if DEBUG
                        if debugShowProjectListDiagnostics {
                            DebugActiveStateCard()
                                .padding(.bottom, 6)
                            DebugActivationTraceCard()
                                .padding(.bottom, 6)
                        }
                    #endif
                    // Setup status card - show regardless of project state
                    if let diagnostic = appState.hookDiagnostic, diagnostic.shouldShowSetupCard {
                        SetupStatusCard(
                            diagnostic: diagnostic,
                            onFix: { appState.fixHooks() },
                            onRefresh: {
                                appState.checkHookDiagnostic()
                                appState.refreshSessionStates()
                            },
                            onTest: { appState.testHooks() },
                        )
                        .padding(.bottom, 4)
                    }

                    if appState.isLoading {
                        VStack(spacing: 8) {
                            SkeletonCard()
                            SkeletonCard()
                            SkeletonCard()
                        }
                        .padding(.top, 8)
                    } else if appState.projects.isEmpty {
                        EmptyProjectsView()
                    } else {
                        if appState.isProjectCreationEnabled {
                            ActivityPanel()
                        }

                        if !activeProjects.isEmpty {
                            SectionHeader(
                                title: "In Progress",
                                count: activeProjects.count,
                            )
                            .padding(.top, 4)
                            .transition(.opacity)

                            ForEach(Array(activeProjects.enumerated()), id: \.element.path) { index, project in
                                activeProjectCard(project: project, index: index)
                            }
                        }

                        if !pausedProjects.isEmpty {
                            PausedSectionHeader(
                                count: pausedProjects.count,
                                isCollapsed: pausedCollapsed,
                                onToggle: {
                                    let expanding = pausedCollapsed
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        pausedCollapsed.toggle()
                                    }
                                    if expanding {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                scrollProxy.scrollTo("scroll-end", anchor: .bottom)
                                            }
                                        }
                                    }
                                },
                            )
                            .padding(.top, activeProjects.isEmpty ? 4 : 12)
                            .transition(.opacity)

                            if !pausedCollapsed {
                                VStack(spacing: 0) {
                                    ForEach(Array(pausedProjects.enumerated()), id: \.element.path) { index, project in
                                        pausedProjectCard(project: project, index: index)
                                    }
                                    // Anchor inside the eager VStack so it's always materialized
                                    // when the section is expanded (LazyVStack won't defer it)
                                    Color.clear.frame(height: 1).id("scroll-end")
                                }
                            }
                        }
                    }
                }
                .padding(.leading, listHorizontalPadding)
                .padding(.trailing, contentTrailingPadding)
                .padding(.top, contentTopPadding)
                .padding(.bottom, contentBottomPadding)
                .onChange(of: pausedProjects.count) { oldCount, newCount in
                    if newCount > oldCount, pausedCollapsed {
                        withAnimation(.spring(response: glassConfig.sectionToggleSpringResponse, dampingFraction: 0.85)) {
                            pausedCollapsed = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.spring(response: glassConfig.sectionToggleSpringResponse, dampingFraction: 0.85)) {
                                scrollProxy.scrollTo("scroll-end", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .mask {
            GeometryReader { proxy in
                let sizes = ScrollMaskLayout.sizes(
                    totalWidth: proxy.size.width,
                    scrollbarWidth: maskScrollbarWidth,
                )

                HStack(spacing: 0) {
                    ScrollEdgeFadeMask(
                        topInset: 0,
                        bottomInset: 0,
                        topFade: topFade,
                        bottomFade: bottomFade,
                    )
                    .frame(width: sizes.content, height: proxy.size.height)

                    Color.white
                        .frame(width: sizes.scrollbar, height: proxy.size.height)
                }
            }
        }
        .background(
            ScrollViewScrollerInsetsConfigurator(
                topInset: scrollbarInset,
                bottomInset: scrollbarInset,
            ),
        )
        .background(floatingMode ? Color.clear : Color.hudBackground)
    }

    @ViewBuilder
    private func activeProjectCard(project: Project, index: Int) -> some View {
        let canShowDetails = appState.isProjectDetailsEnabled
        let canCaptureIdeas = appState.isIdeaCaptureEnabled

        ProjectCardView(
            project: project,
            sessionState: appState.getSessionState(for: project),
            projectStatus: appState.getProjectStatus(for: project),
            flashState: appState.isFlashing(project),
            isStale: isStale(project),
            isActive: appState.activeProjectPath == project.path,
            onTap: {
                appState.launchTerminal(for: project)
            },
            onInfoTap: canShowDetails ? { appState.showProjectDetail(project) } : nil,
            onMoveToDormant: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    appState.moveToDormant(project)
                }
            },
            onCaptureIdea: canCaptureIdeas ? { frame in appState.showIdeaCaptureModal(for: project, from: frame) } : nil,
            onRemove: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    appState.removeProject(project.path)
                }
            },
            onDragStarted: {
                draggedProject = project
                return NSItemProvider(object: project.path as NSString)
            },
            isDragging: draggedProject?.path == project.path,
        )
        .activeProjectCardModifiers(
            project: project,
            index: index,
            activeProjects: activeProjects,
            draggedProject: $draggedProject,
            appState: appState,
            glassConfig: glassConfig,
        )
    }

    private func pausedProjectCard(project: Project, index: Int) -> some View {
        CompactProjectCardView(
            project: project,
            onTap: {
                appState.launchTerminal(for: project)
            },
            onInfoTap: appState.isProjectDetailsEnabled ? { appState.showProjectDetail(project) } : nil,
            onMoveToRecent: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    appState.moveToRecent(project)
                }
            },
            onRemove: {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    appState.removeProject(project.path)
                }
            },
            showSeparator: index < pausedProjects.count - 1,
        )
        .pausedProjectCardModifiers(
            project: project,
            index: index,
            glassConfig: glassConfig,
        )
    }
}

// MARK: - Card Modifier Extensions (extracted for type-checker)

private extension View {
    func activeProjectCardModifiers(
        project: Project,
        index: Int,
        activeProjects: [Project],
        draggedProject: Binding<Project?>,
        appState: AppState,
        glassConfig: GlassConfig,
    ) -> some View {
        preventWindowDrag()
            .zIndex(draggedProject.wrappedValue?.path == project.path ? 999 : 0)
            .id("active-\(project.path)")
            .onDrop(
                of: [.text],
                delegate: ProjectDropDelegate(
                    project: project,
                    activeProjects: activeProjects,
                    draggedProject: draggedProject,
                    appState: appState,
                ),
            )
            .transition(.asymmetric(
                insertion: .opacity
                    .combined(with: .scale(scale: 0.96))
                    .combined(with: .offset(y: -8))
                    .animation(.spring(response: glassConfig.cardInsertSpringResponse, dampingFraction: glassConfig.cardInsertSpringDamping).delay(Double(index) * glassConfig.cardInsertStagger)),
                removal: .opacity
                    .combined(with: .scale(scale: 0.94))
                    .animation(.easeOut(duration: glassConfig.cardRemovalDuration)),
            ))
    }

    func pausedProjectCardModifiers(
        project: Project,
        index: Int,
        glassConfig: GlassConfig,
    ) -> some View {
        id("paused-\(project.path)")
            .transition(.asymmetric(
                insertion: .opacity
                    .combined(with: .scale(scale: 0.97))
                    .animation(.spring(response: glassConfig.cardInsertSpringResponse * 0.8, dampingFraction: glassConfig.cardInsertSpringDamping).delay(Double(index) * glassConfig.pausedCardStagger)),
                removal: .opacity
                    .combined(with: .scale(scale: 0.95))
                    .animation(.easeOut(duration: glassConfig.cardRemovalDuration * 0.8)),
            ))
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(AppTypography.label.weight(.medium))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.45))

            if count > 1 {
                Text("(\(count))")
                    .font(AppTypography.badge)
                    .foregroundColor(.white.opacity(0.25))
            }

            Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) section, \(count) \(count == 1 ? "project" : "projects")")
    }
}

struct PausedSectionHeader: View {
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text("HIDDEN")
                    .font(AppTypography.label.weight(.medium))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.45))

                if count > 1 {
                    Text("(\(count))")
                        .font(AppTypography.badge)
                        .foregroundColor(.white.opacity(0.25))
                }

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(AppTypography.captionSmall.weight(.semibold))
                    .foregroundColor(.white.opacity(isHovered ? 0.45 : 0.25))

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hidden projects section, \(count) \(count == 1 ? "project" : "projects")")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Double-tap to expand" : "Double-tap to collapse")
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct EmptyProjectsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @State private var appeared = false
    @State private var isButtonHovered = false

    var body: some View {
        contentView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Draggable area behind content - won't block button clicks
                if floatingMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .windowDraggable()
                }
            }
    }

    private var contentView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.hudAccent.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                    .scaleEffect(appeared || reduceMotion ? 1.0 : 0.5)
                    .opacity(appeared || reduceMotion ? 1 : 0)

                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom,
                        ),
                    )
                    .scaleEffect(appeared || reduceMotion ? 1.0 : 0.8)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Drag folders here")
                    .font(AppTypography.cardSubtitle.weight(.semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text("or use the button below to get started")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)

            if !appState.suggestedProjects.isEmpty {
                suggestedProjectsSection
                    .opacity(appeared || reduceMotion ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 12)
            }

            Button(action: { appState.showAddProject() }) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(AppTypography.labelMedium.weight(.semibold))
                    Text("Link Project")
                        .font(AppTypography.bodySecondary.weight(.semibold))
                }
                .foregroundColor(.white.opacity(isButtonHovered ? 1 : 0.9))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [
                            Color.hudAccent.opacity(isButtonHovered ? 0.9 : 0.7),
                            Color.hudAccentDark.opacity(isButtonHovered ? 0.8 : 0.6),
                        ],
                        startPoint: .top,
                        endPoint: .bottom,
                    ),
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isButtonHovered ? 0.2 : 0.1), lineWidth: 0.5),
                )
                .shadow(color: Color.hudAccent.opacity(isButtonHovered ? 0.4 : 0.2), radius: isButtonHovered && !reduceMotion ? 10 : 4, y: 2)
                .scaleEffect(isButtonHovered && !reduceMotion ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Link project")
            .accessibilityHint("Opens a folder picker to link an existing project directory")
            .onHover { hovering in
                withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.25, dampingFraction: 0.7)) {
                    isButtonHovered = hovering
                }
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 15)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.hudAccent.opacity(0.03)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6]),
                )
                .foregroundColor(Color.hudAccent.opacity(0.25)),
        )
        .padding(.horizontal, 24)
        .padding(.top, 50)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone for project folders")
        .onAppear {
            if appState.suggestedProjects.isEmpty {
                appState.refreshSuggestedProjects()
            }
            if !reduceMotion {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
    }

    private var suggestedProjectsSection: some View {
        let suggestions = Array(appState.suggestedProjects.prefix(3))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggested from Claude history")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Button("Dismiss") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        appState.dismissSuggestedProjects()
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .buttonStyle(.plain)
            }

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.path) { suggestion in
                    suggestedProjectRow(suggestion)
                }
            }

            if appState.suggestedProjects.count > suggestions.count {
                Text("+\(appState.suggestedProjects.count - suggestions.count) more in ~/.claude/projects")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5),
        )
    }

    private func suggestedProjectRow(_ suggestion: SuggestedProject) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))

                Text(suggestion.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    badge(text: "\(suggestion.taskCount) sessions")
                    badge(text: suggestion.hasClaudeMd ? "CLAUDE.md" : "No CLAUDE.md")
                }
            }

            Spacer()

            Button("Add") {
                appState.addSuggestedProject(suggestion)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.hudAccent.opacity(0.7)),
            )
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.02)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5),
        )
    }

    private func badge(text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06)),
            )
    }
}

struct ProjectCardDragPreview: View {
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(AppTypography.labelMedium)
                .foregroundColor(.white.opacity(0.5))
            Text(project.name)
                .font(AppTypography.bodyMedium)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.hudCard)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.hudAccent.opacity(0.5), lineWidth: 1),
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

struct ProjectDropDelegate: DropDelegate {
    let project: Project
    let activeProjects: [Project]
    @Binding var draggedProject: Project?
    let appState: AppState

    func dropEntered(info _: DropInfo) {
        guard let draggedProject,
              draggedProject.path != project.path,
              let fromIndex = activeProjects.firstIndex(where: { $0.path == draggedProject.path }),
              let toIndex = activeProjects.firstIndex(where: { $0.path == project.path })
        else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            appState.moveProject(
                from: IndexSet(integer: fromIndex),
                to: toIndex > fromIndex ? toIndex + 1 : toIndex,
                in: activeProjects,
            )
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggedProject = nil
        return true
    }
}
