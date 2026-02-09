import Combine
import Foundation
import SwiftUI

enum LayoutMode: String, CaseIterable {
    case vertical
    case dock
}

enum ProjectView: Equatable {
    case list
    case detail(Project)
    case addLink
    case newIdea

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list), (.addLink, .addLink), (.newIdea, .newIdea):
            true
        case let (.detail(p1), .detail(p2)):
            p1.path == p2.path
        default:
            false
        }
    }
}

enum AppFeatureError: LocalizedError {
    case ideaCaptureDisabled
    case projectDetailsDisabled
    case projectCreationDisabled

    var errorDescription: String? {
        switch self {
        case .ideaCaptureDisabled:
            "Idea capture is disabled for this build."
        case .projectDetailsDisabled:
            "Project details are disabled for this build."
        case .projectCreationDisabled:
            "Project creation is disabled for this build."
        }
    }
}

@MainActor
class AppState: ObservableObject {
    // MARK: - Layout Mode

    @Published var layoutMode: LayoutMode = .vertical {
        didSet { saveLayoutMode() }
    }

    // MARK: - Build Channel + Feature Flags

    @Published private(set) var channel: AppChannel = AppConfig.defaultChannel
    @Published private(set) var featureFlags: FeatureFlags = .defaults(for: AppConfig.defaultChannel)

    var isIdeaCaptureEnabled: Bool {
        featureFlags.ideaCapture
    }

    var isProjectDetailsEnabled: Bool {
        featureFlags.projectDetails
    }

    var isWorkstreamsEnabled: Bool {
        featureFlags.workstreams && isProjectDetailsEnabled
    }

    var isProjectCreationEnabled: Bool {
        featureFlags.projectCreation
    }

    var isLlmFeaturesEnabled: Bool {
        featureFlags.llmFeatures && isProjectDetailsEnabled
    }

    // MARK: - Navigation

    @Published var projectView: ProjectView = .list

    /// Path pending validation when navigating to AddProjectView
    /// Set by HeaderView's folder picker, consumed by AddProjectView on appear
    @Published var pendingProjectPath: String?

    // MARK: - Data

    @Published var dashboard: DashboardData?
    @Published var projects: [Project] = []
    @Published var suggestedProjects: [SuggestedProject] = []

    // MARK: - Active project creations (Idea → V1)

    @Published var activeCreations: [ProjectCreation] = []

    // MARK: - UI State

    @Published var isLoading = true
    @Published var error: String?
    @Published var toast: ToastMessage?
    @Published var pendingDragDropTip = false

    // MARK: - Hook Diagnostic

    @Published var hookDiagnostic: HookDiagnosticReport?

    // MARK: - Activation Trace (Debug)

    @Published var activationTrace: String?

    // MARK: - Daemon Diagnostic

    @Published var daemonStatus: DaemonStatus?

    // MARK: - Manual dormant overrides

    @Published var manuallyDormant: Set<String> = [] {
        didSet { saveDormantOverrides() }
    }

    // MARK: - Custom project ordering

    @Published var customProjectOrder: [String] = [] {
        didSet { saveProjectOrder() }
    }

    // MARK: - Modal State for Idea Capture

    @Published var showCaptureModal = false
    @Published var captureModalProject: Project?
    @Published var captureModalOrigin: CGRect?

    // MARK: - Managers (extracted for cleaner architecture)

    let shellStateStore = ShellStateStore()
    let terminalLauncher = TerminalLauncher()
    let sessionStateManager = SessionStateManager()
    let projectDetailsManager = ProjectDetailsManager()
    private let projectIngestionWorker = ProjectIngestionWorker()
    lazy var workstreamsManager: WorkstreamsManager = .init(
        openWorktree: { [weak self] worktreeProject in
            self?.launchTerminal(for: worktreeProject)
        },
        activeWorktreePathsProvider: { [weak self] in
            self?.activeWorktreePathsForGuardrails() ?? []
        },
    )

    private(set) var activeProjectResolver: ActiveProjectResolver!

    // MARK: - Private State

    private let layoutModeKey = "layoutMode"
    private var engine: HudEngine?
    private var stalenessTimer: Timer?
    private var daemonStatusEvaluator = DaemonStatusEvaluator()
    private var daemonRecoveryDecider = DaemonRecoveryDecider()

    /// Debounce work item for coalescing rapid state updates.
    /// Prevents recursive layout crashes when multiple sessions change simultaneously.
    private var refreshDebounceWork: DispatchWorkItem?
    private var isRefreshScheduled = false
    private var sessionStateCancellable: AnyCancellable?

    // MARK: - Computed Properties (bridging to managers)

    var activeProjectPath: String? {
        activeProjectResolver?.activeProject?.path
    }

    var activeSource: ActiveSource {
        activeProjectResolver?.activeSource ?? .none
    }

    // MARK: - Initialization

    init() {
        DebugLog.write("AppState.init start daemonEnabled=\(DaemonClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        let config = AppConfig.current()
        channel = config.channel
        featureFlags = config.featureFlags
        loadLayoutMode()
        loadDormantOverrides()
        loadProjectOrder()
        if isIdeaCaptureEnabled {
            loadCreations()
        }

        activeProjectResolver = ActiveProjectResolver(
            sessionStateManager: sessionStateManager,
            shellStateStore: shellStateStore,
        )

        sessionStateCancellable = sessionStateManager.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleSessionStateRefresh()
            }

        terminalLauncher.onActivationTrace = { [weak self] trace in
            _Concurrency.Task { @MainActor in
                self?.activationTrace = trace
            }
        }

        terminalLauncher.onActivationResult = { [weak self] result in
            guard let self else { return }
            if !result.success {
                toast = ToastMessage(
                    "Couldn’t activate a terminal. Open Ghostty, iTerm2, or Terminal.app.",
                    isError: true,
                )
            }
        }

        do {
            engine = try HudEngine()

            ensureDaemonRunning()
            let cleanupStats = engine!.runStartupCleanup()
            if !cleanupStats.errors.isEmpty {
                DebugLog.write("[Startup] Cleanup errors: \(cleanupStats.errors.joined(separator: "; "))")
            }

            projectDetailsManager.configure(engine: engine)
            loadDashboard()
            checkHookDiagnostic()
            checkDaemonHealth()
            setupStalenessTimer()
            startShellTracking()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Setup

    private var hookHealthCheckCounter = 0
    private var statsRefreshCounter = 0
    private var daemonHealthCheckCounter = 0

    private func setupStalenessTimer() {
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.refreshSessionStates()
                if self.isIdeaCaptureEnabled {
                    self.checkIdeasFileChanges()
                }

                // Check hook diagnostic every ~10 seconds
                self.hookHealthCheckCounter += 1
                if self.hookHealthCheckCounter >= 5 {
                    self.hookHealthCheckCounter = 0
                    self.checkHookDiagnostic()
                }

                // Check daemon health every ~16 seconds
                self.daemonHealthCheckCounter += 1
                if self.daemonHealthCheckCounter >= 8 {
                    self.daemonHealthCheckCounter = 0
                    self.checkDaemonHealth()
                }

                // Refresh stats (including latestSummary from JSONL) every ~30 seconds
                self.statsRefreshCounter += 1
                if self.statsRefreshCounter >= 15 {
                    self.statsRefreshCounter = 0
                    self.loadDashboard()
                }
            }
        }
    }

    private func startShellTracking() {
        shellStateStore.startPolling()
        activeProjectResolver.updateProjects(projects)
    }

    // MARK: - Data Loading

    func loadDashboard() {
        guard let engine else { return }
        isLoading = true

        do {
            dashboard = try engine.loadDashboard()
            projects = dashboard?.projects ?? []
            if projects.isEmpty, suggestedProjects.isEmpty {
                refreshSuggestedProjects()
            }
            activeProjectResolver.updateProjects(projects)
            refreshSessionStates()
            refreshProjectStatuses()
            if isIdeaCaptureEnabled {
                projectDetailsManager.loadAllIdeas(for: projects)
            }
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func refreshSessionStates() {
        sessionStateManager.refreshSessionStates(for: projects)
        activeProjectResolver.resolve()
        #if DEBUG
            DiagnosticsSnapshotLogger.updateContext(
                activeProjectPath: activeProjectPath,
                activeSource: activeSource,
            )
        #endif
        DebugLog.write("AppState.refreshSessionStates activeProject=\(activeProjectResolver.activeProject?.path ?? "nil") source=\(String(describing: activeProjectResolver.activeSource))")
        if let active = activeProjectResolver.activeProject {
            Telemetry.emit("active_project_resolution", "Resolved active project", payload: [
                "project": active.name,
                "path": active.path,
                "source": String(describing: activeProjectResolver.activeSource),
            ])
        } else {
            Telemetry.emit("active_project_resolution", "No active project", payload: [
                "source": String(describing: activeProjectResolver.activeSource),
            ])
        }
    }

    func refreshProjectStatuses() {
        objectWillChange.send()
    }

    private func scheduleSessionStateRefresh() {
        // Debounce objectWillChange to prevent recursive layout crashes
        // when multiple sessions change rapidly (e.g., killing many sessions at once).
        // This coalesces rapid state changes into a single UI update.
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true

        refreshDebounceWork?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isRefreshScheduled = false
            self?.objectWillChange.send()
        }
        refreshDebounceWork = workItem

        // 16ms delay (~1 frame at 60fps) to coalesce updates within a single frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
    }

    // MARK: - Hook Diagnostic

    func checkHookDiagnostic() {
        guard let engine else { return }
        hookDiagnostic = engine.getHookDiagnostic()
    }

    func fixHooks() {
        guard let engine else { return }

        // First, install the bundled hook binary using the shared helper
        if let installError = HookInstaller.installBundledBinary(using: engine) {
            toast = ToastMessage(installError, isError: true)
            return
        }

        do {
            let result = try engine.installHooks()
            if result.success {
                checkHookDiagnostic()
                if hookDiagnostic?.isHealthy == true {
                    toast = ToastMessage("Hooks repaired")
                }
            } else {
                toast = ToastMessage(result.message, isError: true)
            }
        } catch {
            toast = ToastMessage(error.localizedDescription, isError: true)
        }
    }

    func testHooks() -> HookTestResult {
        guard let engine else {
            return HookTestResult(
                success: false,
                heartbeatOk: false,
                heartbeatAgeSecs: nil,
                stateFileOk: false,
                message: "Engine not initialized",
            )
        }
        return engine.runHookTest()
    }

    // MARK: - Daemon Diagnostic

    func ensureDaemonRunning() {
        daemonStatus = daemonStatusEvaluator.beginStartup(currentStatus: daemonStatus)
        _Concurrency.Task { @MainActor [weak self] in
            let errorMessage = await _Concurrency.Task.detached {
                DaemonService.ensureRunning()
            }.value
            if let message = errorMessage {
                self?.daemonStatus = DaemonStatus(
                    isEnabled: true,
                    isHealthy: false,
                    message: message,
                    pid: nil,
                    version: nil,
                )
            }
            self?.checkDaemonHealth()
        }
    }

    func checkDaemonHealth() {
        guard DaemonClient.shared.isEnabled else {
            daemonStatus = DaemonStatus(
                isEnabled: false,
                isHealthy: false,
                message: "Daemon disabled",
                pid: nil,
                version: nil,
            )
            Telemetry.emit("daemon_health", "Daemon disabled", payload: [
                "enabled": false,
            ])
            return
        }

        _Concurrency.Task { [weak self] in
            do {
                let health = try await DaemonClient.shared.fetchHealth()
                await MainActor.run {
                    guard let self else { return }
                    self.daemonRecoveryDecider.noteSuccess()
                    if let status = self.daemonStatusEvaluator.statusForHealthResult(
                        isEnabled: true,
                        result: .success(health),
                    ) {
                        self.daemonStatus = status
                        Telemetry.emit("daemon_health", "Daemon healthy", payload: [
                            "enabled": true,
                            "healthy": true,
                            "pid": health.pid,
                            "version": health.version,
                        ])
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if self.daemonRecoveryDecider.shouldAttemptRecovery(after: error) {
                        DebugLog.write("AppState.checkDaemonHealth triggering recovery error=\(error)")
                        self.ensureDaemonRunning()
                    }
                    if let status = self.daemonStatusEvaluator.statusForHealthResult(
                        isEnabled: true,
                        result: .failure(error),
                    ) {
                        self.daemonStatus = status
                        Telemetry.emit("daemon_health", "Daemon unhealthy", payload: [
                            "enabled": true,
                            "healthy": false,
                            "error": String(describing: error),
                        ])
                    }
                }
            }
        }
    }

    // MARK: - Project Management

    func refreshSuggestedProjects() {
        guard let engine else { return }
        do {
            suggestedProjects = try engine.getSuggestedProjects()
        } catch {
            DebugLog.write("AppState.refreshSuggestedProjects error=\(error.localizedDescription)")
            suggestedProjects = []
        }
    }

    func dismissSuggestedProjects() {
        suggestedProjects = []
    }

    func addSuggestedProject(_ suggestion: SuggestedProject) {
        guard let engine else { return }
        do {
            try engine.addProject(path: suggestion.path)
            prependToProjectOrder(suggestion.path)
            suggestedProjects.removeAll { $0.path == suggestion.path }
            loadDashboard()
            toast = ToastMessage("Connected \(suggestion.name)")
        } catch {
            toast = ToastMessage(error.localizedDescription, isError: true)
        }
    }

    func addSuggestedProjects(_ suggestions: [SuggestedProject]) {
        guard let engine else { return }
        var addedCount = 0
        for suggestion in suggestions {
            do {
                try engine.addProject(path: suggestion.path)
                prependToProjectOrder(suggestion.path)
                suggestedProjects.removeAll { $0.path == suggestion.path }
                addedCount += 1
            } catch {
                DebugLog.write("AppState.addSuggestedProjects error for \(suggestion.name): \(error.localizedDescription)")
            }
        }
        if addedCount > 0 {
            loadDashboard()
            toast = ToastMessage("Connected \(addedCount) project\(addedCount == 1 ? "" : "s")")
        }
    }

    func addProject(_ path: String) {
        guard let engine else { return }
        do {
            try engine.addProject(path: path)
            prependToProjectOrder(path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prependToProjectOrder(_ path: String) {
        customProjectOrder.removeAll { $0 == path }
        customProjectOrder.insert(path, at: 0)
        saveProjectOrder()
    }

    func connectProjectViaFileBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder to connect"
        panel.prompt = "Connect"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        showAddProject(withPath: url.path)
    }

    /// Connects multiple projects from a drag-and-drop operation.
    ///
    /// Toast priority: errors first, then success. For mixed results, shows
    /// "project-a, project-b and X more failed (Y connected)" to surface failures
    /// prominently while still acknowledging successes.
    ///
    /// Already-tracked projects are silently moved from Paused to In Progress
    /// if applicable, showing "Moved to In Progress" rather than an error.
    func addProjectsFromDrop(_ urls: [URL]) {
        guard engine != nil else { return }
        guard let worker = projectIngestionWorker else { return }

        // Navigate to list view first if not already there
        if projectView != .list {
            showProjectList()
        }

        let paths = urls.map(\.path)

        _Concurrency.Task { [weak self] in
            let outcome = await worker.addProjects(paths: paths)
            await MainActor.run {
                guard let self else { return }

                let finalAddedCount = outcome.addedCount
                let finalAddedPaths = outcome.addedPaths
                let finalAlreadyTrackedPaths = outcome.alreadyTrackedPaths
                let finalFailedNames = outcome.failedNames

                // Separate already-tracked projects into paused vs already in progress
                var movedCount = 0
                var alreadyInProgressCount = 0

                if !finalAlreadyTrackedPaths.isEmpty {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        for path in finalAlreadyTrackedPaths {
                            if self.manuallyDormant.contains(path) {
                                self.manuallyDormant.remove(path)
                                movedCount += 1
                            } else {
                                alreadyInProgressCount += 1
                            }
                        }
                    }
                }

                if finalAddedCount > 0 {
                    // Prepend newly added projects to the order (reversed so first dropped is at top)
                    for path in finalAddedPaths.reversed() {
                        self.prependToProjectOrder(path)
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        self.loadDashboard()
                    }
                }

                // Show appropriate toast with error-first formatting
                if !finalFailedNames.isEmpty {
                    let message = Self.formatMixedResultsToast(
                        failedNames: finalFailedNames,
                        connectedCount: finalAddedCount,
                    )
                    self.toast = .error(message)
                } else if finalAddedCount == 0 {
                    if movedCount > 0 {
                        self.toast = ToastMessage(
                            movedCount == 1 ? "Moved to In Progress" : "Moved \(movedCount) projects to In Progress",
                        )
                    } else if alreadyInProgressCount > 0 {
                        self.toast = ToastMessage("Already linked!")
                    }
                }
            }
        }
    }

    /// Formats a mixed results toast with truncation.
    /// Examples: "project-a failed (2 connected)", "project-a, project-b and 3 more failed (1 connected)"
    private static func formatMixedResultsToast(failedNames: [String], connectedCount: Int) -> String {
        let failedCount = failedNames.count

        // Build the failed portion with truncation (max 2 names shown)
        let failedPortion: String
        if failedCount == 1 {
            failedPortion = "\(failedNames[0]) failed"
        } else if failedCount == 2 {
            failedPortion = "\(failedNames[0]), \(failedNames[1]) failed"
        } else {
            let remainder = failedCount - 2
            failedPortion = "\(failedNames[0]), \(failedNames[1]) and \(remainder) more failed"
        }

        // Add success suffix if any were connected
        if connectedCount > 0 {
            return "\(failedPortion) (\(connectedCount) connected)"
        } else {
            return failedPortion
        }
    }

    func removeProject(_ path: String) {
        guard let engine else { return }
        do {
            try engine.removeProject(path: path)
            customProjectOrder.removeAll { $0 == path }
            manuallyDormant.remove(path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Validates a project path before adding.
    /// Returns the validation result for UI handling.
    func validateProject(_ path: String) -> ValidationResultFfi? {
        guard let engine else { return nil }
        return engine.validateProject(path: path)
    }

    /// Creates a CLAUDE.md file for a project.
    func createClaudeMd(for path: String) -> Bool {
        guard let engine else { return false }
        do {
            try engine.createProjectClaudeMd(projectPath: path)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Session State Access (delegating to manager)

    func getSessionState(for project: Project) -> ProjectSessionState? {
        sessionStateManager.getSessionState(for: project)
    }

    func isFlashing(_ project: Project) -> SessionState? {
        sessionStateManager.isFlashing(project)
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        engine?.getProjectStatus(projectPath: project.path)
    }

    // MARK: - Terminal Operations

    func launchTerminal(for project: Project) {
        activeProjectResolver.setManualOverride(project)
        activeProjectResolver.resolve()
        terminalLauncher.launchTerminal(for: project, shellState: shellStateStore.state)
        objectWillChange.send()
    }

    private func activeWorktreePathsForGuardrails() -> Set<String> {
        var paths: Set<String> = []

        if let shellPath = shellStateStore.mostRecentShell?.entry.cwd {
            paths.insert(PathNormalizer.normalize(shellPath))
        }

        for (projectPath, state) in sessionStateManager.sessionStates where state.state == .working {
            paths.insert(PathNormalizer.normalize(projectPath))
        }

        if let activePath = activeProjectPath {
            paths.insert(PathNormalizer.normalize(activePath))
        }

        return paths
    }

    // MARK: - Navigation

    func showProjectDetail(_ project: Project) {
        guard isProjectDetailsEnabled else { return }
        projectView = .detail(project)
    }

    func showAddProject(withPath path: String? = nil) {
        if let path {
            pendingProjectPath = path
        }
        projectView = .addLink
    }

    func showAddLink() {
        projectView = .addLink
    }

    func showNewIdea() {
        guard isProjectCreationEnabled else { return }
        projectView = .newIdea
    }

    func showProjectList() {
        projectView = .list
    }

    // MARK: - Layout Mode Persistence

    private func loadLayoutMode() {
        if let rawValue = UserDefaults.standard.string(forKey: layoutModeKey),
           let mode = LayoutMode(rawValue: rawValue)
        {
            layoutMode = mode
        }
    }

    private func saveLayoutMode() {
        UserDefaults.standard.set(layoutMode.rawValue, forKey: layoutModeKey)
    }

    // MARK: - Dormant/Order Persistence

    private func loadDormantOverrides() {
        manuallyDormant = DormantOverrideStore.load()
    }

    private func saveDormantOverrides() {
        DormantOverrideStore.save(manuallyDormant)
    }

    private func loadProjectOrder() {
        customProjectOrder = ProjectOrderStore.load()
    }

    private func saveProjectOrder() {
        ProjectOrderStore.save(customProjectOrder)
    }

    func orderedProjects(_ projects: [Project]) -> [Project] {
        ProjectOrdering.orderedProjects(projects, customOrder: customProjectOrder)
    }

    func moveProject(from source: IndexSet, to destination: Int, in projectList: [Project]) {
        customProjectOrder = ProjectOrdering.movedOrder(from: source, to: destination, in: projectList)
    }

    func moveToDormant(_ project: Project) {
        manuallyDormant.insert(project.path)
    }

    func moveToRecent(_ project: Project) {
        manuallyDormant.remove(project.path)
    }

    func isManuallyDormant(_ project: Project) -> Bool {
        manuallyDormant.contains(project.path)
    }

    // MARK: - Idea Capture (delegating to ProjectDetailsManager)

    func showIdeaCaptureModal(for project: Project, from origin: CGRect? = nil) {
        guard isIdeaCaptureEnabled else { return }
        captureModalProject = project
        captureModalOrigin = origin
        showCaptureModal = true
    }

    func captureIdea(for project: Project, text: String) -> Result<Void, Error> {
        guard isIdeaCaptureEnabled else {
            return .failure(AppFeatureError.ideaCaptureDisabled)
        }
        let result = projectDetailsManager.captureIdea(for: project, text: text)
        objectWillChange.send()
        return result
    }

    func checkIdeasFileChanges() {
        guard isIdeaCaptureEnabled else { return }
        projectDetailsManager.checkIdeasFileChanges(for: projects)
    }

    func getIdeas(for project: Project) -> [Idea] {
        guard isIdeaCaptureEnabled else { return [] }
        return projectDetailsManager.getIdeas(for: project)
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        guard isIdeaCaptureEnabled else { return false }
        return projectDetailsManager.isGeneratingTitle(for: ideaId)
    }

    func dismissIdea(_ idea: Idea, for project: Project) {
        guard isIdeaCaptureEnabled else { return }
        do {
            try projectDetailsManager.updateIdeaStatus(for: project, idea: idea, newStatus: "done")
        } catch {
            self.error = "Failed to dismiss idea: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project) {
        guard isIdeaCaptureEnabled else { return }
        projectDetailsManager.reorderIdeas(reorderedIdeas, for: project)
        objectWillChange.send()
    }

    // MARK: - Project Descriptions (delegating to ProjectDetailsManager)

    func getDescription(for project: Project) -> String? {
        guard isLlmFeaturesEnabled else { return nil }
        return projectDetailsManager.getDescription(for: project)
    }

    func isGeneratingDescription(for project: Project) -> Bool {
        guard isLlmFeaturesEnabled else { return false }
        return projectDetailsManager.isGeneratingDescription(for: project)
    }

    func generateDescription(for project: Project) {
        guard isLlmFeaturesEnabled else { return }
        projectDetailsManager.generateDescription(for: project)
    }

    // MARK: - Project Creation

    private func loadCreations() {
        let creationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/creations.json")

        guard FileManager.default.fileExists(atPath: creationsPath.path) else { return }

        do {
            let data = try Data(contentsOf: creationsPath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            activeCreations = try decoder.decode([ProjectCreation].self, from: data)
            cleanupCompletedCreations()
        } catch {
            // File doesn't exist or is invalid - start fresh
        }
    }

    private func saveCreations() {
        guard isIdeaCaptureEnabled else { return }
        let creationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/creations.json")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(activeCreations)
            try data.write(to: creationsPath)
        } catch {
            // Silently fail
        }
    }

    private func cleanupCompletedCreations() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        activeCreations = activeCreations.filter { creation in
            if creation.status == .completed || creation.status == .failed || creation.status == .cancelled {
                let completionDate = creation.completedAtDate ?? creation.createdAtDate ?? Date.distantPast
                return completionDate > cutoff
            }
            return true
        }
    }

    func startCreation(request: NewProjectRequest, projectPath: String) -> String {
        guard isIdeaCaptureEnabled else { return UUID().uuidString }
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let creation = ProjectCreation(
            id: id,
            name: request.name,
            path: projectPath,
            description: request.description,
            status: .pending,
            sessionId: nil,
            progress: CreationProgress(phase: "setup", message: "Initializing project...", percentComplete: 0),
            error: nil,
            createdAt: now,
            completedAt: nil,
        )
        activeCreations.insert(creation, at: 0)
        saveCreations()
        return id
    }

    func updateCreationStatus(_ id: String, status: CreationStatus, sessionId: String? = nil, error: String? = nil) {
        guard let index = activeCreations.firstIndex(where: { $0.id == id }) else { return }
        activeCreations[index].status = status
        if let sessionId {
            activeCreations[index].sessionId = sessionId
        }
        if let error {
            activeCreations[index].error = error
        }
        if status == .completed || status == .failed || status == .cancelled {
            activeCreations[index].completedAt = ISO8601DateFormatter().string(from: Date())
        }
        saveCreations()
    }

    func updateCreationProgress(_ id: String, phase: String, message: String, percentComplete: Int?) {
        guard let index = activeCreations.firstIndex(where: { $0.id == id }) else { return }
        activeCreations[index].progress = CreationProgress(
            phase: phase,
            message: message,
            percentComplete: percentComplete.map { UInt8(clamping: $0) },
        )
        saveCreations()
    }

    func cancelCreation(_ id: String) {
        updateCreationStatus(id, status: .cancelled)
    }

    func resumeCreation(_ id: String) {
        guard let creation = activeCreations.first(where: { $0.id == id }),
              let sessionId = creation.sessionId,
              creation.status == .failed || creation.status == .cancelled
        else {
            return
        }

        updateCreationStatus(id, status: .inProgress)
        updateCreationProgress(id, phase: "resuming", message: "Resuming session...", percentComplete: 30)

        _Concurrency.Task {
            do {
                try await launchClaudeResume(projectPath: creation.path, sessionId: sessionId, creationId: id)
            } catch {
                await MainActor.run {
                    updateCreationStatus(id, status: .failed, error: "Failed to resume: \(error.localizedDescription)")
                }
            }
        }
    }

    func canResumeCreation(_ id: String) -> Bool {
        guard let creation = activeCreations.first(where: { $0.id == id }) else {
            return false
        }
        return creation.sessionId != nil &&
            (creation.status == .failed || creation.status == .cancelled)
    }

    func createProjectFromIdea(_ request: NewProjectRequest, completion: @escaping (CreateProjectResult) -> Void) {
        guard isProjectCreationEnabled else {
            completion(CreateProjectResult(
                success: false,
                projectPath: "",
                sessionId: nil,
                error: AppFeatureError.projectCreationDisabled.errorDescription ?? "Project creation is disabled.",
            ))
            return
        }
        _Concurrency.Task {
            do {
                let result = try await createProjectAsync(request)
                await MainActor.run {
                    completion(result)
                }
            } catch {
                await MainActor.run {
                    completion(CreateProjectResult(
                        success: false,
                        projectPath: "",
                        sessionId: nil,
                        error: error.localizedDescription,
                    ))
                }
            }
        }
    }

    private func createProjectAsync(_ request: NewProjectRequest) async throws -> CreateProjectResult {
        let location = (request.location as NSString).expandingTildeInPath
        let sanitizedName = request.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let projectPath = (location as NSString).appendingPathComponent(sanitizedName)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: projectPath) {
            return CreateProjectResult(
                success: false,
                projectPath: projectPath,
                sessionId: nil,
                error: "Project directory already exists",
            )
        }

        let creationId = await MainActor.run {
            startCreation(request: request, projectPath: projectPath)
        }

        await MainActor.run {
            updateCreationProgress(creationId, phase: "setup", message: "Creating project directory...", percentComplete: 10)
        }

        try fileManager.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        await MainActor.run {
            updateCreationProgress(creationId, phase: "setup", message: "Generating CLAUDE.md...", percentComplete: 20)
        }

        let claudeMd = generateClaudeMd(request)
        let claudeMdPath = (projectPath as NSString).appendingPathComponent("CLAUDE.md")
        try claudeMd.write(toFile: claudeMdPath, atomically: true, encoding: .utf8)

        await MainActor.run {
            updateCreationProgress(creationId, phase: "building", message: "Launching Claude to build v1...", percentComplete: 30)
            updateCreationStatus(creationId, status: .inProgress)
        }

        let prompt = buildCreationPrompt(request)

        var sessionId: String?
        do {
            sessionId = try await runClaudeForProject(projectPath: projectPath, prompt: prompt, creationId: creationId)
        } catch {
            await MainActor.run {
                updateCreationStatus(creationId, status: .failed, error: "Failed to run Claude: \(error.localizedDescription)")
            }
            return CreateProjectResult(
                success: false,
                projectPath: projectPath,
                sessionId: nil,
                error: "Failed to run Claude: \(error.localizedDescription)",
            )
        }

        do {
            try engine?.addProject(path: projectPath)
        } catch {
            // Continue even if adding to HUD fails
        }

        await MainActor.run {
            updateCreationProgress(creationId, phase: "building", message: "Claude is building your project in the terminal...", percentComplete: 50)
        }

        return CreateProjectResult(
            success: true,
            projectPath: projectPath,
            sessionId: sessionId,
            error: nil,
        )
    }

    private func generateClaudeMd(_ request: NewProjectRequest) -> String {
        var content = "# \(request.name)\n\n"
        content += "## Overview\n\n"
        content += "\(request.description)\n\n"

        if request.language != nil || request.framework != nil {
            content += "## Tech Stack\n\n"
            if let language = request.language {
                content += "- Language: \(language.capitalized)\n"
            }
            if let framework = request.framework {
                content += "- Framework: \(framework)\n"
            }
            content += "\n"
        }

        content += "## Status\n\n"
        content += "🚀 Initial v1 bootstrap in progress\n"

        return content
    }

    private func buildCreationPrompt(_ request: NewProjectRequest) -> String {
        var prompt = """
        Create a working v1 of "\(request.name)".

        Description: \(request.description)

        """

        if let language = request.language {
            prompt += "Use \(language) as the primary language.\n"
        }

        if let framework = request.framework {
            prompt += "Use \(framework) as the framework.\n"
        }

        prompt += """

        Requirements:
        - Create a WORKING implementation, not just scaffolding
        - Include a README.md with clear usage instructions
        - Make it runnable with a simple command (npm start, cargo run, etc.)
        - Focus on functionality over perfection - a working v1 is the goal
        - Include basic error handling
        """

        return prompt
    }

    private func runClaudeForProject(projectPath: String, prompt: String, creationId: String) async throws -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let promptFile = tempDir.appendingPathComponent("claude-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        let existingSessions = getExistingSessionIds(for: projectPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            PROJECT_PATH="\(projectPath)"
            PROMPT_FILE="\(promptFile.path)"
            CLAUDE_CMD="/opt/homebrew/bin/claude \\"\\$(cat '$PROMPT_FILE')\\" ; rm -f '$PROMPT_FILE'"

            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH" -e bash -c "$CLAUDE_CMD"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "iTerm" to activate'
            elif [ -d "/Applications/Warp.app" ]; then
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "Terminal" to activate'
            else
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "Terminal" to activate'
            fi
        """]

        try process.run()

        startSessionMonitor(projectPath: projectPath, creationId: creationId, existingSessions: existingSessions)

        return nil
    }

    private func getExistingSessionIds(for projectPath: String) -> Set<String> {
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        let encodedPath = projectPath
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let sessionDir = claudeProjectsDir.appendingPathComponent(encodedPath)

        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil) else {
            return []
        }

        return Set(files
            .filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    private func startSessionMonitor(projectPath: String, creationId: String, existingSessions: Set<String>) {
        _Concurrency.Task {
            let maxAttempts = 60
            let pollInterval: UInt64 = 2_000_000_000

            for _ in 0 ..< maxAttempts {
                try? await _Concurrency.Task.sleep(nanoseconds: pollInterval)

                let currentSessions = getExistingSessionIds(for: projectPath)
                let newSessions = currentSessions.subtracting(existingSessions)

                if let sessionId = newSessions.first {
                    await MainActor.run {
                        updateCreationStatus(creationId, status: .inProgress, sessionId: sessionId)
                        updateCreationProgress(creationId, phase: "building", message: "Claude is building your project...", percentComplete: 40)
                    }
                    startCompletionMonitor(projectPath: projectPath, creationId: creationId, sessionId: sessionId)
                    return
                }
            }
        }
    }

    private func startCompletionMonitor(projectPath: String, creationId: String, sessionId: String) {
        _Concurrency.Task {
            let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")

            let encodedPath = projectPath
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

            let sessionFile = claudeProjectsDir
                .appendingPathComponent(encodedPath)
                .appendingPathComponent("\(sessionId).jsonl")

            var lastSize: UInt64 = 0
            var stableCount = 0
            let maxStableChecks = 30

            for _ in 0 ..< 300 {
                try? await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)

                guard let creation = activeCreations.first(where: { $0.id == creationId }),
                      creation.status == .inProgress
                else {
                    return
                }

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile.path),
                      let currentSize = attrs[.size] as? UInt64
                else {
                    continue
                }

                if currentSize == lastSize {
                    stableCount += 1
                    if stableCount >= maxStableChecks {
                        await MainActor.run {
                            updateCreationStatus(creationId, status: .completed)
                            updateCreationProgress(creationId, phase: "complete", message: "Project created successfully!", percentComplete: 100)
                            loadDashboard()
                        }
                        return
                    }
                } else {
                    stableCount = 0
                    lastSize = currentSize

                    let progress = min(90, 40 + (stableCount * 2))
                    await MainActor.run {
                        updateCreationProgress(creationId, phase: "building", message: "Claude is building your project...", percentComplete: progress)
                    }
                }
            }
        }
    }

    private func launchClaudeResume(projectPath: String, sessionId: String, creationId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            PROJECT_PATH="\(projectPath)"
            SESSION_ID="\(sessionId)"
            CLAUDE_CMD="/opt/homebrew/bin/claude --resume $SESSION_ID"

            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH" -e bash -c "$CLAUDE_CMD"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "iTerm" to activate'
            else
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "Terminal" to activate'
            fi
        """]

        try process.run()

        startCompletionMonitor(projectPath: projectPath, creationId: creationId, sessionId: sessionId)
    }
}
