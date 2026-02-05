import Foundation
import XCTest

@testable import Capacitor

@MainActor
final class WorkstreamsManagerTests: XCTestCase {
    func testLoadPopulatesWorktreesOnSuccess() {
        let project = makeProject(path: "/tmp/repo")
        let expected = [
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-2"),
        ]

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in expected }
        )

        manager.load(for: project)
        let state = manager.state(for: project)

        XCTAssertEqual(state.worktrees, expected)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }

    func testLoadStoresErrorMessageOnFailure() {
        let project = makeProject(path: "/tmp/repo")
        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                throw WorktreeService.Error.gitCommandFailed(
                    arguments: ["worktree", "list", "--porcelain"],
                    exitCode: 128,
                    output: "fatal: not a git repository"
                )
            }
        )

        manager.load(for: project)
        let state = manager.state(for: project)

        XCTAssertTrue(state.worktrees.isEmpty)
        XCTAssertFalse(state.isLoading)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage?.contains("worktree list") == true)
    }

    func testCreateUsesNextAvailableNameAndRefreshesList() {
        let project = makeProject(path: "/tmp/repo")
        let initial = [
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-3"),
        ]
        let refreshed = [
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-2"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-3"),
        ]

        var listCallCount = 0
        var createdName: String?

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                defer { listCallCount += 1 }
                return listCallCount == 0 ? initial : refreshed
            },
            createManagedWorktree: { _, name in
                createdName = name
                return Self.makeWorktree(path: "/tmp/repo/.capacitor/worktrees/\(name)")
            }
        )

        manager.load(for: project)
        manager.create(for: project)
        let state = manager.state(for: project)

        XCTAssertEqual(createdName, "workstream-2")
        XCTAssertEqual(state.worktrees.map(\.name), ["workstream-1", "workstream-2", "workstream-3"])
        XCTAssertFalse(state.isCreating)
        XCTAssertNil(state.errorMessage)
    }

    func testDestroyPassesActivePathsAndSurfacesActiveSessionError() {
        let project = makeProject(path: "/tmp/repo")
        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1")
        let activePaths: Set<String> = [worktree.path]
        var receivedActivePaths: Set<String> = []

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in [worktree] },
            removeManagedWorktree: { _, _, _, active in
                receivedActivePaths = active
                throw WorktreeService.Error.activeSessionWorktree(path: worktree.path)
            },
            activeWorktreePathsProvider: { activePaths }
        )

        manager.load(for: project)
        manager.destroy(worktreeName: worktree.name, for: project)
        let state = manager.state(for: project)

        XCTAssertEqual(receivedActivePaths, activePaths)
        XCTAssertTrue(state.errorMessage?.contains("active session") == true)
        XCTAssertFalse(state.destroyingNames.contains(worktree.name))
    }

    func testDestroyRefreshesListOnSuccess() {
        let project = makeProject(path: "/tmp/repo")
        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1")
        var listCallCount = 0

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                defer { listCallCount += 1 }
                return listCallCount == 0 ? [worktree] : []
            },
            removeManagedWorktree: { _, _, _, _ in }
        )

        manager.load(for: project)
        manager.destroy(worktreeName: worktree.name, for: project)
        let state = manager.state(for: project)

        XCTAssertTrue(state.worktrees.isEmpty)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.destroyingNames.contains(worktree.name))
    }

    func testOpenSendsWorktreeShapedProjectToTerminalLauncher() {
        var openedProject: Project?
        let manager = WorkstreamsManager(
            openWorktree: { project in
                openedProject = project
            }
        )

        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-9")
        manager.open(worktree)

        XCTAssertEqual(openedProject?.name, "workstream-9")
        XCTAssertEqual(openedProject?.path, worktree.path)
        XCTAssertEqual(openedProject?.displayPath, worktree.path)
    }

    private static func makeProject(path: String) -> Project {
        Project(
            name: "repo",
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

    private func makeProject(path: String) -> Project {
        Self.makeProject(path: path)
    }

    private static func makeWorktree(path: String) -> WorktreeService.Worktree {
        WorktreeService.Worktree(
            path: PathNormalizer.normalize(path),
            branchRef: nil,
            head: nil,
            isDetached: false,
            isLocked: false,
            isPrunable: false
        )
    }

    private func makeWorktree(path: String) -> WorktreeService.Worktree {
        Self.makeWorktree(path: path)
    }
}
