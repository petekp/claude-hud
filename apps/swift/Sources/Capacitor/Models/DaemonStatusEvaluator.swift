import Foundation

struct DaemonStatusEvaluator {
    static let startupGraceInterval: TimeInterval = 8.0

    private(set) var startupDeadline: Date?

    mutating func noteDaemonStartup(now: Date = Date()) {
        startupDeadline = now.addingTimeInterval(Self.startupGraceInterval)
    }

    mutating func beginStartup(currentStatus: DaemonStatus?, now: Date = Date()) -> DaemonStatus? {
        noteDaemonStartup(now: now)

        guard let currentStatus else { return nil }
        if currentStatus.isEnabled, !currentStatus.isHealthy {
            return nil
        }
        return currentStatus
    }

    func statusForHealthResult(
        isEnabled: Bool,
        result: Result<DaemonHealth, Error>,
        now: Date = Date()
    ) -> DaemonStatus? {
        guard isEnabled else {
            return DaemonStatus(
                isEnabled: false,
                isHealthy: false,
                message: "Daemon disabled",
                pid: nil,
                version: nil
            )
        }

        switch result {
        case let .success(health):
            return DaemonStatus(
                isEnabled: true,
                isHealthy: health.status == "ok",
                message: health.status,
                pid: health.pid,
                version: health.version
            )
        case .failure:
            if let deadline = startupDeadline, now < deadline {
                return nil
            }
            return DaemonStatus(
                isEnabled: true,
                isHealthy: false,
                message: "Daemon unavailable",
                pid: nil,
                version: nil
            )
        }
    }
}
