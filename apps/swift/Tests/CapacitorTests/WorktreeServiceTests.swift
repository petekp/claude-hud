import Foundation
import XCTest

@testable import Capacitor

final class WorktreeServiceTests: XCTestCase {
    func testParseWorktreeListPorcelainBuildsTypedEntries() {
        let output = """
        worktree /tmp/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /tmp/repo/.capacitor/worktrees/workstream-1
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/workstream-1

        worktree /tmp/repo/.capacitor/worktrees/workstream-2
        HEAD 3333333333333333333333333333333333333333
        detached
        locked maintenance
        prunable gitdir file points to non-existent location
        """

        let worktrees = WorktreeService.parseWorktreeListPorcelain(output)

        XCTAssertEqual(worktrees.count, 3)
        XCTAssertEqual(worktrees[0].branchRef, "refs/heads/main")
        XCTAssertEqual(worktrees[1].name, "workstream-1")
        XCTAssertFalse(worktrees[1].isDetached)
        XCTAssertEqual(worktrees[2].name, "workstream-2")
        XCTAssertTrue(worktrees[2].isDetached)
        XCTAssertTrue(worktrees[2].isLocked)
        XCTAssertTrue(worktrees[2].isPrunable)
    }

    func testListManagedWorktreesFiltersOutNonManagedPaths() throws {
        let repoPath = "/tmp/repo"
        var receivedArgs: [String] = []
        var receivedCwd = ""

        let output = """
        worktree /tmp/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /tmp/repo/.capacitor/worktrees/workstream-1
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/workstream-1

        worktree /tmp/repo/sandbox
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/sandbox

        worktree /tmp/repo/.capacitor/worktrees/workstream-2
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/workstream-2
        """

        let service = WorktreeService(runGit: { args, cwd in
            receivedArgs = args
            receivedCwd = cwd
            return .init(exitCode: 0, stdout: output, stderr: "")
        })

        let managed = try service.listManagedWorktrees(in: repoPath)

        XCTAssertEqual(receivedArgs, ["worktree", "list", "--porcelain"])
        XCTAssertEqual(receivedCwd, repoPath)
        XCTAssertEqual(managed.map(\.name), ["workstream-1", "workstream-2"])
    }

    func testCreateManagedWorktreeBuildsExpectedGitCommand() throws {
        let fileManager = FileManager.default
        let repoRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repoRoot) }

        var receivedArgs: [String] = []
        var receivedCwd = ""

        let service = WorktreeService(runGit: { args, cwd in
            receivedArgs = args
            receivedCwd = cwd
            return .init(exitCode: 0, stdout: "", stderr: "")
        })

        let created = try service.createManagedWorktree(in: repoRoot.path, name: "workstream-7")

        XCTAssertEqual(receivedArgs, ["worktree", "add", ".capacitor/worktrees/workstream-7", "-b", "workstream-7"])
        XCTAssertEqual(receivedCwd, repoRoot.path)
        XCTAssertEqual(created.name, "workstream-7")
        XCTAssertEqual(created.path, PathNormalizer.normalize(repoRoot.appendingPathComponent(".capacitor/worktrees/workstream-7").path))

        let managedRoot = repoRoot.appendingPathComponent(".capacitor/worktrees").path
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: managedRoot, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRemoveManagedWorktreeBuildsExpectedGitCommand() throws {
        let repoPath = "/tmp/repo"
        var receivedArgs: [String] = []
        var receivedCwd = ""

        let service = WorktreeService(runGit: { args, cwd in
            receivedArgs = args
            receivedCwd = cwd
            return .init(exitCode: 0, stdout: "", stderr: "")
        })

        try service.removeManagedWorktree(in: repoPath, name: "workstream-4")

        XCTAssertEqual(receivedArgs, ["worktree", "remove", ".capacitor/worktrees/workstream-4"])
        XCTAssertEqual(receivedCwd, repoPath)
    }

    func testRemoveManagedWorktreeThrowsGitCommandFailure() throws {
        let service = WorktreeService(runGit: { _, _ in
            .init(exitCode: 128, stdout: "", stderr: "fatal: worktree contains modified or untracked files")
        })

        do {
            try service.removeManagedWorktree(in: "/tmp/repo", name: "workstream-4")
            XCTFail("Expected remove to throw")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .gitCommandFailed(arguments, exitCode, output):
                XCTAssertEqual(arguments, ["worktree", "remove", ".capacitor/worktrees/workstream-4"])
                XCTAssertEqual(exitCode, 128)
                XCTAssertEqual(output, "fatal: worktree contains modified or untracked files")
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
