import Foundation

/// Decides when the app should try to (re)start the daemon after an IPC failure.
///
/// The daemon is an implementation detail; end-user UX should favor silent recovery.
struct DaemonRecoveryDecider {
    var cooldownInterval: TimeInterval = 20.0

    private(set) var lastAttemptAt: Date?

    mutating func noteSuccess() {
        // Intentionally keep `lastAttemptAt` so we don't thrash if the daemon is flapping.
    }

    mutating func shouldAttemptRecovery(after error: Error, now: Date = Date()) -> Bool {
        guard isRecoverableError(error) else { return false }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < cooldownInterval {
            return false
        }
        lastAttemptAt = now
        return true
    }

    private func isRecoverableError(_ error: Error) -> Bool {
        if case DaemonClientError.timeout = error {
            return true
        }

        if let posix = error as? POSIXError {
            return isRecoverablePosixCode(posix.code)
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return isRecoverablePosixCode(code)
        }

        return false
    }

    private func isRecoverablePosixCode(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ECONNREFUSED, .ENOENT, .ECONNRESET:
            true
        default:
            false
        }
    }
}
