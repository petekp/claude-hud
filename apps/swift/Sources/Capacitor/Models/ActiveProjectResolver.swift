import AppKit
import Foundation
import os.log

// MARK: - Active Source

enum ActiveSource: Equatable {
    case claude(sessionId: String)
    case shell(pid: String, app: String?)
    case none
}

// MARK: - Active Project Resolver

@MainActor
@Observable
final class ActiveProjectResolver {
    private let logger = Logger(subsystem: "com.capacitor.app", category: "ActiveProjectResolver")
    private let sessionStateManager: SessionStateManager
    private let shellStateStore: ShellStateStore

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    private var projects: [Project] = []
    private var manualOverride: Project?

    init(sessionStateManager: SessionStateManager, shellStateStore: ShellStateStore) {
        self.sessionStateManager = sessionStateManager
        self.shellStateStore = shellStateStore
    }

    // MARK: - Public API

    func updateProjects(_ projects: [Project]) {
        self.projects = projects
    }

    /// Set a manual override for the active project.
    /// The override persists until:
    /// - User clicks on a different project
    /// - User navigates to a project directory that has an active Claude session
    func setManualOverride(_ project: Project) {
        manualOverride = project
        logger.info("Manual override set: \(project.path, privacy: .public)")
    }

    func resolve() {
        let shellSummary = shellStateStore.state?.shells.map { pid, entry in
            "\(pid) cwd=\(entry.cwd) updated=\(entry.updatedAt)"
        }
        .sorted()
        .joined(separator: " | ")
        ?? "none"

        let overridePath = manualOverride?.path ?? "none"
        logger.info("Resolve start: manualOverride=\(overridePath, privacy: .public) shells=\(shellSummary, privacy: .public)")
        DebugLog.write("ActiveProjectResolver.resolve start manualOverride=\(overridePath) shells=\(shellSummary)")

        // Clear manual override if the user navigates to a different shell project
        // and there are no active Claude sessions to anchor the override.
        if let override = manualOverride,
           let (shellProject, _, _) = findActiveShellProject(),
           shellProject.path != override.path
        {
            if findActiveClaudeSession() == nil {
                logger.info("Clearing manual override (shell moved, no active Claude session): override=\(override.path, privacy: .public) shell=\(shellProject.path, privacy: .public)")
                DebugLog.write("ActiveProjectResolver.clearOverride reason=shellMoved override=\(override.path) shell=\(shellProject.path)")
                manualOverride = nil
            } else if let shellSessionState = sessionStateManager.getSessionState(for: shellProject),
                      shellSessionState.hasSession
            {
                logger.info("Clearing manual override (shell project has locked session): override=\(override.path, privacy: .public) shell=\(shellProject.path, privacy: .public)")
                DebugLog.write("ActiveProjectResolver.clearOverride reason=shellLocked override=\(override.path) shell=\(shellProject.path)")
                manualOverride = nil
            }
        }

        // Priority 0: Manual override (from clicking a project)
        // Persists until user clicks a different project OR navigates to a project
        // with an active Claude session. This prevents timestamp racing.
        if let override = manualOverride {
            activeProject = override
            activeSource = .none
            logger.info("Resolve result: activeProject=\(override.path, privacy: .public) source=manualOverride")
            DebugLog.write("ActiveProjectResolver.result activeProject=\(override.path) source=manualOverride")
            return
        }

        // Priority 1: Most recent Claude session (accurate timestamps from hook events)
        // Claude sessions update their timestamp on every hook event, making them
        // the most reliable signal for which project is actively being worked on.
        if let (project, sessionId) = findActiveClaudeSession() {
            activeProject = project
            activeSource = .claude(sessionId: sessionId)
            logger.info("Resolve result: activeProject=\(project.path, privacy: .public) source=claude session=\(sessionId, privacy: .public)")
            DebugLog.write("ActiveProjectResolver.result activeProject=\(project.path) source=claude session=\(sessionId)")
            return
        }

        // Priority 2: Shell CWD (fallback when no Claude sessions are running)
        // Shell timestamps only update on prompt display, which doesn't happen
        // during long-running Claude sessions.
        if let (project, pid, app) = findActiveShellProject() {
            activeProject = project
            activeSource = .shell(pid: pid, app: app)
            logger.info("Resolve result: activeProject=\(project.path, privacy: .public) source=shell pid=\(pid, privacy: .public) app=\(app ?? "unknown", privacy: .public)")
            DebugLog.write("ActiveProjectResolver.result activeProject=\(project.path) source=shell pid=\(pid) app=\(app ?? "unknown")")
            return
        }

        activeProject = nil
        activeSource = .none
        logger.info("Resolve result: activeProject=nil source=none")
        DebugLog.write("ActiveProjectResolver.result activeProject=nil source=none")
    }

    // MARK: - Private Resolution

    private func findActiveClaudeSession() -> (Project, String)? {
        var activeSessions: [(Project, String, Date)] = []
        var readySessions: [(Project, String, Date)] = []
        var sessionSummary: [String] = []
        for project in projects {
            guard let sessionState = sessionStateManager.getSessionState(for: project),
                  sessionState.hasSession,
                  let sessionId = sessionState.sessionId
            else {
                continue
            }

            // Use updated_at (updates on every hook event) for accurate activity tracking.
            // Falls back to stateChangedAt, then Date.distantPast.
            let updatedAt: Date = if let dateStr = sessionState.updatedAt,
                                     let parsed = DaemonDateParser.parse(dateStr)
            {
                parsed
            } else if let dateStr = sessionState.stateChangedAt,
                      let parsed = DaemonDateParser.parse(dateStr)
            {
                parsed
            } else {
                Date.distantPast
            }

            // Separate active (Working/Waiting/Compacting) from passive (Ready) sessions.
            // Active sessions always take priority - a session you're using shouldn't
            // lose focus to one that just finished.
            let isActive = sessionState.state == .working ||
                sessionState.state == .waiting ||
                sessionState.state == .compacting

            if isActive {
                activeSessions.append((project, sessionId, updatedAt))
            } else {
                readySessions.append((project, sessionId, updatedAt))
            }

            sessionSummary.append(
                "\(project.path) state=\(String(describing: sessionState.state)) updated=\(updatedAt)"
            )
        }

        // Prefer active sessions over ready sessions, then sort by recency
        let candidates = activeSessions.isEmpty ? readySessions : activeSessions
        if sessionSummary.isEmpty {
            logger.info("Claude session scan: none")
            DebugLog.write("ActiveProjectResolver.claudeSessions none")
        } else {
            let joined = sessionSummary.joined(separator: " | ")
            logger.info("Claude session scan: \(joined, privacy: .public)")
            DebugLog.write("ActiveProjectResolver.claudeSessions \(joined)")
        }
        return candidates.max(by: { $0.2 < $1.2 }).map { ($0.0, $0.1) }
    }

    private func findActiveShellProject() -> (Project, String, String?)? {
        let preferredApp = preferredParentApp()
        if let preferredApp {
            DebugLog.write("ActiveProjectResolver.shellSelection preferredApp=\(preferredApp)")
        }

        guard let (pid, shell) = shellStateStore.mostRecentShell(matchingParentApp: preferredApp) else {
            logger.info("Shell selection: no recent shell")
            DebugLog.write("ActiveProjectResolver.shellSelection none")
            return nil
        }

        guard let project = projectContaining(path: shell.cwd) else {
            logger.info("Shell selection: no matching project for cwd=\(shell.cwd, privacy: .public)")
            DebugLog.write("ActiveProjectResolver.shellSelection noProject cwd=\(shell.cwd)")
            return nil
        }

        logger.info("Shell selection: project=\(project.path, privacy: .public) pid=\(pid, privacy: .public) cwd=\(shell.cwd, privacy: .public)")
        DebugLog.write("ActiveProjectResolver.shellSelection project=\(project.path) pid=\(pid) cwd=\(shell.cwd)")
        return (project, pid, shell.parentApp)
    }

    private func preferredParentApp() -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }

        let bundleId = frontmost.bundleIdentifier?.lowercased() ?? ""
        let name = frontmost.localizedName?.lowercased() ?? ""

        if bundleId == "com.capacitor.app" || name.contains("capacitor") {
            return nil
        }

        if bundleId == "com.apple.terminal" || name == "terminal" {
            return "terminal"
        }
        if bundleId == "com.googlecode.iterm2" || name.contains("iterm") {
            return "iterm2"
        }
        if bundleId == "dev.warp.warp" || name == "warp" {
            return "warp"
        }
        if bundleId == "com.mitchellh.ghostty" || name == "ghostty" {
            return "ghostty"
        }
        if bundleId == "org.alacritty" || name == "alacritty" {
            return "alacritty"
        }
        if bundleId == "net.kovidgoyal.kitty" || name == "kitty" {
            return "kitty"
        }
        if bundleId == "com.microsoft.vscode-insiders"
            || name.contains("visual studio code - insiders")
            || name.contains("vscode insiders")
        {
            return "vscode-insiders"
        }
        if bundleId == "com.microsoft.vscode" || name.contains("visual studio code") {
            return "vscode"
        }
        if name.contains("cursor") {
            return "cursor"
        }
        if bundleId == "dev.zed.zed" || name == "zed" {
            return "zed"
        }

        return nil
    }

    private func projectContaining(path: String) -> Project? {
        let normalizedPath = PathNormalizer.normalize(path)
        for project in projects {
            let normalizedProjectPath = PathNormalizer.normalize(project.path)
            if normalizedPath == normalizedProjectPath || normalizedPath.hasPrefix(normalizedProjectPath + "/") {
                return project
            }
        }

        // If the shell is in a different git worktree than the pinned workspace, the paths won't share
        // a common prefix. Fall back to matching by repo identity (git common dir) so any worktree
        // in the same repo can still map onto a pinned project.
        guard let cwdRepoInfo = GitRepositoryInfo.resolve(for: path) else {
            return nil
        }

        let cwdRepoKey = cwdRepoInfo.commonDir ?? cwdRepoInfo.repoRoot
        var candidates: [(Project, GitRepositoryInfo)] = []
        for project in projects {
            guard let projectRepoInfo = GitRepositoryInfo.resolve(for: project.path) else {
                continue
            }
            let projectRepoKey = projectRepoInfo.commonDir ?? projectRepoInfo.repoRoot
            if projectRepoKey == cwdRepoKey {
                candidates.append((project, projectRepoInfo))
            }
        }

        guard !candidates.isEmpty else {
            return nil
        }

        // If there's only one pinned workspace in this repo, treat it as representing the whole repo.
        if candidates.count == 1 {
            return candidates[0].0
        }

        // If multiple pinned workspaces share the same repo, disambiguate by repo-relative path.
        // (This supports mapping across worktrees when the relative directory matches.)
        let cwdRel = cwdRepoInfo.relativePath
        let matching: [(Project, GitRepositoryInfo)] = candidates.filter { _, info in
            let rel = info.relativePath
            if rel.isEmpty {
                return true
            }
            if cwdRel == rel {
                return true
            }
            return cwdRel.hasPrefix(rel + "/")
        }

        if matching.isEmpty {
            return nil
        }
        if matching.count == 1 {
            return matching[0].0
        }

        // Choose the most specific (deepest) pinned workspace.
        let bestDepth = matching.map(\.1.relativePath.count).max() ?? 0
        let tied = matching.filter { $0.1.relativePath.count == bestDepth }
        if tied.count == 1 {
            return tied[0].0
        }
        return tied.sorted { $0.0.path < $1.0.path }.first?.0
    }
}
