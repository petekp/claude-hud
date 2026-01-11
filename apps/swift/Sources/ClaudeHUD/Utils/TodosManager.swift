import Foundation
import Combine

struct Todo: Codable, Identifiable {
    let id: String
    let content: String
    let status: String
    let activeForm: String?

    var isCompleted: Bool {
        status == "completed"
    }

    var isInProgress: Bool {
        status == "in_progress"
    }
}

struct TodoFile: Codable {
    let todos: [Todo]
}

class TodosManager: ObservableObject {
    @Published var todos: [String: [Todo]] = [:]

    private let fileManager = FileManager.default
    private let todosDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/todos")

    func loadTodos() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var projectTodos: [String: [Todo]] = [:]

            do {
                let files = try self.fileManager.contentsOfDirectory(atPath: self.todosDirectory)

                for file in files where file.hasSuffix(".json") {
                    let filePath = (self.todosDirectory as NSString).appendingPathComponent(file)

                    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                       let todoFile = try? JSONDecoder().decode(TodoFile.self, from: data) {

                        // Group by project - use filename as project identifier
                        let projectId = file.replacingOccurrences(of: ".json", with: "")
                        projectTodos[projectId] = todoFile.todos
                    }
                }

                DispatchQueue.main.async {
                    self.todos = projectTodos
                }
            } catch {
                print("Failed to load todos: \(error)")
            }
        }
    }

    func getTodos(for projectPath: String) -> [Todo] {
        // Try to match project path with todo files
        for (key, todos) in self.todos {
            if projectPath.contains(key) || key.contains(projectPath) {
                return todos
            }
        }
        return []
    }

    func getCompletionStatus(for projectPath: String) -> (completed: Int, total: Int) {
        let todos = getTodos(for: projectPath)
        let completed = todos.filter { $0.isCompleted }.count
        return (completed, todos.count)
    }
}
