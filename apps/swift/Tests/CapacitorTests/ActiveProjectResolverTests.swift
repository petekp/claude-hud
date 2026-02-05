import Foundation
import XCTest

@testable import Capacitor

@MainActor
final class ActiveProjectResolverTests: XCTestCase {
    func testPrefersActiveSessionOverNewerReadySession() {
        let projectA = makeProject(name: "A", path: "/tmp/project-a")
        let projectB = makeProject(name: "B", path: "/tmp/project-b")

        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([
            projectA.path: ProjectSessionState(
                state: .working,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-a",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true
            ),
            projectB.path: ProjectSessionState(
                state: .ready,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:05:00Z",
                sessionId: "session-b",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true
            ),
        ])

        let resolver = ActiveProjectResolver(sessionStateManager: sessionStateManager, shellStateStore: ShellStateStore())
        resolver.updateProjects([projectA, projectB])
        resolver.resolve()

        XCTAssertEqual(resolver.activeProject?.path, projectA.path)
        XCTAssertEqual(resolver.activeSource, .claude(sessionId: "session-a"))
    }

    func testSelectsMostRecentReadySessionWhenNoActiveSessions() {
        let projectA = makeProject(name: "A", path: "/tmp/project-a")
        let projectB = makeProject(name: "B", path: "/tmp/project-b")

        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([
            projectA.path: ProjectSessionState(
                state: .ready,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-a",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true
            ),
            projectB.path: ProjectSessionState(
                state: .ready,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:05:00Z",
                sessionId: "session-b",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true
            ),
        ])

        let resolver = ActiveProjectResolver(sessionStateManager: sessionStateManager, shellStateStore: ShellStateStore())
        resolver.updateProjects([projectA, projectB])
        resolver.resolve()

        XCTAssertEqual(resolver.activeProject?.path, projectB.path)
        XCTAssertEqual(resolver.activeSource, .claude(sessionId: "session-b"))
    }

    func testShellWorktreeMapsToOnlyPinnedWorkspaceInRepo() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repoRoot = tempDir.appendingPathComponent("assistant-ui")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")

        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedPath, withIntermediateDirectories: true)

        let worktreeRoot = tempDir.appendingPathComponent("assistant-ui-wt")
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)

        let worktreeGitDir = repoGit.appendingPathComponent("worktrees/feat-docs")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        let commondirPath = worktreeGitDir.appendingPathComponent("commondir")
        try "../..".write(to: commondirPath, atomically: true, encoding: .utf8)

        let gitFile = worktreeRoot.appendingPathComponent(".git")
        let gitFileContents = "gitdir: \(worktreeGitDir.path)\n"
        try gitFileContents.write(to: gitFile, atomically: true, encoding: .utf8)

        let project = makeProject(name: "assistant-ui-docs", path: pinnedPath.path)

        let pinnedInfo = GitRepositoryInfo.resolve(for: pinnedPath.path)
        XCTAssertNotNil(pinnedInfo)
        let worktreeInfo = GitRepositoryInfo.resolve(for: worktreeRoot.path)
        XCTAssertNotNil(worktreeInfo)
        XCTAssertEqual(pinnedInfo?.commonDir, worktreeInfo?.commonDir)

        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([:])

        let shellStateStore = ShellStateStore()
        shellStateStore.setStateForTesting(
            ShellCwdState(
                version: 1,
                shells: [
                    "123": ShellEntry(
                        cwd: worktreeRoot.path,
                        tty: "/dev/ttys001",
                        parentApp: "terminal",
                        tmuxSession: nil,
                        tmuxClientTty: nil,
                        updatedAt: Date()
                    ),
                ]
            )
        )

        let resolver = ActiveProjectResolver(sessionStateManager: sessionStateManager, shellStateStore: shellStateStore)
        resolver.updateProjects([project])
        resolver.resolve()

        XCTAssertEqual(resolver.activeProject?.path, project.path)
        XCTAssertEqual(resolver.activeSource, .shell(pid: "123", app: "terminal"))
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )
    }
}
