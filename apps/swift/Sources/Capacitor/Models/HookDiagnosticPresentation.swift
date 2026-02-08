extension HookDiagnosticReport {
    var shouldShowSetupCard: Bool {
        guard !isHealthy else { return false }
        if case .notFiring? = primaryIssue { return false }
        return true
    }
}
