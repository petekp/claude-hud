import Foundation

actor ProjectIngestionWorker {
    struct AddProjectsOutcome: Sendable {
        var addedCount: Int
        var addedPaths: [String]
        var alreadyTrackedPaths: [String]
        var failedNames: [String]
    }

    private let engine: HudEngine

    init?() {
        guard let engine = try? HudEngine() else { return nil }
        self.engine = engine
    }

    func addProjects(paths: [String]) async -> AddProjectsOutcome {
        let fm = FileManager.default
        var addedCount = 0
        var addedPaths: [String] = []
        var alreadyTrackedPaths: [String] = []
        var failedNames: [String] = []

        for (index, path) in paths.enumerated() {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let result = engine.validateProject(path: path)

            switch result.resultType {
            case "valid", "missing_claude_md", "suggest_parent", "not_a_project":
                do {
                    try engine.addProject(path: path)
                    addedCount += 1
                    addedPaths.append(path)
                } catch {
                    failedNames.append(URL(fileURLWithPath: path).lastPathComponent)
                }
            case "already_tracked":
                alreadyTrackedPaths.append(result.path)
            case "path_not_found", "dangerous_path":
                failedNames.append(URL(fileURLWithPath: path).lastPathComponent)
            default:
                failedNames.append(URL(fileURLWithPath: path).lastPathComponent)
            }

            if index > 0, index % 5 == 0 {
                await _Concurrency.Task.yield()
            }
        }

        return AddProjectsOutcome(
            addedCount: addedCount,
            addedPaths: addedPaths,
            alreadyTrackedPaths: alreadyTrackedPaths,
            failedNames: failedNames
        )
    }
}
