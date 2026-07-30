import AgentBellCore
import Foundation

final class NotificationPreferences {
    private enum Key {
        static let launchAtLogin = "settings.launchAtLogin"
        static let phoneAlertsEnabled = "settings.phoneAlerts.enabled"
        static let phoneAlertDetailsEnabled = "settings.phoneAlerts.includeDetails"
        static let localAlertDetailsEnabled =
            "settings.notifications.includeDetailsWhenUnlocked"
        static let localPreviewCharacterLimit =
            "settings.notifications.previewCharacterLimit"
        static let automaticHistoryCleanupEnabled =
            "settings.history.automaticCleanupEnabled"
        static let historyRetentionMinutes =
            "settings.history.retentionMinutes"
        static let confirmBeforeQuit = "settings.quit.confirmBeforeQuit"
        static let legacyNtfyTopic = "settings.phoneAlerts.ntfyTopic"

        static func minimumDuration(_ surface: NotificationSurface) -> String {
            "settings.notifications.minimumDuration.\(surface.rawValue)"
        }

        static func notification(_ surface: NotificationSurface) -> String {
            "settings.notifications.\(surface.rawValue)"
        }

        static func phoneAlert(_ state: AgentState) -> String {
            "settings.phoneAlerts.events.\(state.rawValue)"
        }
    }

    static let ntfyServerURL = "https://ntfy.sh"

    private let defaults: UserDefaults
    private let ntfyTopicStore: NtfyTopicStore
    private var cachedNtfyTopic: String?

    init(
        defaults: UserDefaults = .standard,
        ntfyTopicStore: NtfyTopicStore = NtfyTopicStore()
    ) {
        self.defaults = defaults
        self.ntfyTopicStore = ntfyTopicStore
    }

    var launchAtLogin: Bool {
        get {
            guard defaults.object(forKey: Key.launchAtLogin) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.launchAtLogin)
        }
        set {
            defaults.set(newValue, forKey: Key.launchAtLogin)
        }
    }

    func notificationsEnabled(for surface: NotificationSurface) -> Bool {
        let key = Key.notification(surface)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    func setNotificationsEnabled(_ enabled: Bool, for surface: NotificationSurface) {
        defaults.set(enabled, forKey: Key.notification(surface))
    }

    func notificationsEnabled(for session: SessionSummary) -> Bool {
        notificationsEnabled(for: NotificationSurface(session: session))
    }

    func minimumTaskDuration(for surface: NotificationSurface) -> TimeInterval {
        let key = Key.minimumDuration(surface)
        if defaults.object(forKey: key) != nil {
            return max(0, min(3_600, defaults.double(forKey: key)))
        }
        return surface == .chatGPTDesktop ? 30 : 0
    }

    func setMinimumTaskDuration(
        _ duration: TimeInterval,
        for surface: NotificationSurface
    ) {
        defaults.set(max(0, min(3_600, duration)), forKey: Key.minimumDuration(surface))
    }

    func shouldDeliverNotification(for session: SessionSummary) -> Bool {
        let surface = NotificationSurface(session: session)
        return notificationsEnabled(for: surface)
            && DesktopNotificationThresholdPolicy.shouldNotify(
                for: session,
                minimumDuration: minimumTaskDuration(for: surface)
            )
    }

    var phoneAlertsEnabled: Bool {
        get { defaults.bool(forKey: Key.phoneAlertsEnabled) }
        set { defaults.set(newValue, forKey: Key.phoneAlertsEnabled) }
    }

    var ntfyTopic: String {
        (try? prepareSecureNtfyTopic()) ?? ""
    }

    @discardableResult
    func prepareSecureNtfyTopic() throws -> String {
        if let cachedNtfyTopic {
            return cachedNtfyTopic
        }
        let legacy = defaults.string(forKey: Key.legacyNtfyTopic)
        let topic = try ntfyTopicStore.loadOrCreate(migrating: legacy)
        defaults.removeObject(forKey: Key.legacyNtfyTopic)
        cachedNtfyTopic = topic
        return topic
    }

    func deleteSecureNtfyTopic() throws {
        cachedNtfyTopic = nil
        defaults.removeObject(forKey: Key.legacyNtfyTopic)
        try ntfyTopicStore.deleteTopic()
    }

    var phoneAlertDetailsEnabled: Bool {
        get { defaults.bool(forKey: Key.phoneAlertDetailsEnabled) }
        set { defaults.set(newValue, forKey: Key.phoneAlertDetailsEnabled) }
    }

    var localAlertDetailsEnabled: Bool {
        get { defaults.bool(forKey: Key.localAlertDetailsEnabled) }
        set { defaults.set(newValue, forKey: Key.localAlertDetailsEnabled) }
    }

    var localPreviewCharacterLimit: Int {
        get {
            guard defaults.object(forKey: Key.localPreviewCharacterLimit) != nil
            else {
                return 50
            }
            return max(
                10,
                min(
                    AttentionPreviewFormatter.maximumCharacters,
                    defaults.integer(forKey: Key.localPreviewCharacterLimit)
                )
            )
        }
        set {
            defaults.set(
                max(
                    10,
                    min(AttentionPreviewFormatter.maximumCharacters, newValue)
                ),
                forKey: Key.localPreviewCharacterLimit
            )
        }
    }

    var automaticHistoryCleanupEnabled: Bool {
        get {
            guard defaults.object(
                forKey: Key.automaticHistoryCleanupEnabled
            ) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.automaticHistoryCleanupEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.automaticHistoryCleanupEnabled)
        }
    }

    var historyRetentionMinutes: Double {
        get {
            guard defaults.object(forKey: Key.historyRetentionMinutes) != nil
            else {
                return 30
            }
            return max(
                1,
                min(10_080, defaults.double(forKey: Key.historyRetentionMinutes))
            )
        }
        set {
            defaults.set(
                max(1, min(10_080, newValue)),
                forKey: Key.historyRetentionMinutes
            )
        }
    }

    var historyRetentionInterval: TimeInterval {
        historyRetentionMinutes * 60
    }

    var confirmBeforeQuit: Bool {
        get {
            guard defaults.object(forKey: Key.confirmBeforeQuit) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.confirmBeforeQuit)
        }
        set {
            defaults.set(newValue, forKey: Key.confirmBeforeQuit)
        }
    }

    func phoneAlertEnabled(for state: AgentState) -> Bool {
        guard state.shouldNotify else { return false }
        let key = Key.phoneAlert(state)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    func setPhoneAlertEnabled(_ enabled: Bool, for state: AgentState) {
        guard state.shouldNotify else { return }
        defaults.set(enabled, forKey: Key.phoneAlert(state))
    }

    func shouldPublishPhoneAlert(for session: SessionSummary) -> Bool {
        phoneAlertsEnabled && phoneAlertEnabled(for: session.state)
    }

    func resetToDefaults() throws {
        try deleteSecureNtfyTopic()

        var keys = [
            Key.launchAtLogin,
            Key.phoneAlertsEnabled,
            Key.phoneAlertDetailsEnabled,
            Key.localAlertDetailsEnabled,
            Key.localPreviewCharacterLimit,
            Key.automaticHistoryCleanupEnabled,
            Key.historyRetentionMinutes,
            Key.confirmBeforeQuit,
            Key.legacyNtfyTopic,
        ]
        keys.append(
            contentsOf: NotificationSurface.allCases.flatMap {
                [
                    Key.minimumDuration($0),
                    Key.notification($0),
                ]
            }
        )
        keys.append(
            contentsOf: [AgentState.attention, .finished, .failed].map {
                Key.phoneAlert($0)
            }
        )
        keys.forEach { defaults.removeObject(forKey: $0) }
    }
}
