import Foundation

// MARK: - Activity Group

enum ActivityGroup: String {
    case active
    case idle
}

// MARK: - Ordering

enum ProjectOrdering {
    /// Returns projects split into (active, idle) groups, each sorted by their respective custom order.
    /// Active projects come first, idle projects follow — seamless, no section headers.
    static func orderedGroupedProjects(
        _ projects: [Project],
        activeOrder: [String],
        idleOrder: [String],
        sessionStates: [String: ProjectSessionState],
    ) -> (active: [Project], idle: [Project]) {
        var activeProjects: [Project] = []
        var idleProjects: [Project] = []

        for project in projects {
            if isActive(project.path, sessionStates: sessionStates) {
                activeProjects.append(project)
            } else {
                idleProjects.append(project)
            }
        }

        activeProjects = orderedProjects(activeProjects, customOrder: activeOrder)
        idleProjects = orderedProjects(idleProjects, customOrder: idleOrder)

        return (active: activeProjects, idle: idleProjects)
    }

    /// Classifies a project as active if it has a session with a non-idle state.
    static func sessionState(for path: String, sessionStates: [String: ProjectSessionState]) -> ProjectSessionState? {
        if let session = sessionStates[path] {
            return session
        }

        let normalizedPath = PathNormalizer.normalize(path)
        return sessionStates.first(where: { PathNormalizer.normalize($0.key) == normalizedPath })?.value
    }

    /// Classifies a project as active if it has a session with a non-idle state.
    static func isActive(_ path: String, sessionStates: [String: ProjectSessionState]) -> Bool {
        guard let session = sessionState(for: path, sessionStates: sessionStates) else {
            return false
        }

        return isActive(session)
    }

    private static func isActive(_ session: ProjectSessionState) -> Bool {
        switch session.state {
        case .working, .waiting, .compacting, .ready:
            true
        case .idle:
            false
        }
    }

    static func orderedProjects(_ projects: [Project], customOrder: [String]) -> [Project] {
        guard !customOrder.isEmpty else { return projects }

        var result: [Project] = []
        var remaining = projects

        for path in customOrder {
            if let index = remaining.firstIndex(where: { $0.path == path }) {
                result.append(remaining.remove(at: index))
            }
        }

        result.append(contentsOf: remaining)
        return result
    }

    static func movedOrder(from source: IndexSet, to destination: Int, in projectList: [Project]) -> [String] {
        var paths = projectList.map(\.path)
        paths.move(fromOffsets: source, toOffset: destination)
        return paths
    }

    /// Stable per-card identity that refreshes a row only when its own session presentation changes.
    static func cardIdentityKey(projectPath: String, sessionState: ProjectSessionState?) -> String {
        guard let sessionState else {
            return "\(projectPath)#none"
        }

        return "\(projectPath)#\(sessionLabel(sessionState.state))#\(sessionState.sessionId ?? "-")#\(sessionState.hasSession ? "1" : "0")"
    }

    private static func sessionLabel(_ state: SessionState) -> String {
        switch state {
        case .working:
            "working"
        case .ready:
            "ready"
        case .idle:
            "idle"
        case .compacting:
            "compacting"
        case .waiting:
            "waiting"
        }
    }
}

// MARK: - Persistence

enum ProjectOrderStore {
    private static let activeOrderKey = "projectOrder.active"
    private static let idleOrderKey = "projectOrder.idle"
    private static let migrationKey = "projectOrder.migrated.v2"

    /// Legacy key (pre-v2)
    private static let legacyOrderKey = "customProjectOrder"

    static func loadActive(from defaults: UserDefaults = .standard) -> [String] {
        defaults.array(forKey: activeOrderKey) as? [String] ?? []
    }

    static func loadIdle(from defaults: UserDefaults = .standard) -> [String] {
        defaults.array(forKey: idleOrderKey) as? [String] ?? []
    }

    static func saveActive(_ order: [String], to defaults: UserDefaults = .standard) {
        defaults.set(order, forKey: activeOrderKey)
    }

    static func saveIdle(_ order: [String], to defaults: UserDefaults = .standard) {
        defaults.set(order, forKey: idleOrderKey)
    }

    /// Migrates from single `customProjectOrder` to dual active/idle lists.
    /// The first reconciliation cycle after migration classifies idle projects.
    static func migrateIfNeeded(from defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }

        let legacyOrder = defaults.array(forKey: legacyOrderKey) as? [String] ?? []
        if !legacyOrder.isEmpty {
            defaults.set(legacyOrder, forKey: activeOrderKey)
            // Idle starts empty — first reconcileProjectGroups() populates it
            defaults.set([String](), forKey: idleOrderKey)
        }

        defaults.set(true, forKey: migrationKey)
    }
}
