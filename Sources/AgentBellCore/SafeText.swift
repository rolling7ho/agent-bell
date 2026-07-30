import Foundation

public enum AgentBellSafeText {
    private static let bidirectionalFormattingScalars: Set<UInt32> = [
        0x061C,
        0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    public static func collapsed(
        _ value: String,
        maximumCharacters: Int? = nil,
        appendEllipsisWhenTruncated: Bool = false
    ) -> String {
        var visible = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if bidirectionalFormattingScalars.contains(scalar.value) {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
            {
                visible.append(" ")
            } else {
                visible.append(scalar)
            }
        }
        let collapsed = String(visible)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard let maximumCharacters,
              maximumCharacters >= 0,
              collapsed.count > maximumCharacters
        else {
            return collapsed
        }
        if appendEllipsisWhenTruncated, maximumCharacters > 0 {
            return String(collapsed.prefix(maximumCharacters - 1)) + "…"
        }
        return String(collapsed.prefix(maximumCharacters))
    }

    public static func redacted(_ value: String) -> String {
        let patterns: [(String, String)] = [
            (
                #"(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|AUTH|CREDENTIAL)[A-Z0-9_]*=)("[^"]*"|'[^']*'|\S+)"#,
                "$1••••"
            ),
            (
                #"(?i)(--?(?:token|secret|password|passwd|api[-_]?key|auth|credential)(?:=|\s+))("[^"]*"|'[^']*'|\S+)"#,
                "$1••••"
            ),
            (
                #"(?i)(authorization:\s*(?:bearer|basic)\s+)[^\s"']+"#,
                "$1••••"
            ),
            (
                #"(?i)([?&](?:access_token|token|api[-_]?key|apikey|key|secret|password|passwd|credential)=)[^&\s"' ]+"#,
                "$1••••"
            ),
            (
                #"(?i)(https?://)[^/@\s:]+:[^/@\s]+@"#,
                "$1••••@"
            ),
            (
                #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
                "••••"
            ),
            (
                #"\b(?:sk|sk-ant|ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_-]{12,}\b"#,
                "••••"
            ),
            (
                #"\bsk-[A-Za-z0-9_-]{12,}\b"#,
                "••••"
            ),
            (
                #"\bAKIA[A-Z0-9]{12,}\b"#,
                "••••"
            ),
            (
                #"/Users/[^/\s]+/"#,
                "~/"
            ),
            (
                #"(?<![:/~A-Za-z0-9])/(?:[^/\s]+/)*[^/\s]*"#,
                "[path]"
            ),
            (
                #"\b[A-Za-z]:\\(?:[^\\\s]+\\)*[^\\\s]*"#,
                "[path]"
            ),
            (
                #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
                "[email]"
            ),
        ]
        return patterns.reduce(value) { partial, item in
            guard let expression = try? NSRegularExpression(
                pattern: item.0
            ) else {
                return partial
            }
            let range = NSRange(
                partial.startIndex..<partial.endIndex,
                in: partial
            )
            return expression.stringByReplacingMatches(
                in: partial,
                range: range,
                withTemplate: item.1
            )
        }
    }
}
