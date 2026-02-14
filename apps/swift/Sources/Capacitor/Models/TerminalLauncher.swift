import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "TerminalLauncher")

private func telemetry(_ message: String, payload: [String: Any] = [:]) {
    let output = "[TELEMETRY] \(message)\n"
    FileHandle.standardError.write(Data(output.utf8))
    DebugLog.write("[TerminalLauncher] \(message)")
    Telemetry.emit("activation_log", message, payload: payload)
}

private func debugLog(_ message: String) {
    DebugLog.write("[TerminalLauncher] \(message)")
}

protocol AppleScriptClient {
    func run(_ script: String)
    func runChecked(_ script: String) -> Bool
}

private struct DefaultAppleScriptClient: AppleScriptClient {
    func run(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    func runChecked(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
                logger.warning("AppleScript failed (exit \(process.terminationStatus)): \(errorMsg)")
                debugLog("runAppleScriptChecked failed exit=\(process.terminationStatus) error=\(errorMsg)")
                return false
            }
            return true
        } catch {
            logger.error("AppleScript launch failed: \(error.localizedDescription)")
            debugLog("runAppleScriptChecked failed error=\(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - ParentApp Terminal Extensions

extension ParentApp {
    static let alphaSupportedTerminals: [ParentApp] = [
        .ghostty, .iTerm, .terminal,
    ]

    var isAlphaSupportedTerminal: Bool {
        Self.alphaSupportedTerminals.contains(self)
    }

    var bundlePath: String? {
        switch self {
        case .ghostty: "/Applications/Ghostty.app"
        case .iTerm: "/Applications/iTerm.app"
        case .alacritty: "/Applications/Alacritty.app"
        case .warp: "/Applications/Warp.app"
        case .terminal: "/System/Applications/Utilities/Terminal.app"
        case .kitty: nil
        default: nil
        }
    }

    var isInstalled: Bool {
        guard category == .terminal, isAlphaSupportedTerminal else { return false }
        if self == .terminal {
            let candidates = [
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Utilities/Terminal.app",
            ]
            return candidates.contains { FileManager.default.fileExists(atPath: $0) }
        }
        guard let path = bundlePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    static let terminalPriorityOrder: [ParentApp] = [
        .ghostty, .iTerm, .terminal,
    ]

    var runningAppMatchNames: [String] {
        switch self {
        case .terminal: ["Terminal", "Terminal.app"]
        case .iTerm: ["iTerm", "iTerm2", "iTerm.app"]
        case .ghostty: ["Ghostty"]
        case .alacritty: ["Alacritty"]
        case .kitty: ["kitty"]
        case .warp: ["Warp", "WarpTerminal"]
        default: [displayName]
        }
    }

    func matchesRunningAppName(_ localizedName: String) -> Bool {
        let lower = localizedName.lowercased()
        return runningAppMatchNames.contains { lower.contains($0.lowercased()) }
    }

    var processName: String? {
        switch self {
        case .cursor: "Cursor"
        case .vsCode: "Code"
        case .vsCodeInsiders: "Code - Insiders"
        case .zed: "Zed"
        default: nil
        }
    }

    var cliBinary: String? {
        switch self {
        case .cursor: "cursor"
        case .vsCode: "code"
        case .vsCodeInsiders: "code-insiders"
        case .zed: "zed"
        default: nil
        }
    }
}

// MARK: - TerminalType Display Name Extension

extension TerminalType {
    var appName: String {
        switch self {
        case .iTerm: "iTerm"
        case .terminalApp: "Terminal"
        case .ghostty: "Ghostty"
        case .alacritty: "Alacritty"
        case .kitty: "kitty"
        case .warp: "Warp"
        case .unknown: ""
        }
    }
}

// MARK: - Shell Escape Utilities

/// Escapes a string for safe use in single-quoted shell arguments.
/// Handles single quotes by ending the quote, adding an escaped quote, and starting a new quote.
/// Example: "foo'bar" becomes "'foo'\''bar'"
private func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Escapes a string for safe interpolation into a bash double-quoted string.
/// Escapes: backslash, double quote, dollar sign, and backticks.
/// Example: "foo$bar" becomes "foo\$bar"
private func bashDoubleQuoteEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
}

// MARK: - Terminal Launcher

struct TerminalActivationResult: Equatable {
    let projectName: String
    let projectPath: String
    let success: Bool
    let usedFallback: Bool
}

//
// Handles "click project → focus terminal" activation. The goal is to bring the user
// to their existing terminal window for a project, not spawn new windows unnecessarily.
//
// ACTIVATION PRIORITY (ordered by user intent signal strength):
//
//   1. Active shell in daemon snapshot → User has a terminal window open RIGHT NOW
//      These are verified-live PIDs from recent shell hook activity.
//
//   2. Tmux session at project path → User has a session but may not be attached
//      Queried directly from tmux, may exist even without recent shell activity.
//
//   3. Launch new terminal → No existing terminal for this project
//
// WHY THIS ORDER MATTERS:
// Previously, tmux was checked first. This caused a bug: if a user had a Ghostty
// window open (non-tmux) AND a tmux session existed at the same path, clicking
// the project would open a NEW window in tmux instead of focusing the existing
// Ghostty window. The daemon shell snapshot finds the actively-used terminal.

@MainActor
final class TerminalLauncher: ActivationActionDependencies {
    enum GhosttyWindowDecision: Equatable {
        case activateAndSwitch
        case launchNew
    }

    private enum Constants {
        static let activationDelaySeconds: Double = 0.3
        static let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
        static let ghosttySessionCacheDuration: TimeInterval = 30.0
    }

    private let appleScript: AppleScriptClient
    var onActivationTrace: ((String) -> Void)?
    var onActivationResult: ((TerminalActivationResult) -> Void)?
    private lazy var executor: ActivationActionExecutor = {
        let tmuxAdapter = TmuxClientAdapter(
            hasAnyClientAttached: { [weak self] in
                await self?.hasAnyClientAttachedInternal() ?? false
            },
            getCurrentClientTty: { [weak self] in
                await self?.getCurrentClientTtyInternal()
            },
            switchClient: { [weak self] sessionName, clientTty in
                await self?.switchClientInternal(to: sessionName, clientTty: clientTty) ?? false
            },
        )

        let terminalDiscovery = TerminalDiscoveryAdapter(
            activateTerminalByTTY: { [weak self] tty in
                await self?.activateTerminalByTTYDiscovery(tty: tty) ?? false
            },
            activateAppByName: { [weak self] appName in
                self?.activateAppAction(appName: appName) ?? false
            },
            isGhosttyRunning: { [weak self] in
                self?.isGhosttyRunningInternal() ?? false
            },
            countGhosttyWindows: { [weak self] in
                self?.countGhosttyWindowsInternal() ?? 0
            },
        )

        let terminalLauncher = TerminalLauncherAdapter(
            launchTerminalWithTmux: { [weak self] sessionName in
                self?.launchTerminalWithTmuxSession(sessionName)
            },
        )

        return ActivationActionExecutor(
            dependencies: self,
            tmuxClient: tmuxAdapter,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: terminalLauncher,
        )
    }()

    // Cache: tracks tmux sessions where we recently launched a Ghostty window.
    // Prevents re-launching on rapid clicks when window count > 1.
    private static var recentlyLaunchedGhosttySessions: [String: Date] = [:]
    private static let activationTraceEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["CAPACITOR_ACTIVATION_TRACE"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }()

    // MARK: - Public API

    init(appleScript: AppleScriptClient = DefaultAppleScriptClient()) {
        self.appleScript = appleScript
    }

    func launchTerminal(for project: Project, shellState: ShellCwdState? = nil) {
        _Concurrency.Task {
            await launchTerminalAsync(for: project, shellState: shellState)
        }
    }

    private func launchTerminalAsync(for project: Project, shellState: ShellCwdState? = nil) async {
        if AppConfig.current().featureFlags.areLauncher {
            let handledWithARE = await launchTerminalWithAERSnapshot(for: project)
            if handledWithARE {
                return
            }
        }
        await launchTerminalWithRustResolver(for: project, shellState: shellState)
    }

    static func performSwitchTmuxSession(
        sessionName: String,
        projectPath _: String,
        runScript: (String) async -> (exitCode: Int32, output: String?),
        activateTerminal: (String?) async -> Bool,
    ) async -> Bool {
        let clientTty = await resolveAttachedTmuxClientTty(runScript: runScript)
        let escapedSession = shellEscape(sessionName)
        let switchCommand: String
        if let clientTty, !clientTty.isEmpty {
            let escapedClientTty = shellEscape(clientTty)
            switchCommand = "tmux switch-client -c \(escapedClientTty) -t \(escapedSession) 2>&1"
        } else {
            switchCommand = "tmux switch-client -t \(escapedSession) 2>&1"
        }
        let switchResult = await runScript(switchCommand)
        if switchResult.exitCode == 0 {
            return await activateTerminal(clientTty)
        }
        return false
    }

    static func performEnsureTmuxSession(
        sessionName: String,
        projectPath: String,
        runScript: (String) async -> (exitCode: Int32, output: String?),
        activateTerminal: (String?) async -> Bool,
    ) async -> Bool {
        let clientTty = await resolveAttachedTmuxClientTty(runScript: runScript)
        let escapedSession = shellEscape(sessionName)
        let switchCommand: String
        if let clientTty, !clientTty.isEmpty {
            let escapedClientTty = shellEscape(clientTty)
            switchCommand = "tmux switch-client -c \(escapedClientTty) -t \(escapedSession) 2>&1"
        } else {
            switchCommand = "tmux switch-client -t \(escapedSession) 2>&1"
        }
        let switchResult = await runScript(switchCommand)
        if switchResult.exitCode == 0 {
            return await activateTerminal(clientTty)
        }

        let escapedPath = shellEscape(projectPath)
        let createResult = await runScript(
            "tmux new-session -d -s \(escapedSession) -c \(escapedPath) 2>&1",
        )
        if createResult.exitCode != 0 {
            return false
        }

        let retryResult = await runScript(switchCommand)
        if retryResult.exitCode == 0 {
            return await activateTerminal(clientTty)
        }

        return false
    }

    static func resolveAttachedTmuxClientTty(
        runScript: (String) async -> (exitCode: Int32, output: String?),
    ) async -> String? {
        let result = await runScript("tmux display-message -p '#{client_tty}' 2>/dev/null")
        if result.exitCode == 0,
           let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty
        {
            return output
        }

        // App-triggered activation usually runs outside a tmux client, so
        // `display-message` cannot resolve #{client_tty}. Fall back to any
        // attached client to make switch-client deterministic.
        let clients = await runScript("tmux list-clients -F '#{client_tty}' 2>/dev/null")
        guard clients.exitCode == 0,
              let output = clients.output
        else {
            return nil
        }

        for line in output.split(separator: "\n") {
            let tty = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tty.isEmpty {
                return tty
            }
        }

        return nil
    }

    nonisolated static func ghosttyOwnerPid(forTTY tty: String, processSnapshot: String) -> Int32? {
        struct ProcRow {
            let pid: Int32
            let ppid: Int32
            let tty: String
            let command: String
        }

        let normalizedTTY = tty
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/dev/", with: "")
        guard !normalizedTTY.isEmpty else { return nil }

        var rowsByPid: [Int32: ProcRow] = [:]
        for rawLine in processSnapshot.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1])
            else {
                continue
            }

            rowsByPid[pid] = ProcRow(pid: pid, ppid: ppid, tty: parts[2], command: parts[3])
        }

        let candidatePids = rowsByPid.values
            .filter { $0.tty == normalizedTTY }
            .map(\.pid)

        for candidate in candidatePids {
            var current: Int32? = candidate
            var hops = 0
            while let pid = current, hops < 64 {
                guard let row = rowsByPid[pid] else { break }
                if row.command.contains("/Applications/Ghostty.app/Contents/MacOS/ghostty") {
                    return row.pid
                }
                current = row.ppid > 1 ? row.ppid : nil
                hops += 1
            }
        }

        return nil
    }

    static func ghosttyWindowDecision(windowCount _: Int, anyClientAttached: Bool) -> GhosttyWindowDecision {
        if !anyClientAttached {
            return .launchNew
        }

        // If a tmux client is attached, prefer activating Ghostty and switching
        // sessions over spawning new windows. Users can pick the correct window.
        return .activateAndSwitch
    }

    // MARK: - Rust Resolver Path

    private func launchTerminalWithAERSnapshot(for project: Project) async -> Bool {
        do {
            let snapshot = try await DaemonClient.shared.fetchRoutingSnapshot(
                projectPath: project.path,
                workspaceId: nil,
            )
            let primary = Self.activationActionFromAERSnapshot(
                snapshot,
                projectPath: project.path,
                projectName: project.name,
            )
            logger.info(
                "ARE launcher snapshot: status=\(snapshot.status) target=\(snapshot.target.kind):\(snapshot.target.value ?? "nil") reason_code=\(snapshot.reasonCode)",
            )
            Telemetry.emit("activation_decision", "are_snapshot", payload: [
                "primary": String(describing: primary),
                "reason_code": snapshot.reasonCode,
                "status": snapshot.status,
                "target_kind": snapshot.target.kind,
                "target_value": snapshot.target.value ?? "",
            ])

            let primarySuccess = await executeActivationAction(primary, projectPath: project.path, projectName: project.name)
            var fallbackSuccess = false
            var usedFallback = false
            if !primarySuccess {
                let primaryIsLaunchNew = if case .launchNewTerminal = primary {
                    true
                } else {
                    false
                }
                if !primaryIsLaunchNew {
                    usedFallback = true
                    let fallback = ActivationAction.launchNewTerminal(
                        projectPath: project.path,
                        projectName: project.name,
                    )
                    fallbackSuccess = await executeActivationAction(
                        fallback,
                        projectPath: project.path,
                        projectName: project.name,
                    )
                }
            }

            let finalSuccess = primarySuccess || fallbackSuccess
            onActivationResult?(TerminalActivationResult(
                projectName: project.name,
                projectPath: project.path,
                success: finalSuccess,
                usedFallback: usedFallback,
            ))
            return true
        } catch {
            logger.warning("ARE launcher snapshot unavailable, falling back to resolver: \(error.localizedDescription)")
            Telemetry.emit("activation_decision", "are_snapshot_fetch_failed", payload: [
                "project": project.name,
                "path": project.path,
                "error": error.localizedDescription,
            ])
            return false
        }
    }

    static func activationActionFromAERSnapshot(
        _ snapshot: DaemonRoutingSnapshot,
        projectPath: String,
        projectName: String,
    ) -> ActivationAction {
        if snapshot.target.kind == "tmux_session",
           let sessionName = snapshot.target.value,
           !sessionName.isEmpty
        {
            if snapshot.status == "attached" {
                if let hostTty = tmuxHostTTY(from: snapshot) {
                    return .activateHostThenSwitchTmux(hostTty: hostTty, sessionName: sessionName)
                }
                return .switchTmuxSession(sessionName: sessionName)
            }
            if snapshot.status == "detached" {
                return .ensureTmuxSession(sessionName: sessionName, projectPath: projectPath)
            }
        }

        if snapshot.target.kind == "terminal_app",
           snapshot.status == "detached" || snapshot.status == "attached",
           let appName = snapshot.target.value,
           !appName.isEmpty
        {
            return .activateApp(appName: appName)
        }

        return .launchNewTerminal(projectPath: projectPath, projectName: projectName)
    }

    private static func tmuxHostTTY(from snapshot: DaemonRoutingSnapshot) -> String? {
        snapshot.evidence
            .first(where: { $0.evidenceType == "tmux_client" })
            .flatMap { evidence in
                let trimmed = evidence.value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    private func launchTerminalWithRustResolver(for project: Project, shellState: ShellCwdState? = nil) async {
        logger.info("━━━ ACTIVATION START: \(project.name) ━━━")
        telemetry(" ━━━ ACTIVATION START: \(project.name) ━━━", payload: [
            "project": project.name,
            "path": project.path,
        ])
        Telemetry.emit("activation_start", "Activation started", payload: [
            "project": project.name,
            "path": project.path,
        ])
        logger.info("  Project path: \(project.path)")

        if !ParentApp.alphaSupportedTerminals.contains(where: \.isInstalled) {
            logger.error("  No supported terminals installed")
            telemetry(" Activation failed: no supported terminals installed", payload: [
                "project": project.name,
                "path": project.path,
            ])
            onActivationResult?(TerminalActivationResult(
                projectName: project.name,
                projectPath: project.path,
                success: false,
                usedFallback: false,
            ))
            return
        }

        if let state = shellState {
            logger.info("  Shell state provided: \(state.shells.count) shells")
            for (pid, entry) in state.shells {
                let isLive = isLiveShell((pid, entry))
                logger.debug("    pid=\(pid) cwd=\(entry.cwd) tty=\(entry.tty) parent=\(entry.parentApp ?? "nil") live=\(isLive)")
            }
        } else {
            logger.info("  Shell state: nil")
        }

        let ffiShellState = shellState.map { convertToFfi($0) }
        let tmuxContext = await queryTmuxContext(projectPath: project.path)

        logger.info("  Tmux context: session=\(tmuxContext.sessionAtPath ?? "nil"), hasClients=\(tmuxContext.hasAttachedClient)")

        guard let engine = try? HudEngine() else {
            logger.warning("Failed to create HudEngine, launching new terminal as fallback")
            launchNewTerminal(for: project)
            return
        }

        let traceEnabled = Self.activationTraceEnabled
        let decision = traceEnabled
            ? engine.resolveActivationWithTrace(
                projectPath: project.path,
                shellState: ffiShellState,
                tmuxContext: tmuxContext,
                includeTrace: true,
            )
            : engine.resolveActivation(
                projectPath: project.path,
                shellState: ffiShellState,
                tmuxContext: tmuxContext,
            )

        logger.info("  Decision: \(decision.reason)")
        telemetry(" Decision: \(decision.reason)", payload: [
            "reason": decision.reason,
        ])
        logger.info("  Primary action: \(String(describing: decision.primary))")
        telemetry(" Primary action: \(String(describing: decision.primary))", payload: [
            "primary": String(describing: decision.primary),
            "fallback": decision.fallback.map { String(describing: $0) } ?? "none",
        ])
        Telemetry.emit("activation_decision", decision.reason, payload: [
            "primary": String(describing: decision.primary),
            "fallback": decision.fallback.map { String(describing: $0) } ?? "none",
        ])
        if let fallback = decision.fallback {
            logger.info("  Fallback action: \(String(describing: fallback))")
        }
        if traceEnabled, let trace = decision.trace {
            logActivationTrace(trace)
        }

        let primarySuccess = await executeActivationAction(decision.primary, projectPath: project.path, projectName: project.name)
        logger.info("  Primary action result: \(primarySuccess ? "SUCCESS" : "FAILED")")
        telemetry(" Primary action result: \(primarySuccess ? "SUCCESS" : "FAILED")", payload: [
            "result": primarySuccess ? "success" : "failed",
        ])
        Telemetry.emit("activation_primary_result", primarySuccess ? "success" : "failed", payload: [
            "project": project.name,
            "path": project.path,
        ])

        var fallbackSuccess = false
        if !primarySuccess, let fallback = decision.fallback {
            logger.info("  ▸ Primary failed, executing fallback: \(String(describing: fallback))")
            fallbackSuccess = await executeActivationAction(fallback, projectPath: project.path, projectName: project.name)
            logger.info("  Fallback result: \(fallbackSuccess ? "SUCCESS" : "FAILED")")
            Telemetry.emit("activation_fallback_result", fallbackSuccess ? "success" : "failed", payload: [
                "project": project.name,
                "path": project.path,
            ])
        }
        let finalSuccess = primarySuccess || fallbackSuccess
        let usedFallback = !primarySuccess && decision.fallback != nil
        let result = TerminalActivationResult(
            projectName: project.name,
            projectPath: project.path,
            success: finalSuccess,
            usedFallback: usedFallback,
        )
        onActivationResult?(result)
        logger.info("━━━ ACTIVATION END ━━━")
    }

    // MARK: - Type Conversion to FFI

    private func convertToFfi(_ state: ShellCwdState) -> ShellCwdStateFfi {
        var ffiShells: [String: ShellEntryFfi] = [:]

        for (pid, entry) in state.shells {
            let parentApp = ParentApp(fromString: entry.parentApp)
            let sanitizedParentApp = parentApp.isAlphaSupportedTerminal || parentApp.category == .multiplexer
                ? parentApp
                : .unknown
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Check liveness and pass to Rust instead of filtering here
            let isLive = isLiveShell((pid, entry))

            ffiShells[pid] = ShellEntryFfi(
                cwd: entry.cwd,
                tty: entry.tty,
                parentApp: sanitizedParentApp,
                tmuxSession: entry.tmuxSession,
                tmuxClientTty: entry.tmuxClientTty,
                updatedAt: formatter.string(from: entry.updatedAt),
                isLive: isLive,
            )
        }

        return ShellCwdStateFfi(version: UInt32(state.version), shells: ffiShells)
    }

    private func queryTmuxContext(projectPath: String) async -> TmuxContextFfi {
        let sessionAtPath = await findTmuxSessionForPath(projectPath)
        logger.debug("  queryTmuxContext: findTmuxSessionForPath('\(projectPath)') → \(sessionAtPath ?? "nil")")

        // Check if ANY tmux client is attached (regardless of which session).
        // This is crucial: if a client is viewing session A and we want to activate
        // session B, we can still `tmux switch-client` to B. We only need to launch
        // a new terminal if NO clients exist at all.
        let hasAttached = await hasAnyClientAttachedInternal()
        logger.debug("  queryTmuxContext: hasTmuxClientAttached() → \(hasAttached)")

        return TmuxContextFfi(
            sessionAtPath: sessionAtPath,
            hasAttachedClient: hasAttached,
            homeDir: NSHomeDirectory(),
        )
    }

    // MARK: - Action Execution

    private func executeActivationAction(_ action: ActivationAction, projectPath: String, projectName: String) async -> Bool {
        debugLog("executeActivationAction action=\(String(describing: action))")
        logger.debug("Executing activation action: \(String(describing: action))")
        let result = await executor.execute(action, projectPath: projectPath, projectName: projectName)
        logger.debug("Activation action result: \(result ? "SUCCESS" : "FAILED")")
        return result
    }

    private func logActivationTrace(_ trace: DecisionTraceFfi) {
        let formatted = formatActivationTrace(trace: trace)
        debugLog(formatted)
        onActivationTrace?(formatted)
        Telemetry.emit("activation_trace", "Activation trace", payload: [
            "trace": formatted,
        ])
    }

    // MARK: - Action Helpers

    private func activateAppAction(appName: String) -> Bool {
        logger.info("  ▸ activateApp: \(appName)")
        let result = activateAppByName(appName)
        logger.info("  ▸ activateApp result: \(result ? "SUCCESS" : "FAILED")")
        return result
    }

    private func activateKittyWindowAction(shellPid: UInt32) -> Bool {
        logger.info("  ▸ activateKittyWindow: pid=\(shellPid)")
        debugLog("activateKittyWindow pid=\(shellPid)")
        let activated = activateAppByName("kitty")
        if activated {
            runBashScript("kitty @ focus-window --match pid:\(shellPid) 2>/dev/null")
        }
        logger.info("  ▸ activateKittyWindow result: \(activated ? "SUCCESS" : "FAILED")")
        return activated
    }

    private func switchTmuxSessionAction(sessionName: String, projectPath: String) async -> Bool {
        logger.info("  ▸ switchTmuxSession: \(sessionName)")
        debugLog("switchTmuxSession session=\(sessionName)")
        let succeeded = await Self.performSwitchTmuxSession(
            sessionName: sessionName,
            projectPath: projectPath,
            runScript: { await runBashScriptWithResultAsync($0) },
            activateTerminal: { tty in await self.activateTerminalAfterTmuxSwitch(clientTty: tty) },
        )
        if !succeeded {
            logger.warning("  ▸ tmux switch failed for session '\(sessionName)'")
            debugLog("switchTmuxSession failed session=\(sessionName)")
            return false
        }
        logger.info("  ▸ switchTmuxSession result: SUCCESS")
        return true
    }

    private func ensureTmuxSessionAction(sessionName: String, projectPath: String) async -> Bool {
        logger.info("  ▸ ensureTmuxSession: \(sessionName)")
        debugLog("ensureTmuxSession session=\(sessionName)")
        let succeeded = await Self.performEnsureTmuxSession(
            sessionName: sessionName,
            projectPath: projectPath,
            runScript: { await runBashScriptWithResultAsync($0) },
            activateTerminal: { tty in await self.activateTerminalAfterTmuxSwitch(clientTty: tty) },
        )
        if !succeeded {
            logger.warning("  ▸ tmux ensure/create failed for session '\(sessionName)'")
            debugLog("ensureTmuxSession failed session=\(sessionName)")
            return false
        }
        logger.info("  ▸ ensureTmuxSession result: SUCCESS")
        return true
    }

    private func activateHostThenSwitchTmuxAction(hostTty: String, sessionName: String, projectPath: String) async -> Bool {
        logger.info("  ▸ activateHostThenSwitchTmux: hostTty=\(hostTty), session=\(sessionName)")
        debugLog("activateHostThenSwitchTmux hostTty=\(hostTty) session=\(sessionName) path=\(projectPath)")
        return await executor.activateHostThenSwitchTmux(
            hostTty: hostTty,
            sessionName: sessionName,
            projectPath: projectPath,
        )
    }

    private func launchTerminalWithTmuxAction(sessionName: String, projectPath: String) -> Bool {
        logger.info("  ▸ launchTerminalWithTmux: session=\(sessionName), path=\(projectPath)")
        debugLog("launchTerminalWithTmux session=\(sessionName) path=\(projectPath)")
        launchTerminalWithTmuxSession(sessionName, projectPath: projectPath)
        logger.info("  ▸ launchTerminalWithTmux: launched")
        return true
    }

    private func launchNewTerminalAction(projectPath: String, projectName: String) -> Bool {
        logger.info("  ▸ launchNewTerminal: path=\(projectPath), name=\(projectName)")
        debugLog("launchNewTerminal path=\(projectPath) name=\(projectName)")
        launchNewTerminal(forPath: projectPath, name: projectName)
        logger.info("  ▸ launchNewTerminal: launched")
        return true
    }

    private func activatePriorityFallbackAction() -> Bool {
        logger.warning("  ⚠️ activatePriorityFallback: FALLBACK PATH - activating first running terminal")
        debugLog("activatePriorityFallback (activating first running terminal)")
        if ParentApp.ghostty.isInstalled {
            let ghosttyRunning = isGhosttyRunningInternal()
            let windowCount = ghosttyRunning ? countGhosttyWindowsInternal() : 0
            if !ghosttyRunning {
                logger.warning("  ⚠️ activatePriorityFallback: Ghostty installed but not running; allowing fallback launch")
                debugLog("activatePriorityFallback ghostty not running -> return false")
                return false
            }
            if windowCount == 0 {
                logger.warning("  ⚠️ activatePriorityFallback: Ghostty running with zero windows; allowing fallback launch")
                debugLog("activatePriorityFallback ghostty windowCount=0 -> return false")
                return false
            }
        }
        let activated = activateFirstRunningTerminal()
        logger.warning("  ⚠️ activatePriorityFallback: completed (may have focused wrong window)")
        return activated
    }

    func activateByTtyAction(tty: String, terminalType: TerminalType) async -> Bool {
        logger.info("    activateByTtyAction: tty=\(tty), terminalType=\(String(describing: terminalType))")
        debugLog("activateByTtyAction tty=\(tty) terminalType=\(String(describing: terminalType))")

        switch terminalType {
        case .iTerm:
            return activateITermSession(tty: tty)
        case .terminalApp:
            return activateTerminalAppSession(tty: tty)
        case .ghostty:
            debugLog("activateByTtyAction ghostty heuristic tty=\(tty)")
            return await activateGhosttyWithHeuristic(forTty: tty)
        case .alacritty, .warp:
            return activateAppByName(terminalType.appName)
        case .kitty:
            return activateAppByName("kitty")
        case .unknown:
            logger.info("    activateByTtyAction: unknown type, attempting TTY discovery")
            debugLog("activateByTtyAction unknown terminalType; starting TTY discovery tty=\(tty)")
            if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
                logger.info("    TTY discovery found: \(owningTerminal.displayName) for tty=\(tty)")
                debugLog("activateByTtyAction tty discovery found terminal=\(owningTerminal.displayName) tty=\(tty)")
                switch owningTerminal {
                case .iTerm:
                    return activateITermSession(tty: tty)
                case .terminal:
                    return activateTerminalAppSession(tty: tty)
                case .ghostty:
                    return await activateGhosttyWithHeuristic(forTty: tty)
                default:
                    return activateAppByName(owningTerminal.displayName)
                }
            }

            logger.info("    TTY discovery failed, checking if Ghostty is running")
            debugLog("activateByTtyAction tty discovery failed tty=\(tty); ghosttyRunning=\(isGhosttyRunningInternal())")
            if isGhosttyRunningInternal() {
                logger.info("    Ghostty is running, trying Ghostty heuristic as fallback")
                return await activateGhosttyWithHeuristic(forTty: tty)
            }

            logger.info("    No known terminal found for TTY")
            debugLog("activateByTtyAction no known terminal for tty=\(tty)")
            return false
        }
    }

    private func activateGhosttyWithHeuristic(forTty tty: String) async -> Bool {
        guard isGhosttyRunningInternal() else {
            logger.info("    activateGhosttyWithHeuristic: Ghostty not running")
            debugLog("activateGhosttyWithHeuristic ghostty not running tty=\(tty)")
            return false
        }

        let windowCount = countGhosttyWindowsInternal()
        logger.info("    activateGhosttyWithHeuristic: tty=\(tty), windowCount=\(windowCount)")
        debugLog("activateGhosttyWithHeuristic tty=\(tty) windowCount=\(windowCount)")

        if windowCount == 1 {
            logger.info("    activateGhosttyWithHeuristic: single window → activating")
            debugLog("activateGhosttyWithHeuristic single window → activate")
            runAppleScript("tell application \"Ghostty\" to activate")
            return true
        } else if windowCount == 0 {
            logger.info("    activateGhosttyWithHeuristic: no windows → returning false")
            debugLog("activateGhosttyWithHeuristic windowCount=0 → return false")
            return false
        } else {
            logger.info("    activateGhosttyWithHeuristic: multiple windows (\(windowCount)) → activating Ghostty (user may need to switch windows)")
            debugLog("activateGhosttyWithHeuristic windowCount=\(windowCount) → activate (no selection)")
            runAppleScript("tell application \"Ghostty\" to activate")
            return true
        }
    }

    private func activateIdeWindowAction(ideType: IdeType, projectPath: String) async -> Bool {
        let parentApp: ParentApp = switch ideType {
        case .cursor: .cursor
        case .vsCode: .vsCode
        case .vsCodeInsiders: .vsCodeInsiders
        case .zed: .zed
        }

        guard findRunningIDE(parentApp) != nil else { return false }
        return await activateIDEWindowInternal(app: parentApp, projectPath: projectPath)
    }

    // MARK: - ActivationActionDependencies

    func activateByTty(tty: String, terminalType: TerminalType) async -> Bool {
        let result = await activateByTtyAction(tty: tty, terminalType: terminalType)
        logger.info("  ▸ activateByTty result: \(result ? "SUCCESS" : "FAILED")")
        return result
    }

    func activateApp(appName: String) -> Bool {
        activateAppAction(appName: appName)
    }

    func activateKittyWindow(shellPid: UInt32) -> Bool {
        activateKittyWindowAction(shellPid: shellPid)
    }

    func activateIdeWindow(ideType: IdeType, projectPath: String) async -> Bool {
        logger.info("  ▸ activateIdeWindow: ide=\(String(describing: ideType)), path=\(projectPath)")
        debugLog("activateIdeWindow ide=\(String(describing: ideType)) path=\(projectPath)")
        let result = await activateIdeWindowAction(ideType: ideType, projectPath: projectPath)
        logger.info("  ▸ activateIdeWindow result: \(result ? "SUCCESS" : "FAILED")")
        return result
    }

    func switchTmuxSession(sessionName: String, projectPath: String) async -> Bool {
        await switchTmuxSessionAction(sessionName: sessionName, projectPath: projectPath)
    }

    func ensureTmuxSession(sessionName: String, projectPath: String) async -> Bool {
        await ensureTmuxSessionAction(sessionName: sessionName, projectPath: projectPath)
    }

    func activateHostThenSwitchTmux(hostTty: String, sessionName: String, projectPath: String) async -> Bool {
        await activateHostThenSwitchTmuxAction(
            hostTty: hostTty,
            sessionName: sessionName,
            projectPath: projectPath,
        )
    }

    func launchTerminalWithTmux(sessionName: String, projectPath: String) -> Bool {
        launchTerminalWithTmuxAction(sessionName: sessionName, projectPath: projectPath)
    }

    func launchNewTerminal(projectPath: String, projectName: String) -> Bool {
        launchNewTerminalAction(projectPath: projectPath, projectName: projectName)
    }

    func activatePriorityFallback() -> Bool {
        activatePriorityFallbackAction()
    }

    // MARK: - Adapter Helpers

    private func hasAnyClientAttachedInternal() async -> Bool {
        let result = await runBashScriptWithResultAsync("tmux list-clients 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func getCurrentClientTtyInternal() async -> String? {
        let result = await runBashScriptWithResultAsync("tmux display-message -p '#{client_tty}' 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return nil }
        let tty = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? nil : tty
    }

    private func switchClientInternal(to sessionName: String, clientTty: String?) async -> Bool {
        let escapedSession = shellEscape(sessionName)
        let script: String
        if let clientTty, !clientTty.isEmpty {
            let escapedClient = shellEscape(clientTty)
            script = "tmux switch-client -c \(escapedClient) -t \(escapedSession) 2>&1"
        } else {
            script = "tmux switch-client -t \(escapedSession) 2>&1"
        }

        let result = await runBashScriptWithResultAsync(script)
        if result.exitCode != 0 {
            logger.warning("tmux switch-client failed (exit \(result.exitCode)): \(result.output ?? "")")
            return false
        }
        return true
    }

    // MARK: - Tmux Helpers

    private func launchTerminalWithTmuxSession(_ session: String, projectPath: String? = nil) {
        logger.debug("Launching terminal with tmux session '\(session)' at path '\(projectPath ?? "default")'")
        debugLog("launchTerminalWithTmuxSession session=\(session) path=\(projectPath ?? "default")")
        let escapedSession = shellEscape(session)
        // Use -A flag: attach if session exists, create if it doesn't
        // Use -c to set working directory when creating new session
        let tmuxCmd: String
        if let path = projectPath {
            let escapedPath = shellEscape(path)
            tmuxCmd = "tmux new-session -A -s \(escapedSession) -c \(escapedPath)"
        } else {
            tmuxCmd = "tmux new-session -A -s \(escapedSession)"
        }

        // Launch terminal with tmux command
        let script = """
        if [ -d "/Applications/Ghostty.app" ]; then
            open -na "Ghostty.app" --args -e sh -c "\(tmuxCmd)"
        elif [ -d "/Applications/iTerm.app" ]; then
            osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"\(tmuxCmd)\\""
            osascript -e 'tell application "iTerm" to activate'
        else
            osascript -e "tell application \\"Terminal\\" to do script \\"\(tmuxCmd)\\""
            osascript -e 'tell application "Terminal" to activate'
        fi
        """
        runBashScript(script)
    }

    func activateTerminalApp() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isTerminalApp(frontmost)
        {
            frontmost.activate()
            return
        }
        _ = activateFirstRunningTerminal()
    }

    // MARK: - Shell Helpers

    private func findTmuxSessionForPath(_ projectPath: String) async -> String? {
        let result = await runBashScriptWithResultAsync("tmux list-windows -a -F '#{session_name}\t#{pane_current_path}' 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return nil }

        return Self.bestTmuxSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: NSHomeDirectory(),
        )
    }

    nonisolated static func bestTmuxSessionForPath(output: String, projectPath: String, homeDirectory: String) -> String? {
        func normalizePath(_ path: String) -> String {
            if path == "/" { return "/" }
            var normalized = path
            while normalized.hasSuffix("/"), normalized != "/" {
                normalized.removeLast()
            }
            return normalized.lowercased()
        }

        func managedWorktreeRoot(_ path: String) -> String? {
            let marker = "/.capacitor/worktrees/"
            guard let markerRange = path.range(of: marker) else { return nil }
            let worktreeNameStart = markerRange.upperBound
            guard worktreeNameStart < path.endIndex else { return nil }

            let suffix = path[worktreeNameStart...]
            guard let nextSlash = suffix.firstIndex(of: "/") else {
                return path
            }

            return String(path[..<nextSlash])
        }

        func isWithinPath(_ candidate: String, root: String) -> Bool {
            candidate == root || candidate.hasPrefix(root + "/")
        }

        func matchRank(shellPath: String, projectPath: String, homeDir: String) -> Int? {
            if shellPath == projectPath {
                return 2
            }

            let (shorter, longer) = shellPath.count < projectPath.count
                ? (shellPath, projectPath)
                : (projectPath, shellPath)

            if shorter == homeDir {
                return nil
            }

            guard longer.hasPrefix(shorter + "/") else { return nil }
            return shorter == projectPath ? 1 : 0
        }

        let normalizedProjectPath = normalizePath(projectPath)
        let homeDir = normalizePath(homeDirectory)
        let projectManagedRoot = managedWorktreeRoot(normalizedProjectPath)
        var bestMatch: (rank: Int, session: String)?

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let sessionName = String(parts[0])
            let panePath = normalizePath(String(parts[1]))
            let paneManagedRoot = managedWorktreeRoot(panePath)

            if let projectManagedRoot {
                if paneManagedRoot != projectManagedRoot || !isWithinPath(panePath, root: projectManagedRoot) {
                    continue
                }
            } else if paneManagedRoot != nil {
                continue
            }

            guard let rank = matchRank(
                shellPath: panePath,
                projectPath: normalizedProjectPath,
                homeDir: homeDir,
            ) else { continue }

            if bestMatch == nil || rank > bestMatch!.rank {
                bestMatch = (rank, sessionName)
                if rank == 2 {
                    break
                }
            }
        }
        return bestMatch?.session
    }

    private func isLiveShell(_ entry: (key: String, value: ShellEntry)) -> Bool {
        guard let pid = Int32(entry.key) else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: - IDE Activation

    private func findRunningIDE(_ app: ParentApp) -> NSRunningApplication? {
        guard let processName = app.processName else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName == processName
        }
    }

    private func activateIDEWindowInternal(app: ParentApp, projectPath: String) async -> Bool {
        guard let runningApp = findRunningIDE(app),
              let cliBinary = app.cliBinary
        else { return false }

        runningApp.activate()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [cliBinary, projectPath]

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = Constants.homebrewPaths + ":" + (env["PATH"] ?? "")
                process.environment = env

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        logger.warning("IDE CLI '\(cliBinary)' exited with status \(process.terminationStatus)")
                        continuation.resume(returning: false)
                        return
                    }
                    continuation.resume(returning: true)
                } catch {
                    logger.error("Failed to launch IDE CLI '\(cliBinary)': \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Ghostty Window Detection

    //
    // Ghostty has no API for selecting a specific window by TTY (unlike iTerm/Terminal.app).
    // When multiple Ghostty windows exist, we can't focus the correct one - only activate the app.
    // Strategy: If a tmux client is attached, activate Ghostty (window count is unreliable).
    // If no client is attached, launch a new terminal to guarantee the correct session.

    private func countGhosttyWindowsInternal() -> Int {
        guard let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            return 0
        }

        let appElement = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return 0
        }

        if Self.activationTraceEnabled {
            let titles = windows.compactMap { ghosttyWindowTitle($0) }
            if titles.isEmpty {
                debugLog("ghostty windows count=\(windows.count) titles=unavailable")
            } else {
                debugLog("ghostty windows count=\(windows.count) titles=\(titles)")
            }
        }

        return windows.count
    }

    private func ghosttyWindowTitle(_ window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard result == .success, let title = titleRef as? String else {
            return nil
        }
        return title
    }

    private func isGhosttyRunningInternal() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }
    }

    private func cleanupExpiredGhosttyCache() {
        let now = Date()
        Self.recentlyLaunchedGhosttySessions = Self.recentlyLaunchedGhosttySessions.filter { _, launchTime in
            now.timeIntervalSince(launchTime) < Constants.ghosttySessionCacheDuration
        }

        // Safety: cap cache at 100 entries to prevent unbounded growth
        if Self.recentlyLaunchedGhosttySessions.count > 100 {
            let sorted = Self.recentlyLaunchedGhosttySessions.sorted { $0.value > $1.value }
            Self.recentlyLaunchedGhosttySessions = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(50)))
        }
    }

    // MARK: - TTY Discovery

    @discardableResult
    private func activateTerminalByTTYDiscovery(tty: String) async -> Bool {
        if await activateGhosttyProcessOwningTTY(tty: tty) {
            logger.debug("    TTY discovery focused Ghostty process for tty=\(tty)")
            debugLog("activateTerminalByTTYDiscovery focused ghostty process tty=\(tty)")
            return true
        }

        if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
            logger.debug("    TTY discovery found: \(owningTerminal.displayName) for tty=\(tty)")
            debugLog("activateTerminalByTTYDiscovery found terminal=\(owningTerminal.displayName) tty=\(tty)")
            switch owningTerminal {
            case .iTerm:
                return activateITermSession(tty: tty)
            case .terminal:
                return activateTerminalAppSession(tty: tty)
            default:
                return activateAppByName(owningTerminal.displayName)
            }
        } else {
            logger.debug("    TTY discovery: no terminal found for tty=\(tty)")
            debugLog("activateTerminalByTTYDiscovery no terminal found tty=\(tty)")
            return false
        }
    }

    private func activateTerminalAfterTmuxSwitch(clientTty: String?) async -> Bool {
        if let clientTty, !clientTty.isEmpty {
            let focused = await activateTerminalByTTYDiscovery(tty: clientTty)
            if focused {
                return true
            }
        }
        activateTerminalApp()
        return true
    }

    private func activateGhosttyProcessOwningTTY(tty: String) async -> Bool {
        let result = await runBashScriptWithResultAsync("ps -Ao pid=,ppid=,tty=,command=")
        guard result.exitCode == 0,
              let snapshot = result.output,
              let pid = Self.ghosttyOwnerPid(forTTY: tty, processSnapshot: snapshot),
              let app = NSRunningApplication(processIdentifier: pid_t(pid))
        else {
            return false
        }
        return app.activate()
    }

    private func discoverTerminalOwningTTY(tty: String) async -> ParentApp? {
        if findRunningApp(.iTerm) != nil, await queryITermForTTY(tty) {
            debugLog("discoverTerminalOwningTTY iTerm owns tty=\(tty)")
            return .iTerm
        }
        if findRunningApp(.terminal) != nil, await queryTerminalAppForTTY(tty) {
            debugLog("discoverTerminalOwningTTY Terminal owns tty=\(tty)")
            return .terminal
        }
        return nil
    }

    private func queryITermForTTY(_ tty: String) async -> Bool {
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not found"
        """
        return await runAppleScriptWithResultAsync(script) == "found"
    }

    private func queryTerminalAppForTTY(_ tty: String) async -> Bool {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return "not found"
        """
        return await runAppleScriptWithResultAsync(script) == "found"
    }

    // MARK: - TTY-Based Tab Selection (AppleScript)

    @discardableResult
    private func activateITermSession(tty: String) -> Bool {
        let script = """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select t
                            select s
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        return runAppleScriptChecked(script)
    }

    @discardableResult
    private func activateTerminalAppSession(tty: String) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set frontmost of w to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        return runAppleScriptChecked(script)
    }

    // MARK: - App Activation Helpers

    @discardableResult
    private func activateAppByName(_ name: String?) -> Bool {
        guard let name,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.localizedName?.lowercased().contains(name.lowercased()) == true
              }),
              let appName = app.localizedName
        else {
            debugLog("activateAppByName failed name=\(name ?? "nil") (no running app match)")
            return false
        }
        // Use AppleScript for reliable activation - NSRunningApplication.activate()
        // can silently fail when SwiftUI windows steal focus back.
        logger.debug("Activating '\(appName)' via AppleScript")
        let result = runAppleScriptChecked("tell application \"\(appName)\" to activate")
        debugLog("activateAppByName app=\(appName) result=\(result)")
        return result
    }

    private func activateFirstRunningTerminal() -> Bool {
        logger.debug("    activateFirstRunningTerminal: checking priority order...")
        for terminal in ParentApp.terminalPriorityOrder where terminal.isInstalled {
            logger.debug("    checking \(terminal.displayName)...")
            if let app = findRunningApp(terminal) {
                logger.warning("    ⚠️ FALLBACK: activating \(terminal.displayName) (pid=\(app.processIdentifier)) - NO PROJECT CONTEXT")
                debugLog("activateFirstRunningTerminal activating \(terminal.displayName) pid=\(app.processIdentifier)")
                app.activate()
                return true
            }
        }
        logger.warning("    activateFirstRunningTerminal: no running terminal found")
        debugLog("activateFirstRunningTerminal no running terminal found")
        return false
    }

    private func findRunningApp(_ terminal: ParentApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            guard let localizedName = $0.localizedName else { return false }
            return terminal.matchesRunningAppName(localizedName)
        }
    }

    private func isTerminalApp(_ app: NSRunningApplication) -> Bool {
        guard let name = app.localizedName else { return false }
        return ParentApp.terminalPriorityOrder.contains { $0.matchesRunningAppName(name) }
    }

    // MARK: - New Terminal Launch

    private func launchNewTerminal(for project: Project) {
        debugLog("launchNewTerminal project=\(project.name) path=\(project.path)")
        launchNewTerminal(forPath: project.path, name: project.name)
    }

    static func launchNewTerminalScript(projectPath: String, projectName: String, claudePath: String) -> String {
        TerminalScripts.launchNoTmux(
            projectPath: projectPath,
            projectName: projectName,
            claudePath: claudePath,
        )
    }

    private func launchNewTerminal(forPath path: String, name: String) {
        _Concurrency.Task {
            let claudePath = await getClaudePath()
            debugLog("launchNewTerminal script path=\(path) name=\(name) claudePath=\(claudePath)")
            let script = Self.launchNewTerminalScript(
                projectPath: path,
                projectName: name,
                claudePath: claudePath,
            )
            runBashScript(script)
            scheduleTerminalActivation()
        }
    }

    private func getClaudePath() async -> String {
        await CapacitorConfig.shared.getClaudePath() ?? "/opt/homebrew/bin/claude"
    }

    private func scheduleTerminalActivation() {
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(Constants.activationDelaySeconds * 1_000_000_000))
            activateTerminalApp()
        }
    }

    // MARK: - Script Execution

    private func runAppleScript(_ script: String) {
        appleScript.run(script)
    }

    /// Runs AppleScript and returns success/failure based on exit code.
    /// Use this for critical activation paths where failure should trigger fallback.
    @discardableResult
    private func runAppleScriptChecked(_ script: String) -> Bool {
        appleScript.runChecked(script)
    }

    private func runAppleScriptWithResultAsync(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
                        logger.warning("AppleScript failed (exit \(process.terminationStatus)): \(errorMsg)")
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: result)
                } catch {
                    logger.error("AppleScript launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func runBashScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Constants.homebrewPaths + ":" + (env["PATH"] ?? "")
        process.environment = env

        try? process.run()
    }

    private func runBashScriptWithResultAsync(_ script: String) async -> (exitCode: Int32, output: String?) {
        await Self.runBashScriptWithResult(script)
    }

    static func runBashScriptWithResult(_ script: String) async -> (exitCode: Int32, output: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", script]

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8)
                    continuation.resume(returning: (process.terminationStatus, output))
                } catch {
                    continuation.resume(returning: (-1, nil))
                }
            }
        }
    }
}

// MARK: - Terminal Launch Scripts

enum TerminalScripts {
    static func launchNoTmux(projectPath: String, projectName: String, claudePath: String) -> String {
        // Escape values for safe interpolation into bash double-quoted strings
        let escapedPath = bashDoubleQuoteEscape(projectPath)
        let escapedName = bashDoubleQuoteEscape(projectName)
        let escapedClaude = bashDoubleQuoteEscape(claudePath)

        return """
        PROJECT_PATH="\(escapedPath)"
        PROJECT_NAME="\(escapedName)"
        CLAUDE_PATH="\(escapedClaude)"

        # Helper function to escape strings for single-quoted shell arguments
        shell_escape_single() {
            printf '%s' "$1" | sed "s/'/'\\\\''/g"
        }

        # Escape path for single-quoted arguments in osascript commands
        PATH_ESC=$(shell_escape_single "$PROJECT_PATH")

        if [ -d "/Applications/Ghostty.app" ]; then
            open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH"
        elif [ -d "/Applications/iTerm.app" ]; then
            osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PATH_ESC' && exec \\$SHELL\\""
            osascript -e 'tell application "iTerm" to activate'
        else
            osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PATH_ESC'\\""
            osascript -e 'tell application "Terminal" to activate'
        fi
        """
    }
}
