import Foundation

struct DaemonStatusEvaluator {
    static let startupGraceInterval: TimeInterval = 20.0
    static let failuresBeforeOffline: Int = 2

    private(set) var startupDeadline: Date?
    private(set) var consecutiveFailures: Int = 0

    mutating func noteDaemonStartup(now: Date = Date()) {
        startupDeadline = now.addingTimeInterval(Self.startupGraceInterval)
        consecutiveFailures = 0
    }

    mutating func beginStartup(currentStatus: DaemonStatus?, now: Date = Date()) -> DaemonStatus? {
        noteDaemonStartup(now: now)

        guard let currentStatus else { return nil }
        if currentStatus.isEnabled, !currentStatus.isHealthy {
            return nil
        }
        return currentStatus
    }

    mutating func statusForHealthResult(
        isEnabled: Bool,
        result: Result<DaemonHealth, Error>,
        now: Date = Date()
    ) -> DaemonStatus? {
        guard isEnabled else {
            consecutiveFailures = 0
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
            consecutiveFailures = 0
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
            consecutiveFailures += 1
            if consecutiveFailures < Self.failuresBeforeOffline {
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
