import Foundation

public enum AgentBellValidation {
    private static let sessionPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$"#
    )

    public static func isValidSessionID(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return sessionPattern.firstMatch(in: value, range: range) != nil
    }

    public static func isValidOptionalIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 192 else { return false }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || "._:-".contains($0)
        }
    }

    public static func validatedDirectory(_ value: String) -> String? {
        guard let path = normalizedAbsolutePath(value) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return path
    }

    public static func normalizedAbsolutePath(_ value: String) -> String? {
        guard !value.isEmpty,
              value.hasPrefix("/"),
              value.utf8.count <= 4096,
              !value.contains("\0")
        else {
            return nil
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    public static func projectName(for cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        let safeName = AgentBellSafeText.collapsed(
            name,
            maximumCharacters: 100
        )
        return safeName.isEmpty ? "Project" : safeName
    }

    public static func resumeArguments(
        provider: AgentProvider,
        sessionID: String
    ) -> [String]? {
        guard isValidSessionID(sessionID) else { return nil }
        return provider.resumeArguments + [sessionID]
    }

    public static func isValidExecutable(
        _ path: String,
        for provider: AgentProvider,
        fileManager: FileManager = .default
    ) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let expectedNames = provider == .codex
            ? ["codex"]
            : ["claude", "claude.exe"]
        return expectedNames.contains(name)
            && fileManager.isExecutableFile(atPath: path)
    }
}
