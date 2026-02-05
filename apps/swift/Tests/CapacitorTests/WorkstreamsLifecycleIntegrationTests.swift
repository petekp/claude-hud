import Foundation
import XCTest

@testable import Capacitor

@MainActor
final class WorkstreamsLifecycleIntegrationTests: XCTestCase {
    func testCreateAttributionAndDestroyGuardrailFlow() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let repoRoot = tempDir.appendingPathComponent("repo")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")
        try fileManager.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pinnedPath, withIntermediateDirectories: true)

        var gitCalls: [[String]] = []
        let service = WorktreeService(runGit: { args, _ in
            gitCalls.append(args)
            switch args {
            case ["worktree", "add", ".capacitor/worktrees/workstream-1", "-b", "workstream-1"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            default:
                XCTFail("Unexpected git command: \(args)")
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
        })

        let worktree = try service.createManagedWorktree(in: repoRoot.path, name: "workstream-1")
        let shellPath = PathNormalizer.normalize(worktree.path + "/apps/docs")
        try fileManager.createDirectory(atPath: shellPath, withIntermediateDirectories: true)

        let project = Project(
            name: "repo-docs",
            path: pinnedPath.path,
            displayPath: pinnedPath.path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )

        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([:])

        let shellStateStore = ShellStateStore()
        shellStateStore.setStateForTesting(
            ShellCwdState(
                version: 1,
                shells: [
                    "123": ShellEntry(
                        cwd: shellPath,
                        tty: "/dev/ttys001",
                        parentApp: "terminal",
                        tmuxSession: nil,
                        tmuxClientTty: nil,
                        updatedAt: Date()
                    ),
                ]
            )
        )

        let resolver = ActiveProjectResolver(
            sessionStateManager: sessionStateManager,
            shellStateStore: shellStateStore
        )
        resolver.updateProjects([project])
        resolver.resolve()

        XCTAssertEqual(resolver.activeProject?.path, project.path)
        XCTAssertEqual(resolver.activeSource, .shell(pid: "123", app: "terminal"))

        do {
            try service.removeManagedWorktree(
                in: repoRoot.path,
                name: "workstream-1",
                activeWorktreePaths: [shellPath]
            )
            XCTFail("Expected guardrail to block destroy for active worktree")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .activeSessionWorktree(path):
                XCTAssertEqual(path, worktree.path)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(gitCalls, [
            ["worktree", "add", ".capacitor/worktrees/workstream-1", "-b", "workstream-1"],
        ])
    }
}
