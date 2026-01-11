import Foundation
import Combine

struct Plan: Identifiable {
    let id: String
    let filename: String
    let name: String
    let content: String
    let createdDate: Date?
    let modifiedDate: Date?

    var preview: String {
        let lines = content.split(separator: "\n", maxSplits: 3)
        return String(lines.prefix(2).joined(separator: "\n"))
            .trimmingCharacters(in: .whitespaces)
    }

    var wordCount: Int {
        content.split(separator: " ").count
    }
}

class PlansManager: ObservableObject {
    @Published var plans: [String: [Plan]] = [:]
    @Published var allPlans: [Plan] = []

    private let fileManager = FileManager.default
    private let plansDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/plans")

    func loadPlans() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var allPlans: [Plan] = []
            var projectPlans: [String: [Plan]] = [:]

            do {
                let files = try self.fileManager.contentsOfDirectory(atPath: self.plansDirectory)

                for file in files where file.hasSuffix(".md") {
                    let filePath = (self.plansDirectory as NSString).appendingPathComponent(file)

                    if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                        let attributes = try? self.fileManager.attributesOfItem(atPath: filePath)
                        let modifiedDate = attributes?[.modificationDate] as? Date

                        let planName = file.replacingOccurrences(of: ".md", with: "")
                            .split(separator: "-")
                            .dropLast(2)
                            .joined(separator: " ")
                            .capitalized

                        let plan = Plan(
                            id: file,
                            filename: file,
                            name: planName.isEmpty ? file : planName,
                            content: content,
                            createdDate: nil,
                            modifiedDate: modifiedDate
                        )

                        allPlans.append(plan)

                        // Group by filename pattern
                        projectPlans[file] = [plan]
                    }
                }

                DispatchQueue.main.async {
                    self.allPlans = allPlans.sorted { $0.modifiedDate ?? .distantPast > $1.modifiedDate ?? .distantPast }
                    self.plans = projectPlans
                }
            } catch {
                print("Failed to load plans: \(error)")
            }
        }
    }

    func getPlans(for projectPath: String) -> [Plan] {
        // Return most recent plans (usually projects don't have associated plan files)
        // But we'll include plans that might be relevant
        return allPlans.prefix(3).map { $0 }
    }
}
