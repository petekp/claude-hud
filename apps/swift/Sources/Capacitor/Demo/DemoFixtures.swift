import Foundation

struct DemoStateTimelineKeyframe {
    let atSeconds: TimeInterval
    let sessionStates: [String: ProjectSessionState]
    let projectStatuses: [String: ProjectStatus]?
}

struct DemoFixture {
    let scenario: String
    let projects: [Project]
    let hiddenProjectPaths: Set<String>
    let sessionStates: [String: ProjectSessionState]
    let projectStatuses: [String: ProjectStatus]
    let featureFlags: FeatureFlags
    let stateTimeline: [DemoStateTimelineKeyframe]
}

enum DemoFixtureError: LocalizedError {
    case unreadableProjectsFile(path: String)
    case invalidProjectsFile(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableProjectsFile(path):
            "Unable to read demo projects file at \(path)."
        case let .invalidProjectsFile(path, reason):
            "Invalid demo projects file at \(path): \(reason)"
        }
    }
}

enum DemoFixtures {
    static func fixture(for scenario: String?, projectOverrideFilePath: String? = nil) throws -> DemoFixture? {
        let normalizedScenario = scenario?.trimmingCharacters(in: .whitespacesAndNewlines)

        let scenarioName: String
        let includeStateTimeline: Bool

        switch normalizedScenario {
        case nil, "", "project_flow_v1":
            scenarioName = "project_flow_v1"
            includeStateTimeline = true
        case "project_flow_states_v1":
            scenarioName = "project_flow_states_v1"
            includeStateTimeline = true
        default:
            return nil
        }

        let projectSeeds = try loadProjectSeeds(projectOverrideFilePath: projectOverrideFilePath) ?? defaultProjectSeeds

        return makeProjectFlowFixture(
            scenario: scenarioName,
            includeStateTimeline: includeStateTimeline,
            projectSeeds: projectSeeds,
        )
    }

    private static let defaultProjectSeeds: [DemoProjectSeed] = [
        DemoProjectSeed(
            name: "Capacitor Core",
            path: "/Users/petepetrash/Code/capacitor-demo/capacitor-core",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/capacitor-core",
            lastActive: "2026-02-16T18:00:00Z",
            taskCount: 12,
            hidden: false,
            initialState: .working,
        ),
        DemoProjectSeed(
            name: "Agent Skills",
            path: "/Users/petepetrash/Code/capacitor-demo/agent-skills",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/agent-skills",
            lastActive: "2026-02-16T17:54:00Z",
            taskCount: 8,
            hidden: false,
            initialState: .ready,
        ),
        DemoProjectSeed(
            name: "Tool UI",
            path: "/Users/petepetrash/Code/capacitor-demo/tool-ui",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/tool-ui",
            lastActive: "2026-02-16T17:48:00Z",
            taskCount: 5,
            hidden: false,
            initialState: .waiting,
        ),
        DemoProjectSeed(
            name: "Docs Portal",
            path: "/Users/petepetrash/Code/capacitor-demo/docs-portal",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/docs-portal",
            lastActive: "2026-02-16T17:41:00Z",
            taskCount: 4,
            hidden: true,
            initialState: .compacting,
        ),
        DemoProjectSeed(
            name: "Daemon Runtime",
            path: "/Users/petepetrash/Code/capacitor-demo/daemon-runtime",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/daemon-runtime",
            lastActive: "2026-02-16T17:35:00Z",
            taskCount: 7,
            hidden: false,
            initialState: .ready,
        ),
        DemoProjectSeed(
            name: "Marketing Site",
            path: "/Users/petepetrash/Code/capacitor-demo/marketing-site",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/marketing-site",
            lastActive: "2026-02-16T17:32:00Z",
            taskCount: 3,
            hidden: false,
            initialState: .working,
        ),
        DemoProjectSeed(
            name: "Telemetry Pipeline",
            path: "/Users/petepetrash/Code/capacitor-demo/telemetry-pipeline",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/telemetry-pipeline",
            lastActive: "2026-02-16T17:28:00Z",
            taskCount: 6,
            hidden: true,
            initialState: .waiting,
        ),
        DemoProjectSeed(
            name: "Onboarding Lab",
            path: "/Users/petepetrash/Code/capacitor-demo/onboarding-lab",
            displayPath: "/Users/petepetrash/Code/capacitor-demo/onboarding-lab",
            lastActive: "2026-02-16T17:20:00Z",
            taskCount: 2,
            hidden: true,
            initialState: .compacting,
        ),
    ]

    private static func loadProjectSeeds(projectOverrideFilePath: String?) throws -> [DemoProjectSeed]? {
        guard let projectOverrideFilePath else { return nil }

        let url = URL(fileURLWithPath: projectOverrideFilePath)
        guard let data = try? Data(contentsOf: url) else {
            throw DemoFixtureError.unreadableProjectsFile(path: projectOverrideFilePath)
        }

        let decoder = JSONDecoder()
        let file: DemoProjectsFile
        do {
            file = try decoder.decode(DemoProjectsFile.self, from: data)
        } catch {
            throw DemoFixtureError.invalidProjectsFile(
                path: projectOverrideFilePath,
                reason: "Failed to decode JSON (\(error.localizedDescription))",
            )
        }

        guard !file.projects.isEmpty else {
            throw DemoFixtureError.invalidProjectsFile(
                path: projectOverrideFilePath,
                reason: "projects must contain at least one item",
            )
        }

        var paths: Set<String> = []
        var projectSeeds: [DemoProjectSeed] = []
        for (index, project) in file.projects.enumerated() {
            let path = project.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw DemoFixtureError.invalidProjectsFile(
                    path: projectOverrideFilePath,
                    reason: "projects[\(index)].path is required",
                )
            }
            guard !name.isEmpty else {
                throw DemoFixtureError.invalidProjectsFile(
                    path: projectOverrideFilePath,
                    reason: "projects[\(index)].name is required",
                )
            }
            guard !paths.contains(path) else {
                throw DemoFixtureError.invalidProjectsFile(
                    path: projectOverrideFilePath,
                    reason: "projects has duplicate path \(path)",
                )
            }
            paths.insert(path)

            let explicitState = parseSessionState(project.initialState)
            if project.initialState != nil, explicitState == nil {
                throw DemoFixtureError.invalidProjectsFile(
                    path: projectOverrideFilePath,
                    reason: "projects[\(index)].initialState must be one of: ready, working, waiting, compacting, idle",
                )
            }
            projectSeeds.append(
                DemoProjectSeed(
                    name: name,
                    path: path,
                    displayPath: project.displayPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? path,
                    lastActive: project.lastActive?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "2026-02-16T18:00:00Z",
                    taskCount: project.taskCount ?? 0,
                    hidden: project.hidden ?? false,
                    initialState: explicitState,
                ),
            )
        }

        let extraHiddenPaths = Set((file.hiddenProjectPaths ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let unknownHiddenPaths = extraHiddenPaths.subtracting(paths)
        if !unknownHiddenPaths.isEmpty {
            let sortedPaths = unknownHiddenPaths.sorted().joined(separator: ", ")
            throw DemoFixtureError.invalidProjectsFile(
                path: projectOverrideFilePath,
                reason: "hiddenProjectPaths contains unknown paths: \(sortedPaths)",
            )
        }

        projectSeeds = projectSeeds.map { seed in
            DemoProjectSeed(
                name: seed.name,
                path: seed.path,
                displayPath: seed.displayPath,
                lastActive: seed.lastActive,
                taskCount: seed.taskCount,
                hidden: seed.hidden || extraHiddenPaths.contains(seed.path),
                initialState: seed.initialState,
            )
        }

        return projectSeeds
    }

    private static func makeProjectFlowFixture(
        scenario: String,
        includeStateTimeline: Bool,
        projectSeeds: [DemoProjectSeed],
    ) -> DemoFixture {
        let projects = projectSeeds.map(makeProject(from:))
        let hiddenProjectPaths = Set(projectSeeds.filter(\.hidden).map(\.path))

        var stateByPath: [String: SessionState] = [:]
        for (index, projectSeed) in projectSeeds.enumerated() {
            stateByPath[projectSeed.path] = projectSeed.initialState ?? defaultState(for: index)
        }

        let initialTimestamp = "2026-02-16T18:00:00Z"
        let sessionStates = makeSessionStates(
            stateByPath: stateByPath,
            projects: projects,
            timestamp: initialTimestamp,
        )

        let projectStatuses = makeProjectStatuses(
            states: sessionStates,
            timestamp: initialTimestamp,
        )

        let featureFlags = FeatureFlags.defaults(for: .alpha)

        let stateTimeline = includeStateTimeline
            ? makeStateTimeline(projects: projects, initialStatesByPath: stateByPath)
            : []

        return DemoFixture(
            scenario: scenario,
            projects: projects,
            hiddenProjectPaths: hiddenProjectPaths,
            sessionStates: sessionStates,
            projectStatuses: projectStatuses,
            featureFlags: featureFlags,
            stateTimeline: stateTimeline,
        )
    }

    private static func makeStateTimeline(
        projects: [Project],
        initialStatesByPath: [String: SessionState],
    ) -> [DemoStateTimelineKeyframe] {
        guard !projects.isEmpty else { return [] }

        let baseStates: [SessionState] = [.ready, .working, .waiting, .compacting]
        let frameTimes: [TimeInterval] = [3, 6, 9, 12, 15]

        return frameTimes.enumerated().map { frameIndex, frameTime in
            var statesByPath: [String: SessionState] = [:]
            for (projectIndex, project) in projects.enumerated() {
                let startingState = initialStatesByPath[project.path] ?? defaultState(for: projectIndex)
                let startingIndex = baseStates.firstIndex(of: startingState) ?? (projectIndex % baseStates.count)
                statesByPath[project.path] = baseStates[(startingIndex + frameIndex + 1) % baseStates.count]
            }

            let timestamp = String(format: "2026-02-16T18:00:%02dZ", 3 * (frameIndex + 1))
            let states = makeSessionStates(
                stateByPath: statesByPath,
                projects: projects,
                timestamp: timestamp,
            )

            return DemoStateTimelineKeyframe(
                atSeconds: frameTime,
                sessionStates: states,
                projectStatuses: makeProjectStatuses(states: states, timestamp: timestamp),
            )
        }
    }

    private static func makeSessionStates(
        stateByPath: [String: SessionState],
        projects: [Project],
        timestamp: String,
    ) -> [String: ProjectSessionState] {
        var result: [String: ProjectSessionState] = [:]
        for project in projects {
            let state = stateByPath[project.path] ?? .idle
            let hasSession = state != .idle
            result[project.path] = ProjectSessionState(
                state: state,
                stateChangedAt: timestamp,
                updatedAt: timestamp,
                sessionId: hasSession ? "\(DemoAccessibility.slug(for: project))-session-001" : nil,
                workingOn: hasSession ? "\(state.label) in progress" : nil,
                context: nil,
                thinking: false,
                hasSession: hasSession,
            )
        }
        return result
    }

    private static func makeProjectStatuses(
        states: [String: ProjectSessionState],
        timestamp: String,
    ) -> [String: ProjectStatus] {
        var result: [String: ProjectStatus] = [:]
        for (path, sessionState) in states {
            result[path] = ProjectStatus(
                workingOn: sessionState.workingOn ?? "No active session",
                nextStep: sessionState.state == .idle ? "Resume work" : "Continue \(sessionState.state.label.lowercased())",
                status: sessionState.state.label.lowercased(),
                blocker: nil,
                updatedAt: timestamp,
            )
        }
        return result
    }

    private static func makeProject(from seed: DemoProjectSeed) -> Project {
        Project(
            name: seed.name,
            path: seed.path,
            displayPath: seed.displayPath,
            lastActive: seed.lastActive,
            claudeMdPath: "\(seed.path)/CLAUDE.md",
            claudeMdPreview: "# \(seed.name)",
            hasLocalSettings: true,
            taskCount: seed.taskCount,
            stats: nil,
            isMissing: false,
        )
    }

    private static func defaultState(for index: Int) -> SessionState {
        let states: [SessionState] = [.working, .ready, .waiting, .compacting]
        return states[index % states.count]
    }

    private static func parseSessionState(_ raw: String?) -> SessionState? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "working":
            return .working
        case "ready":
            return .ready
        case "waiting":
            return .waiting
        case "compacting":
            return .compacting
        case "idle":
            return .idle
        default:
            return nil
        }
    }
}

private struct DemoProjectSeed {
    let name: String
    let path: String
    let displayPath: String
    let lastActive: String
    let taskCount: UInt32
    let hidden: Bool
    let initialState: SessionState?
}

private struct DemoProjectsFile: Decodable {
    let projects: [DemoProjectRecord]
    let hiddenProjectPaths: [String]?
}

private struct DemoProjectRecord: Decodable {
    let name: String
    let path: String
    let displayPath: String?
    let lastActive: String?
    let taskCount: UInt32?
    let hidden: Bool?
    let initialState: String?
}

private extension SessionState {
    var label: String {
        switch self {
        case .working:
            "Working"
        case .ready:
            "Ready"
        case .waiting:
            "Waiting"
        case .compacting:
            "Compacting"
        case .idle:
            "Idle"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
