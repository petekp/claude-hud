import Foundation

enum ProjectOrdering {
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

enum ProjectOrderStore {
    private static let projectOrderKey = "customProjectOrder"

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        defaults.array(forKey: projectOrderKey) as? [String] ?? []
    }

    static func save(_ order: [String], to defaults: UserDefaults = .standard) {
        defaults.set(order, forKey: projectOrderKey)
    }
}
