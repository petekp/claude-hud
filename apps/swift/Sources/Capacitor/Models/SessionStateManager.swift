import Foundation

/// Manages session state display for projects.
///
/// This is a "dumb" client that:
/// - Caches states from the Rust engine
/// - Detects state changes for flash animations
/// - Provides state to views (direct passthrough)
///
/// All state logic (staleness, lock detection, resolution) lives in Rust.
@Observable
@MainActor
final class SessionStateManager {
    private struct ProjectMatchInfo {
        let project: Project
        let normalizedPath: String
        let depth: Int
        let repoInfo: GitRepositoryInfo?
        let workspaceId: String
    }

    private struct StateMatchInfo {
        let state: DaemonProjectState
        let normalizedPath: String
        let repoInfo: GitRepositoryInfo?
        let workspaceId: String
    }

    private enum MatchPriority: Int {
        case repoFallback = 0
        case direct = 1
    }

    private struct BestProjectState {
        let state: DaemonProjectState
        let priority: MatchPriority
    }

    private enum Constants {
        static let flashDurationSeconds: TimeInterval = 1.4
        static let emptySnapshotCommitThreshold = 2
    }

    @ObservationIgnored var onVisualStateChanged: (() -> Void)?

    private(set) var sessionStates: [String: ProjectSessionState] = [:] {
        didSet {
            guard sessionStates != oldValue else { return }
            onVisualStateChanged?()
        }
    }

    private(set) var flashingProjects: [String: SessionState] = [:] {
        didSet {
            guard flashingProjects != oldValue else { return }
            onVisualStateChanged?()
        }
    }

    private var previousSessionStates: [String: SessionState] = [:]
    private var consecutiveEmptySnapshotCount = 0

    private let daemonClient: DaemonClient
    private var daemonRefreshTask: _Concurrency.Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    init(daemonClient: DaemonClient = .shared) {
        self.daemonClient = daemonClient
    }

    // MARK: - Refresh

    func refreshSessionStates(for projects: [Project]) {
        refreshGeneration &+= 1
        let requestGeneration = refreshGeneration
        let daemonEnabled = daemonClient.isEnabled
        DebugLog.write("SessionStateManager.refresh daemonEnabled=\(daemonEnabled) projects=\(projects.count)")

        guard daemonEnabled else {
            DebugLog.write("SessionStateManager.refresh daemonEnabled=false clearingStates")
            consecutiveEmptySnapshotCount = 0
            sessionStates = [:]
            pruneCachedStates()
            return
        }

        // Daemon is the single source of truth. Keep prior state until refreshed
        // to avoid flicker if the daemon request is delayed.
        DebugLog.write("SessionStateManager.refresh daemonEnabled=true existingStates=\(sessionStates.count)")
        checkForStateChanges()

        daemonRefreshTask?.cancel()
        let daemonClient = daemonClient
        daemonRefreshTask = _Concurrency.Task.detached { [weak self] in
            guard let self else { return }
            do {
                let daemonProjects = try await daemonClient.fetchProjectStates()
                if _Concurrency.Task.isCancelled {
                    await MainActor.run {
                        DebugLog.write("SessionStateManager.refresh drop canceled generation=\(requestGeneration)")
                    }
                    return
                }
                let merged = mergeDaemonProjectStates(daemonProjects, projects: projects)
                await MainActor.run {
                    guard !_Concurrency.Task.isCancelled else {
                        DebugLog.write("SessionStateManager.refresh drop canceled-before-apply generation=\(requestGeneration)")
                        return
                    }
                    guard requestGeneration == self.refreshGeneration else {
                        DebugLog.write(
                            "SessionStateManager.refresh drop stale generation=\(requestGeneration) current=\(self.refreshGeneration)",
                        )
                        return
                    }
                    let stabilized = self.stabilizeEmptyDaemonSnapshotIfNeeded(merged)
                    DebugLog.write("SessionStateManager.fetchProjectStates success count=\(daemonProjects.count)")
                    if !merged.isEmpty {
                        let summary = merged
                            .map { "\($0.key) state=\($0.value.state) updated=\($0.value.updatedAt ?? "nil") session=\($0.value.sessionId ?? "nil")" }
                            .sorted()
                            .joined(separator: " | ")
                        DebugLog.write("SessionStateManager.merge summary=\(summary)")
                    } else {
                        DebugLog.write("SessionStateManager.merge summary=empty")
                    }
                    let didChange = stabilized != self.sessionStates
                    if didChange {
                        self.sessionStates = stabilized
                    }
                    self.pruneCachedStates()
                    #if DEBUG
                        DiagnosticsSnapshotLogger.maybeCaptureStuckSessions(sessionStates: stabilized)
                    #endif
                    if didChange {
                        self.checkForStateChanges()
                    }
                }
            } catch {
                await MainActor.run {
                    if _Concurrency.Task.isCancelled {
                        DebugLog.write("SessionStateManager.fetchProjectStates canceled generation=\(requestGeneration)")
                        return
                    }
                    if requestGeneration != self.refreshGeneration {
                        DebugLog.write(
                            "SessionStateManager.fetchProjectStates stale-error generation=\(requestGeneration) current=\(self.refreshGeneration)",
                        )
                        return
                    }
                    DebugLog.write("SessionStateManager.fetchProjectStates error=\(error)")
                }
                return
            }
        }
    }

    private func stabilizeEmptyDaemonSnapshotIfNeeded(
        _ merged: [String: ProjectSessionState],
    ) -> [String: ProjectSessionState] {
        if merged.isEmpty {
            guard !sessionStates.isEmpty else {
                consecutiveEmptySnapshotCount = 0
                logEmptySnapshotDecision(
                    decision: "commit_empty_no_existing_state",
                    mergedCount: merged.count,
                    stabilizedCount: merged.count,
                )
                return merged
            }

            consecutiveEmptySnapshotCount += 1
            if consecutiveEmptySnapshotCount < Constants.emptySnapshotCommitThreshold {
                logEmptySnapshotDecision(
                    decision: "hold_empty_snapshot",
                    mergedCount: merged.count,
                    stabilizedCount: sessionStates.count,
                )
                return sessionStates
            }

            logEmptySnapshotDecision(
                decision: "commit_empty_snapshot",
                mergedCount: merged.count,
                stabilizedCount: merged.count,
            )
            consecutiveEmptySnapshotCount = 0
            return merged
        }

        let hadPendingEmptyHold = consecutiveEmptySnapshotCount > 0
        consecutiveEmptySnapshotCount = 0
        if hadPendingEmptyHold {
            logEmptySnapshotDecision(
                decision: "commit_non_empty_reset_hold",
                mergedCount: merged.count,
                stabilizedCount: merged.count,
            )
        }
        return merged
    }

    private func logEmptySnapshotDecision(
        decision: String,
        mergedCount: Int,
        stabilizedCount: Int,
    ) {
        let existingCount = sessionStates.count
        DebugLog.write(
            "SessionStateManager.emptySnapshot decision=\(decision) consecutiveEmpty=\(consecutiveEmptySnapshotCount) mergedCount=\(mergedCount) existingCount=\(existingCount) appliedCount=\(stabilizedCount)",
        )
        Telemetry.emit(
            "session_state_empty_snapshot",
            decision,
            payload: [
                "decision": decision,
                "consecutive_empty_count": consecutiveEmptySnapshotCount,
                "merged_count": mergedCount,
                "existing_count": existingCount,
                "applied_count": stabilizedCount,
            ],
        )
    }

    // MARK: - Flash Animation

    private func checkForStateChanges() {
        for (path, sessionState) in sessionStates {
            let current = sessionState.state
            if let previous = previousSessionStates[path], previous != current {
                triggerFlashIfNeeded(for: path, state: current)
            }
            previousSessionStates[path] = current
        }
    }

    private func pruneCachedStates() {
        let active = Set(sessionStates.keys)
        previousSessionStates = previousSessionStates.filter { active.contains($0.key) }
        flashingProjects = flashingProjects.filter { active.contains($0.key) }
    }

    private func triggerFlashIfNeeded(for path: String, state: SessionState) {
        switch state {
        case .ready, .waiting, .compacting:
            flashingProjects[path] = state
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.flashDurationSeconds) { [weak self] in
                self?.flashingProjects.removeValue(forKey: path)
            }
        case .working, .idle:
            break
        }
    }

    func isFlashing(_ project: Project) -> SessionState? {
        flashingProjects[project.path]
    }

    // MARK: - State Retrieval

    func getSessionState(for project: Project) -> ProjectSessionState? {
        if let direct = sessionStates[project.path] {
            return direct
        }

        let normalizedPath = PathNormalizer.normalize(project.path)
        return sessionStates.first(where: { PathNormalizer.normalize($0.key) == normalizedPath })?.value
    }

    private nonisolated func mergeDaemonProjectStates(
        _ states: [DaemonProjectState],
        projects: [Project],
    ) -> [String: ProjectSessionState] {
        let homeNormalized = PathNormalizer.normalize(NSHomeDirectory())
        var projectInfos: [ProjectMatchInfo] = []
        var seen: Set<String> = []

        for project in projects {
            let normalized = PathNormalizer.normalize(project.path)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            let depth = normalized.split(separator: "/").count
            let repoInfo = GitRepositoryInfo.resolve(for: project.path)
            let workspaceId = repoInfo.map { WorkspaceIdentity.fromGitInfo($0) }
                ?? WorkspaceIdentity.fromPath(project.path)
            projectInfos.append(
                ProjectMatchInfo(
                    project: project,
                    normalizedPath: normalized,
                    depth: depth,
                    repoInfo: repoInfo,
                    workspaceId: workspaceId,
                ),
            )
        }

        let sortedProjects = projectInfos.sorted { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.normalizedPath > rhs.normalizedPath
            }
            return lhs.depth > rhs.depth
        }

        // Index pinned projects by repo identity so we can map daemon activity anywhere in a repo
        // onto pinned workspaces within that repo (common monorepo + worktree case).
        //
        // We prefer the git common dir when available so that different worktrees of the same repo
        // are treated as the same logical project (end-user mental model: "this is the same repo").
        var pinnedProjectsByRepoKey: [String: [ProjectMatchInfo]] = [:]
        for info in projectInfos {
            guard let repoInfo = info.repoInfo else { continue }
            let repoKey = repoInfo.commonDir ?? repoInfo.repoRoot
            pinnedProjectsByRepoKey[repoKey, default: []].append(info)
        }

        var bestStates: [String: BestProjectState] = [:]
        var unmatched: [DaemonProjectState] = []

        for state in states {
            let normalizedStatePath = PathNormalizer.normalize(state.projectPath)
            let stateRepoInfo = GitRepositoryInfo.resolve(for: state.projectPath)
            let stateWorkspaceId = state.workspaceId
                ?? stateRepoInfo.map { WorkspaceIdentity.fromGitInfo($0) }
                ?? WorkspaceIdentity.fromPath(state.projectPath)
            let stateInfo = StateMatchInfo(
                state: state,
                normalizedPath: normalizedStatePath,
                repoInfo: stateRepoInfo,
                workspaceId: stateWorkspaceId,
            )
            guard let match = sortedProjects.first(where: { info in
                matchesProject(
                    info,
                    state: stateInfo,
                    homeNormalized: homeNormalized,
                )
            }) else {
                // If the daemon reports activity for a different workspace within the same repo,
                // apply that state to pinned workspaces in that repo root. This is common when
                // users pin a subdirectory of a monorepo but agent sessions run elsewhere in it.
                if let repoInfo = stateInfo.repoInfo,
                   let candidates = pinnedProjectsByRepoKey[repoInfo.commonDir ?? repoInfo.repoRoot]
                {
                    for candidate in candidates {
                        let projectPath = candidate.project.path
                        let candidateBest = BestProjectState(state: state, priority: .repoFallback)
                        if let existing = bestStates[projectPath] {
                            if shouldReplace(existing: existing, with: candidateBest) {
                                bestStates[projectPath] = candidateBest
                            }
                        } else {
                            bestStates[projectPath] = candidateBest
                        }
                    }
                    continue
                }

                unmatched.append(state)
                continue
            }

            let projectPath = match.project.path
            let candidateBest = BestProjectState(state: state, priority: .direct)
            if let existing = bestStates[projectPath] {
                if shouldReplace(existing: existing, with: candidateBest) {
                    bestStates[projectPath] = candidateBest
                }
            } else {
                bestStates[projectPath] = candidateBest
            }
        }

        if !unmatched.isEmpty {
            let sample = unmatched.prefix(3).map { "\($0.projectPath) [\($0.state)]" }.joined(separator: ", ")
            DebugLog.write("SessionStateManager.mergeDaemonProjectStates unmatched=\(unmatched.count) sample=\(sample)")
        }

        var merged: [String: ProjectSessionState] = [:]
        for (projectPath, best) in bestStates {
            let state = best.state
            let mappedState = mapDaemonState(state.state)
            let sessionState = ProjectSessionState(
                state: mappedState,
                stateChangedAt: state.stateChangedAt,
                updatedAt: state.updatedAt,
                sessionId: state.sessionId,
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: state.hasSession,
            )
            merged[projectPath] = sessionState
        }

        return merged
    }

    private nonisolated func matchesProject(
        _ project: ProjectMatchInfo,
        state: StateMatchInfo,
        homeNormalized: String,
    ) -> Bool {
        if project.workspaceId == state.workspaceId {
            return true
        }

        if isParentOrSelfExcludingHome(
            parent: project.normalizedPath,
            child: state.normalizedPath,
            homeNormalized: homeNormalized,
        ) {
            return true
        }

        guard
            let projectInfo = project.repoInfo,
            let stateInfo = state.repoInfo,
            let projectCommon = projectInfo.commonDir,
            let stateCommon = stateInfo.commonDir,
            projectCommon == stateCommon
        else {
            return false
        }

        let projectRel = projectInfo.relativePath
        let stateRel = stateInfo.relativePath
        if projectRel.isEmpty {
            return true
        }
        if projectRel == stateRel {
            return true
        }
        return stateRel.hasPrefix(projectRel + "/")
    }

    private nonisolated func isParentOrSelfExcludingHome(parent: String, child: String, homeNormalized: String) -> Bool {
        if parent == child {
            return true
        }
        if parent == homeNormalized {
            return false
        }
        return child.hasPrefix(parent + "/")
    }

    private nonisolated func isMoreRecent(_ candidate: DaemonProjectState, than existing: DaemonProjectState) -> Bool {
        let candidateTime = parseISO8601Date(candidate.updatedAt) ?? parseISO8601Date(candidate.stateChangedAt)
        let existingTime = parseISO8601Date(existing.updatedAt) ?? parseISO8601Date(existing.stateChangedAt)

        switch (candidateTime, existingTime) {
        case let (candidate?, existing?):
            return candidate > existing
        case (_?, nil):
            return true
        default:
            return false
        }
    }

    private nonisolated func shouldReplace(existing: BestProjectState, with candidate: BestProjectState) -> Bool {
        if candidate.priority != existing.priority {
            return candidate.priority.rawValue > existing.priority.rawValue
        }
        return isMoreRecent(candidate.state, than: existing.state)
    }

    private nonisolated func mapDaemonState(_ state: String) -> SessionState {
        switch state.lowercased() {
        case "working":
            .working
        case "ready":
            .ready
        case "compacting":
            .compacting
        case "waiting":
            .waiting
        case "idle":
            .idle
        default:
            .idle
        }
    }

    #if DEBUG
        /// Test-only helper for deterministic session resolution.
        func setSessionStatesForTesting(_ states: [String: ProjectSessionState]) {
            sessionStates = states
            pruneCachedStates()
            checkForStateChanges()
        }
    #endif
}
