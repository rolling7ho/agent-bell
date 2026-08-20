import Foundation

public enum CodexApprovalReviewer: Equatable, Sendable {
    case user
    case automatic

    init?(hookValue: String?) {
        switch hookValue {
        case "user":
            self = .user
        case "auto_review", "guardian_subagent":
            self = .automatic
        default:
            return nil
        }
    }
}

public enum CodexApprovalNotificationPolicy {
    public static func shouldNotify(
        permissionMode: String?,
        reviewer: CodexApprovalReviewer?
    ) -> Bool {
        guard permissionMode != "dontAsk",
              permissionMode != "bypassPermissions"
        else {
            return false
        }

        // PermissionRequest runs before Codex's automatic reviewer. Only an
        // explicitly user-routed approval represents a visible manual prompt.
        return reviewer == .user
    }
}

public enum CodexApprovalContextResolver {
    private static let maximumTranscriptTailBytes = 16 * 1_024 * 1_024
    private static let maximumJSONLineBytes = 1 * 1_024 * 1_024

    public static func reviewer(
        fromHookPayload data: Data,
        allowedTranscriptRoots: [URL]? = nil
    ) -> CodexApprovalReviewer? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              payload["hook_event_name"] as? String == "PermissionRequest"
        else {
            return nil
        }

        if let direct = CodexApprovalReviewer(
            hookValue: payload["approvals_reviewer"] as? String
        ) {
            return direct
        }

        guard let transcriptPath = payload["transcript_path"] as? String,
              let turnID = payload["turn_id"] as? String
        else {
            return nil
        }

        let roots = allowedTranscriptRoots ?? defaultTranscriptRoots()
        return reviewer(
            fromTranscriptAt: URL(fileURLWithPath: transcriptPath),
            turnID: turnID,
            allowedRoots: roots
        )
    }

    private static func reviewer(
        fromTranscriptAt transcriptURL: URL,
        turnID: String,
        allowedRoots: [URL]
    ) -> CodexApprovalReviewer? {
        guard transcriptURL.pathExtension == "jsonl",
              isContained(transcriptURL, inAnyOf: allowedRoots),
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: transcriptURL.path
              ),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value > 0,
              let handle = try? FileHandle(forReadingFrom: transcriptURL)
        else {
            return nil
        }
        defer { try? handle.close() }

        let size = fileSize.uint64Value
        let bytesToRead = min(size, UInt64(maximumTranscriptTailBytes))
        let offset = size - bytesToRead
        do {
            try handle.seek(toOffset: offset)
            guard var tail = try handle.readToEnd(), !tail.isEmpty else {
                return nil
            }
            if offset > 0,
               let firstNewline = tail.firstIndex(of: 0x0A)
            {
                tail.removeSubrange(tail.startIndex...firstNewline)
            }

            for line in tail.split(separator: 0x0A).reversed() {
                guard line.count <= maximumJSONLineBytes,
                      line.range(of: Data("\"approvals_reviewer\"".utf8)) != nil
                else {
                    continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let record = object as? [String: Any],
                      let type = record["type"] as? String,
                      let payload = record["payload"] as? [String: Any]
                else {
                    continue
                }

                if type == "turn_context",
                   payload["turn_id"] as? String == turnID,
                   let reviewer = CodexApprovalReviewer(
                       hookValue: payload["approvals_reviewer"] as? String
                   )
                {
                    return reviewer
                }

                if type == "event_msg",
                   payload["type"] as? String == "thread_settings_applied",
                   let settings = payload["thread_settings"] as? [String: Any],
                   let reviewer = CodexApprovalReviewer(
                       hookValue: settings["approvals_reviewer"] as? String
                   )
                {
                    return reviewer
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func defaultTranscriptRoots() -> [URL] {
        let base: URL
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"],
           configured.hasPrefix("/")
        {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return [
            base.appendingPathComponent("sessions", isDirectory: true),
            base.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    private static func isContained(_ file: URL, inAnyOf roots: [URL]) -> Bool {
        let resolvedFile = file.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in
            let resolvedRoot = root.standardizedFileURL
                .resolvingSymlinksInPath().path
            return resolvedFile.hasPrefix(resolvedRoot + "/")
        }
    }
}
