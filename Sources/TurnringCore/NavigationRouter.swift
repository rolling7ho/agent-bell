import AppKit
import ApplicationServices
import Foundation

public enum NavigationResult: Equatable {
    case opened
    case focused
    case unavailable(String)
}

public final class NavigationRouter: @unchecked Sendable {
    private let fileManager: FileManager
    private var vscodeCompanionAvailable = false

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @MainActor
    public func setVSCodeCompanionAvailable(_ available: Bool) {
        vscodeCompanionAvailable = available
    }

    @MainActor
    public func open(_ session: SessionSummary) -> NavigationResult {
        if session.origin.hostBundleIdentifier == "com.openai.codex",
           session.provider == .codex
        {
            return openCodexDeepLink(session.sessionID)
        }

        let isAgentAlive = ProcessInspector.isAlive(session.origin.agentProcess)
        if isAgentAlive {
            return focusLiveSession(session)
        }
        return resumeDeadSession(session)
    }

    @MainActor
    private func focusLiveSession(_ session: SessionSummary) -> NavigationResult {
        switch session.origin.hostBundleIdentifier {
        case "com.microsoft.VSCode":
            guard vscodeCompanionAvailable else {
                return activateHost(session)
            }
            let result = sendVSCodeRequest(session, action: .focus)
            if case .unavailable = result {
                return activateHost(session)
            }
            return result
        case "com.cmuxterm.app":
            if focusCMux(session) { return .focused }
            return activateHost(session)
        case "com.apple.Terminal":
            if focusTerminalTab(session) { return .focused }
            return activateHost(session)
        case "com.mitchellh.ghostty":
            if focusGhosttyTerminal(session) { return .focused }
            return activateHost(session)
        default:
            return activateHost(session)
        }
    }

    @MainActor
    private func resumeDeadSession(_ session: SessionSummary) -> NavigationResult {
        guard TurnringValidation.isValidSessionID(session.sessionID),
              let cwd = TurnringValidation.validatedDirectory(session.cwd)
        else {
            return .unavailable("The saved session or project path is no longer valid.")
        }

        switch session.origin.hostBundleIdentifier {
        case "com.openai.codex" where session.provider == .codex:
            return openCodexDeepLink(session.sessionID)
        case "com.openai.chat" where session.provider == .codex,
             "com.anthropic.claudefordesktop" where session.provider == .claude:
            return activateHost(session)
        case "com.microsoft.VSCode":
            guard vscodeCompanionAvailable else {
                return resumeInTerminal(session, cwd: cwd)
            }
            let result = sendVSCodeRequest(session, action: .resume)
            if case .unavailable = result {
                return resumeInTerminal(session, cwd: cwd)
            }
            return result
        case "com.cmuxterm.app":
            if resumeInCMux(session, cwd: cwd) { return .opened }
            return resumeInTerminal(session, cwd: cwd)
        case "com.mitchellh.ghostty":
            if resumeInGhostty(session, cwd: cwd) { return .opened }
            return resumeInTerminal(session, cwd: cwd)
        default:
            return resumeInTerminal(session, cwd: cwd)
        }
    }

    @MainActor
    private func openCodexDeepLink(_ sessionID: String) -> NavigationResult {
        guard TurnringValidation.isValidSessionID(sessionID),
              let url = URL(string: "codex://threads/\(sessionID)")
        else {
            return .unavailable("The Codex thread identifier is invalid.")
        }
        return NSWorkspace.shared.open(url)
            ? .opened
            : .unavailable("The Codex desktop app could not open this thread.")
    }

    @MainActor
    private func activateHost(_ session: SessionSummary) -> NavigationResult {
        let application: NSRunningApplication?
        let pid: Int32?
        if let host = session.origin.hostProcess,
           ProcessInspector.isAlive(host),
           let original = NSRunningApplication(
               processIdentifier: host.pid
           )
        {
            application = original
            pid = host.pid
        } else if let bundleIdentifier = session.origin.hostBundleIdentifier,
                  let running = NSRunningApplication.runningApplications(
                      withBundleIdentifier: bundleIdentifier
                  ).first
        {
            application = running
            pid = running.processIdentifier
        } else {
            application = nil
            pid = nil
        }
        guard let application, let pid else {
            return .unavailable("The original app is no longer running.")
        }

        _ = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        focusMatchingWindow(pid: pid, projectName: session.projectName)
        return .focused
    }

    private func focusMatchingWindow(pid: Int32, projectName: String) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
            let windows = value as? [AXUIElement],
            !windows.isEmpty
        else {
            return
        }

        let target = windows.first(where: { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success,
                let title = titleValue as? String
            else {
                return false
            }
            return title.localizedCaseInsensitiveContains(projectName)
        }) ?? (windows.count == 1 ? windows[0] : nil)

        guard let target else { return }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    @MainActor
    private func sendVSCodeRequest(
        _ session: SessionSummary,
        action: FocusRequest.Action
    ) -> NavigationResult {
        do {
            try TurnringPaths.prepareRuntimeDirectories()
            let requestID = UUID().uuidString.lowercased()
            let request = FocusRequest(
                requestID: requestID,
                provider: session.provider,
                sessionID: session.sessionID,
                shellPID: session.origin.shellProcess?.pid,
                cwd: session.cwd,
                executablePath: session.origin.executablePath,
                action: action
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(request)
            let requestURL = TurnringPaths.focusRequestsDirectory
                .appendingPathComponent("\(requestID).json")
            try data.write(to: requestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            guard let url = URL(string: "vscode://turnring.focus/focus?request=\(requestID)"),
                  NSWorkspace.shared.open(url)
            else {
                try? fileManager.removeItem(at: requestURL)
                return .unavailable("VS Code did not accept the Turnring focus request.")
            }
            return action == .focus ? .focused : .opened
        } catch {
            return .unavailable("Could not prepare the VS Code focus request.")
        }
    }

    private func focusCMux(_ session: SessionSummary) -> Bool {
        guard let cmux = cmuxCLIPath() else { return false }
        if let window = session.origin.cmuxWindowID {
            let result = ProcessInspector.run(
                executable: cmux,
                arguments: ["focus-window", "--window", window],
                timeout: 3
            )
            guard result.status == 0 else { return false }
        }
        if let workspace = session.origin.cmuxWorkspaceID {
            let result = ProcessInspector.run(
                executable: cmux,
                arguments: ["select-workspace", "--workspace", workspace],
                timeout: 3
            )
            guard result.status == 0 else { return false }
        }
        if let pane = session.origin.cmuxPaneID {
            let result = ProcessInspector.run(
                executable: cmux,
                arguments: ["focus-pane", "--pane", pane],
                timeout: 3
            )
            guard result.status == 0 else { return false }
        }
        return session.origin.cmuxWindowID != nil
            || session.origin.cmuxWorkspaceID != nil
            || session.origin.cmuxPaneID != nil
    }

    /// Captures Ghostty's stable terminal identifier while the hook's source
    /// terminal is still focused. Ghostty 1.3 exposes terminal IDs and working
    /// directories, but does not expose the child PID or TTY.
    public func captureGhosttyTerminalID(expectedCWD: String) -> String? {
        let script = """
        on run argv
          tell application "Ghostty"
            if not running then return ""
            try
              set sourceTerminal to focused terminal of selected tab of front window
              return (id of sourceTerminal as text) & linefeed & (working directory of sourceTerminal as text)
            on error
              return ""
            end try
          end tell
        end run
        """
        let result = ProcessInspector.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script, "--"],
            timeout: 2
        )
        guard result.status == 0 else { return nil }
        let parts = result.output.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              URL(fileURLWithPath: parts[1]).standardizedFileURL.path
                == URL(fileURLWithPath: expectedCWD).standardizedFileURL.path,
              isSafeOpaqueIdentifier(parts[0])
        else {
            return nil
        }
        return parts[0]
    }

    private func focusTerminalTab(_ session: SessionSummary) -> Bool {
        guard let tty = session.origin.agentProcess?.tty
            ?? session.origin.shellProcess?.tty,
            isSafeTTY(tty)
        else {
            return false
        }
        let normalizedTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
        on run argv
          set targetTTY to item 1 of argv
          tell application "Terminal"
            repeat with sourceWindow in windows
              repeat with sourceTab in tabs of sourceWindow
                if (tty of sourceTab as text) is targetTTY then
                  set selected tab of sourceWindow to sourceTab
                  set index of sourceWindow to 1
                  activate
                  return "focused"
                end if
              end repeat
            end repeat
          end tell
          return "not-found"
        end run
        """
        let result = ProcessInspector.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script, "--", normalizedTTY],
            timeout: 3
        )
        return result.status == 0
            && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "focused"
    }

    private func focusGhosttyTerminal(_ session: SessionSummary) -> Bool {
        guard let terminalID = session.origin.ghosttyTerminalID,
              isSafeOpaqueIdentifier(terminalID)
        else {
            return false
        }
        let script = """
        on run argv
          set targetID to item 1 of argv
          tell application "Ghostty"
            if not running then return "not-found"
            repeat with sourceWindow in windows
              repeat with sourceTab in tabs of sourceWindow
                repeat with sourceTerminal in terminals of sourceTab
                  if (id of sourceTerminal as text) is targetID then
                    set selected tab of sourceWindow to sourceTab
                    focus sourceTerminal
                    activate
                    return "focused"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "not-found"
        end run
        """
        let result = ProcessInspector.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script, "--", terminalID],
            timeout: 3
        )
        return result.status == 0
            && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "focused"
    }

    private func resumeInCMux(_ session: SessionSummary, cwd: String) -> Bool {
        guard let cmux = cmuxCLIPath(),
              let script = try? createResumeScript(session: session, cwd: cwd)
        else {
            return false
        }
        let result = ProcessInspector.run(
            executable: cmux,
            arguments: [
                "new-workspace",
                "--name", "\(session.provider.displayName) · \(session.projectName)",
                "--cwd", cwd,
                "--command", script.path,
                "--focus", "true",
            ],
            timeout: 5
        )
        return result.status == 0
    }

    private func resumeInGhostty(_ session: SessionSummary, cwd: String) -> Bool {
        guard let executable = validatedExecutable(for: session),
              let resumeArguments = TurnringValidation.resumeArguments(
                  provider: session.provider,
                  sessionID: session.sessionID
              )
        else {
            return false
        }
        let arguments = [
            "-na", "/Applications/Ghostty.app",
            "--args",
            "--working-directory=\(cwd)",
            "-e", executable,
        ] + resumeArguments
        return ProcessInspector.run(
            executable: "/usr/bin/open",
            arguments: arguments,
            timeout: 5
        ).status == 0
    }

    @MainActor
    private func resumeInTerminal(_ session: SessionSummary, cwd: String) -> NavigationResult {
        do {
            let script = try createResumeScript(session: session, cwd: cwd)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [script],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: configuration
            ) { _, error in
                if error == nil {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                        try? FileManager.default.removeItem(at: script)
                    }
                }
            }
            return .opened
        } catch {
            return .unavailable("Could not create a safe Terminal resume command.")
        }
    }

    private func createResumeScript(session: SessionSummary, cwd: String) throws -> URL {
        try TurnringPaths.prepareRuntimeDirectories()
        guard let executable = validatedExecutable(for: session) else {
            throw CocoaError(.executableNotLoadable)
        }
        guard let arguments = TurnringValidation.resumeArguments(
            provider: session.provider,
            sessionID: session.sessionID
        ) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let scriptURL = TurnringPaths.resumeScriptsDirectory
            .appendingPathComponent("resume-\(UUID().uuidString).command")
        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let contents = """
        #!/bin/zsh
        cd -- \(shellQuote(cwd))
        exec \(command)
        """
        try contents.data(using: .utf8)!.write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func validatedExecutable(for session: SessionSummary) -> String? {
        let candidates = [
            session.origin.executablePath,
            "/opt/homebrew/bin/\(session.provider == .codex ? "codex" : "claude")",
            "/usr/local/bin/\(session.provider == .codex ? "codex" : "claude")",
            "\(TurnringPaths.homeDirectory.path)/.local/bin/\(session.provider == .codex ? "codex" : "claude")",
            "\(TurnringPaths.homeDirectory.path)/.npm-global/bin/\(session.provider == .codex ? "codex" : "claude")",
        ].compactMap { $0 }
        return candidates.first { path in
            TurnringValidation.isValidExecutable(
                path,
                for: session.provider,
                fileManager: fileManager
            )
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func isSafeTTY(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
    }

    private func isSafeOpaqueIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || "._:-".contains($0)
        }
    }

    private func cmuxCLIPath() -> String? {
        let candidates = [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/opt/homebrew/bin/cmux",
            "/usr/local/bin/cmux",
        ]
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }
}
