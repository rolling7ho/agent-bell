import Darwin
import Foundation

public enum ProcessInspector {
    private static let maximumAncestors = 12

    public static func captureOrigin(
        provider: AgentProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startingPID: Int32 = getppid()
    ) -> OriginMetadata {
        let chain = ancestorChain(startingPID: startingPID)
        let agentIndex = chain.firstIndex(where: { isAgent($0.command, provider: provider) })
        let agent = agentIndex.map { chain[$0] }
        let shell = agentIndex.flatMap { index in
            chain.dropFirst(index + 1).first(where: { isShell($0.command) })
        } ?? chain.first(where: { isShell($0.command) })
        let host = chain.first(where: { bundleIdentifier(for: $0.command) != nil })
        let executablePath = executablePath(
            provider: provider,
            agentCommand: agent?.command,
            environment: environment
        )

        return OriginMetadata(
            agentProcess: agent,
            shellProcess: shell,
            hostProcess: host,
            hostBundleIdentifier: host.flatMap { bundleIdentifier(for: $0.command) }
                ?? bundleIdentifierFromEnvironment(environment),
            executablePath: executablePath,
            termProgram: sanitizedEnvironmentValue(environment["TERM_PROGRAM"]),
            cmuxWindowID: sanitizedEnvironmentValue(environment["CMUX_WINDOW_ID"]),
            cmuxWorkspaceID: sanitizedEnvironmentValue(environment["CMUX_WORKSPACE_ID"]),
            cmuxPaneID: sanitizedEnvironmentValue(environment["CMUX_PANE_ID"]),
            cmuxSurfaceID: sanitizedEnvironmentValue(environment["CMUX_SURFACE_ID"])
        )
    }

    public static func ancestorChain(startingPID: Int32) -> [ProcessRecord] {
        var records: [ProcessRecord] = []
        var pid = startingPID
        var visited = Set<Int32>()

        for _ in 0..<maximumAncestors {
            guard pid > 1, !visited.contains(pid), let record = processRecord(pid: pid) else {
                break
            }
            records.append(record)
            visited.insert(pid)
            pid = record.parentPID
        }
        return records
    }

    public static func processRecord(pid: Int32) -> ProcessRecord? {
        let result = run(
            executable: "/bin/ps",
            // `comm` captures only the executable, never command-line arguments that
            // could contain a non-interactive prompt or other user content.
            arguments: ["-o", "pid=", "-o", "ppid=", "-o", "tty=", "-o", "lstart=", "-o", "comm=", "-p", "\(pid)"],
            timeout: 0.1
        )
        guard result.status == 0 else { return nil }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }

        let pattern = #"^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.{24})\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              let pidRange = Range(match.range(at: 1), in: output),
              let parentRange = Range(match.range(at: 2), in: output),
              let ttyRange = Range(match.range(at: 3), in: output),
              let startRange = Range(match.range(at: 4), in: output),
              let commandRange = Range(match.range(at: 5), in: output),
              let parsedPID = Int32(output[pidRange]),
              let parentPID = Int32(output[parentRange])
        else {
            return nil
        }

        let ttyValue = String(output[ttyRange])
        return ProcessRecord(
            pid: parsedPID,
            parentPID: parentPID,
            tty: ttyValue == "??" ? nil : ttyValue,
            startIdentifier: String(output[startRange]).trimmingCharacters(in: .whitespaces),
            command: String(output[commandRange])
        )
    }

    public static func isAlive(_ record: ProcessRecord?) -> Bool {
        guard let record, kill(record.pid, 0) == 0 || errno == EPERM,
              let current = processRecord(pid: record.pid)
        else {
            return false
        }
        return current.startIdentifier == record.startIdentifier
    }

    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 5
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let outputCollector = ProcessOutputCollector()
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { outputGroup.leave() }
            while true {
                let chunk: Data
                do {
                    guard let value = try pipe.fileHandleForReading.read(
                        upToCount: 64 * 1_024
                    ),
                        !value.isEmpty
                    else {
                        return
                    }
                    chunk = value
                } catch {
                    return
                }
                outputCollector.append(chunk)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            finishReadingOutput(pipe: pipe, group: outputGroup)
            return (-2, "")
        }
        finishReadingOutput(pipe: pipe, group: outputGroup)
        return (
            process.terminationStatus,
            String(decoding: outputCollector.data, as: UTF8.self)
        )
    }

    private static func finishReadingOutput(
        pipe: Pipe,
        group: DispatchGroup
    ) {
        if group.wait(timeout: .now() + 0.5) == .timedOut {
            try? pipe.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 0.1)
        }
    }

    public static func bundleIdentifier(for command: String) -> String? {
        if command.contains("/Visual Studio Code.app/") { return "com.microsoft.VSCode" }
        if command.contains("/ChatGPT Classic.app/") { return "com.openai.chat" }
        if command.contains("/ChatGPT.app/") || command.contains("/Codex.app/") {
            return "com.openai.codex"
        }
        if command.contains("/Claude.app/") {
            return "com.anthropic.claudefordesktop"
        }
        if command.contains("/Ghostty.app/") { return "com.mitchellh.ghostty" }
        if command.contains("/cmux.app/") { return "com.cmuxterm.app" }
        if command.contains("/Terminal.app/") { return "com.apple.Terminal" }
        if command.contains("/iTerm.app/") || command.contains("/iTerm2.app/") {
            return "com.googlecode.iterm2"
        }
        return nil
    }

    private static func isAgent(_ command: String, provider: AgentProvider) -> Bool {
        let executable = firstCommandToken(command).lowercased()
        switch provider {
        case .codex:
            return URL(fileURLWithPath: executable).lastPathComponent == "codex"
        case .claude:
            return URL(fileURLWithPath: executable).lastPathComponent == "claude"
                || URL(fileURLWithPath: executable).lastPathComponent == "claude.exe"
        }
    }

    private static func isShell(_ command: String) -> Bool {
        let name = URL(fileURLWithPath: firstCommandToken(command)).lastPathComponent
        return ["zsh", "bash", "fish", "sh"].contains(name)
    }

    private static func firstCommandToken(_ command: String) -> String {
        command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? command
    }

    private static func executablePath(
        provider: AgentProvider,
        agentCommand: String?,
        environment: [String: String]
    ) -> String? {
        if let token = agentCommand.map(firstCommandToken),
           token.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: token)
        {
            return token
        }

        let names: [String]
        switch provider {
        case .codex: names = ["codex"]
        case .claude: names = ["claude", "claude.exe"]
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            for name in names {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func bundleIdentifierFromEnvironment(_ environment: [String: String]) -> String? {
        switch environment["TERM_PROGRAM"]?.lowercased() {
        case "vscode": "com.microsoft.VSCode"
        case "ghostty": "com.mitchellh.ghostty"
        case "apple_terminal": "com.apple.Terminal"
        case "iterm.app": "com.googlecode.iterm2"
        default:
            environment["CMUX_WORKSPACE_ID"] == nil ? nil : "com.cmuxterm.app"
        }
    }

    private static func sanitizedEnvironmentValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256 else { return nil }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || "._:/-".contains(character)
        } ? value : nil
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private static let maximumBytes = 1 * 1_024 * 1_024
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < Self.maximumBytes else { return }
        storage.append(
            data.prefix(Self.maximumBytes - storage.count)
        )
    }
}
