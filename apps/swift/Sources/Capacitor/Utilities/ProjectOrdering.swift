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
    static func isActive(_ path: String, sessionStates: [String: ProjectSessionState]) -> Bool {
        guard let session = sessionStates[path] else { return false }
        switch session.state {
        case .working, .waiting, .compacting, .ready:
            return true
        case .idle:
            return false
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
