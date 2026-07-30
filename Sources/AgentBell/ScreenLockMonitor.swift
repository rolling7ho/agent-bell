import CoreGraphics
import Foundation
import IOKit

@MainActor
final class ScreenLockMonitor: NSObject {
    private(set) var isLocked: Bool
    var onLock: (() -> Void)?

    override init() {
        isLocked = Self.currentState() ?? true
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func refresh() {
        isLocked = Self.currentState() ?? isLocked
    }

    @objc private func screenLocked() {
        isLocked = true
        onLock?()
    }

    @objc private func screenUnlocked() {
        isLocked = false
    }

    private static func currentState() -> Bool? {
        if let dictionary = CGSessionCopyCurrentDictionary()
            as? [String: Any],
            let state = booleanValue(
                dictionary["CGSSessionScreenIsLocked"]
            )
        {
            return state
        }
        return ioRegistryLockState()
    }

    private static func ioRegistryLockState() -> Bool? {
        let rootEntry = IORegistryGetRootEntry(kIOMainPortDefault)
        guard rootEntry != 0 else { return nil }
        defer { IOObjectRelease(rootEntry) }

        let value = IORegistryEntryCreateCFProperty(
            rootEntry,
            "IOConsoleLocked" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        return booleanValue(value)
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }
}
