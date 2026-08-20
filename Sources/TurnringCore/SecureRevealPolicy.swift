import Foundation

public enum SecureRevealPolicy {
    public static let maximumDuration: TimeInterval = 60
    public static let maximumDurationNanoseconds: UInt64 = 60_000_000_000

    public static let knownCaptureBundleIdentifiers: Set<String> = [
        "cc.ffitch.shottr",
        "com.apple.QuickTimePlayerX",
        "com.apple.screencaptureui",
        "com.cleanshot.X",
        "com.loom.desktop",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.obsproject.obs-studio",
        "net.telestream.screenflow",
        "us.zoom.xos",
    ]

    public static func isKnownCaptureBundleIdentifier(
        _ identifier: String?
    ) -> Bool {
        guard let identifier else { return false }
        return knownCaptureBundleIdentifiers.contains(identifier)
    }

    public static func isScreenshotShortcut(
        command: Bool,
        shift: Bool,
        keyCode: UInt16
    ) -> Bool {
        command && shift && [20, 21, 22, 23].contains(keyCode)
    }
}
