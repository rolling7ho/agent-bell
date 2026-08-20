import TurnringCore
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum SettingsSection {
    case general
    case notifications
    case phone
    case integration
    case testing
    case info
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        preferences: NotificationPreferences,
        ntfyAccessTokenStore: NtfyAccessTokenStore,
        integrationStatus: IntegrationStatus,
        initialSection: SettingsSection = .general,
        onLaunchAtLoginChanged: @escaping (Bool) -> Void,
        onDeliveryPreferencesChanged: @escaping () -> Void,
        onHistoryPreferencesChanged: @escaping () -> Void,
        onRepairIntegration: @escaping () async throws -> IntegrationStatus,
        onTestAlert: @escaping () -> Void,
        onTestAllApps: @escaping () -> Void,
        onTestSurface: @escaping (NotificationSurface) -> Void,
        onTestPhoneAlert: @escaping () async throws -> Void,
        onResetSettings: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) {
        let controller = SettingsViewController(
            preferences: preferences,
            ntfyAccessTokenStore: ntfyAccessTokenStore,
            integrationStatus: integrationStatus,
            initialSection: initialSection,
            onLaunchAtLoginChanged: onLaunchAtLoginChanged,
            onDeliveryPreferencesChanged: onDeliveryPreferencesChanged,
            onHistoryPreferencesChanged: onHistoryPreferencesChanged,
            onRepairIntegration: onRepairIntegration,
            onTestAlert: onTestAlert,
            onTestAllApps: onTestAllApps,
            onTestSurface: onTestSurface,
            onTestPhoneAlert: onTestPhoneAlert,
            onResetSettings: onResetSettings,
            onUninstall: onUninstall
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Turnring Settings"
        window.styleMask = [.titled, .closable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = TurnringAppearance.canvas
        window.isOpaque = true
        window.setContentSize(NSSize(width: 538, height: 640))
        window.minSize = NSSize(width: 538, height: 640)
        window.maxSize = NSSize(width: 538, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        guard let window else { return }
        showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    private let preferences: NotificationPreferences
    private let ntfyAccessTokenStore: NtfyAccessTokenStore
    private var integrationStatus: IntegrationStatus
    private let initialSection: SettingsSection
    private let onLaunchAtLoginChanged: (Bool) -> Void
    private let onDeliveryPreferencesChanged: () -> Void
    private let onHistoryPreferencesChanged: () -> Void
    private let onRepairIntegration: () async throws -> IntegrationStatus
    private let onTestAlert: () -> Void
    private let onTestAllApps: () -> Void
    private let onTestSurface: (NotificationSurface) -> Void
    private let onTestPhoneAlert: () async throws -> Void
    private let onResetSettings: () -> Void
    private let onUninstall: () -> Void
    private let contentContainer = NSView()
    private let generalButton = SettingsNavigationButton(title: "General", symbol: "gearshape")
    private let notificationsButton = SettingsNavigationButton(
        title: "Notifications",
        symbol: "bell"
    )
    private let phoneButton = SettingsNavigationButton(title: "Phone", symbol: "iphone")
    private let integrationButton = SettingsNavigationButton(
        title: "Integration",
        symbol: "puzzlepiece.extension"
    )
    private let testingButton = SettingsNavigationButton(title: "Testing", symbol: "testtube.2")
    private let infoButton = SettingsNavigationButton(title: "Info", symbol: "info.circle")
    private let phoneStatusLabel = NSTextField(labelWithString: "")
    private let ntfyTokenField = NSSecureTextField()
    private let ntfyTopicField = CaptureProtectedSecretField()
    private let integrationStatusLabel = NSTextField(
        wrappingLabelWithString: ""
    )
    private let integrationDetailLabel = NSTextField(
        wrappingLabelWithString: ""
    )
    private var integrationActionButton: SettingsActionButton?
    private var phoneActionTask: Task<Void, Never>?
    private var phoneStatusHideTask: Task<Void, Never>?
    private var topicClipboardClearTask: Task<Void, Never>?
    private var integrationActionTask: Task<Void, Never>?
    private lazy var codexTrustNotice = WarningCalloutView(
        attributedText: codexInstructions()
    )
    private lazy var generalView = buildGeneralView()
    private lazy var notificationsView = buildNotificationsView()
    private lazy var phoneView = buildPhoneView()
    private lazy var integrationView = buildIntegrationView()
    private lazy var testingView = buildTestingView()
    private lazy var infoView = buildInfoView()

    init(
        preferences: NotificationPreferences,
        ntfyAccessTokenStore: NtfyAccessTokenStore,
        integrationStatus: IntegrationStatus,
        initialSection: SettingsSection,
        onLaunchAtLoginChanged: @escaping (Bool) -> Void,
        onDeliveryPreferencesChanged: @escaping () -> Void,
        onHistoryPreferencesChanged: @escaping () -> Void,
        onRepairIntegration: @escaping () async throws -> IntegrationStatus,
        onTestAlert: @escaping () -> Void,
        onTestAllApps: @escaping () -> Void,
        onTestSurface: @escaping (NotificationSurface) -> Void,
        onTestPhoneAlert: @escaping () async throws -> Void,
        onResetSettings: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.ntfyAccessTokenStore = ntfyAccessTokenStore
        self.integrationStatus = integrationStatus
        self.initialSection = initialSection
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        self.onDeliveryPreferencesChanged = onDeliveryPreferencesChanged
        self.onHistoryPreferencesChanged = onHistoryPreferencesChanged
        self.onRepairIntegration = onRepairIntegration
        self.onTestAlert = onTestAlert
        self.onTestAllApps = onTestAllApps
        self.onTestSurface = onTestSurface
        self.onTestPhoneAlert = onTestPhoneAlert
        self.onResetSettings = onResetSettings
        self.onUninstall = onUninstall
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = TurnringGlassGroupingView(
            frame: NSRect(x: 0, y: 0, width: 538, height: 640),
            surfaceColor: TurnringAppearance.canvas,
            cornerRadius: 0,
            glassSpacing: 8
        )
        buildInterface()
        show(initialSection)
    }

    private func buildInterface() {
        guard let contentRoot = (view as? TurnringGlassGroupingView)?.contentView
        else {
            return
        }
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = TurnringAppearance.sidebar.cgColor

        let heading = NSTextField(labelWithString: "Settings")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        generalButton.target = self
        generalButton.action = #selector(showGeneral)
        notificationsButton.target = self
        notificationsButton.action = #selector(showNotifications)
        phoneButton.target = self
        phoneButton.action = #selector(showPhone)
        integrationButton.target = self
        integrationButton.action = #selector(showIntegration)
        testingButton.target = self
        testingButton.action = #selector(showTesting)
        infoButton.target = self
        infoButton.action = #selector(showInfo)

        let navigation = NSStackView(
            views: [
                heading,
                generalButton,
                notificationsButton,
                phoneButton,
                integrationButton,
                testingButton,
                infoButton,
                NSView(),
            ]
        )
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 8
        navigation.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 12, right: 12)

        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentRoot.addSubview(sidebar)
        sidebar.addSubview(navigation)
        contentRoot.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 156),

            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            generalButton.widthAnchor.constraint(equalToConstant: 132),
            notificationsButton.widthAnchor.constraint(equalToConstant: 132),
            phoneButton.widthAnchor.constraint(equalToConstant: 132),
            integrationButton.widthAnchor.constraint(equalToConstant: 132),
            testingButton.widthAnchor.constraint(equalToConstant: 132),
            infoButton.widthAnchor.constraint(equalToConstant: 132),

            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
        ])
    }

    private func buildPhoneView() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "Phone")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString: "Send minimal Turnring alerts through ntfy.sh. Details are opt-in; the random topic and token stay in Keychain."
        )
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2

        let enabledRow = SettingSwitchRow(
            title: "Phone alerts",
            detail: "No network request is made while this is off.",
            isOn: preferences.phoneAlertsEnabled
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.phoneAlertsEnabled = enabled
            onDeliveryPreferencesChanged()
        }

        let eventsTitle = NSTextField(labelWithString: "Send for")
        eventsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        eventsTitle.textColor = .secondaryLabelColor

        let alertStates: [(AgentState, String)] = [
            (.attention, "Needs attention"),
            (.finished, "Finished"),
            (.failed, "Failed"),
        ]
        let eventButtons = alertStates.map { state, label in
            CallbackCheckbox(
                title: label,
                isOn: preferences.phoneAlertEnabled(for: state)
            ) { [weak self] enabled in
                guard let self else { return }
                preferences.setPhoneAlertEnabled(enabled, for: state)
                onDeliveryPreferencesChanged()
            }
        }
        let events = NSStackView(views: eventButtons)
        events.orientation = .horizontal
        events.alignment = .centerY
        events.distribution = .fillEqually
        events.spacing = 8

        let detailsButton = CallbackCheckbox(
            title: "Include task titles and previews",
            isOn: preferences.phoneAlertDetailsEnabled
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.phoneAlertDetailsEnabled = enabled
            onDeliveryPreferencesChanged()
        }
        detailsButton.toolTip = "Details may appear on a phone lock screen."
        let detailsDisclaimer = WarningCalloutView(
            text:
                "Sensitive previews can expose task names, questions, commands, or filenames on your phone. Leave this off unless your phone notification previews are private."
        )

        let tokenTitle = NSTextField(
            labelWithString: "Publish access token (protected topics)"
        )
        tokenTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        tokenTitle.textColor = .secondaryLabelColor

        ntfyTokenField.stringValue =
            (try? ntfyAccessTokenStore.loadToken()) ?? ""
        ntfyTokenField.placeholderString = "Paste an ntfy publish token"
        ntfyTokenField.usesSingleLineMode = true
        ntfyTokenField.maximumNumberOfLines = 1
        ntfyTokenField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let saveTokenButton = SettingsActionButton(title: "Save") {
            [weak self] in
            self?.saveNtfyAccessToken()
        }
        saveTokenButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let removeTokenButton = SettingsActionButton(title: "Remove") {
            [weak self] in
            self?.removeNtfyAccessToken()
        }
        removeTokenButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let tokenRow = NSStackView(
            views: [ntfyTokenField, saveTokenButton, removeTokenButton]
        )
        tokenRow.orientation = .horizontal
        tokenRow.alignment = .centerY
        tokenRow.spacing = 8

        let topicTitle = NSTextField(
            labelWithString: "Random ntfy topic (Keychain)"
        )
        topicTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        topicTitle.textColor = .secondaryLabelColor

        let secureTopic = preferences.ntfyTopic
        let maskedTopic = secureTopic.isEmpty
            ? "Secure topic unavailable"
            : "\(SecureNtfyTopic.prefix)••••••••\(secureTopic.suffix(8))"
        ntfyTopicField.stringValue = secureTopic
        ntfyTopicField.maskedStringValue = maskedTopic
        ntfyTopicField.toolTip = secureTopic.isEmpty
            ? nil
            : "Stored in Keychain. Reveal lasts at most 60 seconds and masks sooner when Turnring detects a screenshot or supported recorder. Detection is best effort."

        let copyButton = SettingsActionButton(title: "Copy Topic") { [weak self] in
            self?.copyNtfyTopic()
        }
        copyButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        copyButton.isEnabled = !secureTopic.isEmpty

        let topicRow = NSStackView(views: [ntfyTopicField, copyButton])
        topicRow.orientation = .horizontal
        topicRow.alignment = .centerY
        topicRow.spacing = 8

        let connectButton = SettingsActionButton(
            title: "Connect Phone…"
        ) { [weak self] in
            self?.showPhoneConnection()
        }
        connectButton.isEnabled = !secureTopic.isEmpty

        let server = NSTextField(
            labelWithString: "Server: \(NotificationPreferences.ntfyServerURL)"
        )
        server.font = .systemFont(ofSize: 11)
        server.textColor = .tertiaryLabelColor

        let publicTopicWarning = WarningCalloutView(
            text:
                "Important: an unreserved ntfy.sh topic acts like a password, not an authorization boundary. Treat the topic and QR code as secrets. For enforced access control, reserve and protect the topic in ntfy or use a deny-by-default self-hosted server."
        )

        let testButton = SettingsActionButton(title: "Test Phone Alert") { [weak self] in
            self?.testPhoneAlert()
        }

        phoneStatusLabel.font = .systemFont(ofSize: 11)
        phoneStatusLabel.textColor = .secondaryLabelColor
        phoneStatusLabel.maximumNumberOfLines = 2
        phoneStatusLabel.lineBreakMode = .byWordWrapping

        let stack = NSStackView(
            views: [
                title,
                detail,
                enabledRow,
                eventsTitle,
                events,
                detailsButton,
                detailsDisclaimer,
                tokenTitle,
                tokenRow,
                topicTitle,
                topicRow,
                connectButton,
                server,
                publicTopicWarning,
                testButton,
                phoneStatusLabel,
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            enabledRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            events.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailsDisclaimer.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ),
            tokenRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            topicRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connectButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            publicTopicWarning.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ),
            testButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            phoneStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    private func buildTestingView() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "Testing")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString: "Send native notifications and add matching test entries to the dashboard."
        )
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2

        let alertButton = SettingsActionButton(title: "Test Alert") { [weak self] in
            self?.onTestAlert()
        }
        let allAppsButton = SettingsActionButton(title: "Test All Apps") { [weak self] in
            self?.onTestAllApps()
        }
        let surfaceButtons = NotificationSurface.supportedCases.map { surface in
            SettingsActionButton(title: "Test \(surface.displayName)") { [weak self] in
                self?.onTestSurface(surface)
            }
        }

        let stack = NSStackView(
            views: [title, detail, alertButton, allAppsButton] + surfaceButtons
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let actionButtons = [alertButton, allAppsButton] + surfaceButtons
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ] + actionButtons.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        return container
    }

    private func buildGeneralView() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let launchRow = SettingSwitchRow(
            title: "Launch at login",
            detail: "Keep Turnring running after you sign in.",
            isOn: preferences.launchAtLogin
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.launchAtLogin = enabled
            onLaunchAtLoginChanged(enabled)
        }

        let behaviorTitle = NSTextField(labelWithString: "Behavior")
        behaviorTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        behaviorTitle.textColor = .secondaryLabelColor

        let confirmQuitRow = SettingSwitchRow(
            title: "Confirm before quitting",
            detail: "Ask before stopping Turnring. On by default.",
            isOn: preferences.confirmBeforeQuit
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.confirmBeforeQuit = enabled
        }

        let historyTitle = NSTextField(labelWithString: "Dashboard history")
        historyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        historyTitle.textColor = .secondaryLabelColor

        let retentionRow = NumericPreferenceRow(
            title: "Remove notification after",
            value: preferences.historyRetentionMinutes,
            minimum: 1,
            maximum: 10_080,
            increment: 0.5,
            allowsDecimals: true,
            unit: "minutes"
        ) { [weak self] minutes in
            guard let self else { return }
            preferences.historyRetentionMinutes = minutes
            onHistoryPreferencesChanged()
        }
        retentionRow.controlsEnabled =
            preferences.automaticHistoryCleanupEnabled

        let cleanupRow = SettingSwitchRow(
            title: "Automatically remove completed items",
            detail: "Finished, failed, ended, and test items only.",
            isOn: preferences.automaticHistoryCleanupEnabled
        ) { [weak self, weak retentionRow] enabled in
            guard let self else { return }
            preferences.automaticHistoryCleanupEnabled = enabled
            retentionRow?.controlsEnabled = enabled
            onHistoryPreferencesChanged()
        }

        let historyDetail = NSTextField(
            wrappingLabelWithString:
                "Active work and unresolved Needs attention items are never removed automatically. Default: 5 minutes."
        )
        historyDetail.font = .systemFont(ofSize: 10)
        historyDetail.textColor = .tertiaryLabelColor
        historyDetail.maximumNumberOfLines = 3

        let stack = NSStackView(
            views: [
                title,
                launchRow,
                behaviorTitle,
                confirmQuitRow,
                historyTitle,
                cleanupRow,
                retentionRow,
                historyDetail,
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            launchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            confirmQuitRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cleanupRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            retentionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    private func buildNotificationsView() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "Notifications")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let previewLengthRow = NumericPreferenceRow(
            title: "Preview length",
            value: Double(preferences.localPreviewCharacterLimit),
            minimum: 10,
            maximum: Double(AttentionPreviewFormatter.maximumCharacters),
            increment: 5,
            allowsDecimals: false,
            unit: "characters"
        ) { [weak self] characters in
            guard let self else { return }
            preferences.localPreviewCharacterLimit = Int(characters)
            onDeliveryPreferencesChanged()
        }
        previewLengthRow.controlsEnabled =
            preferences.localAlertDetailsEnabled

        let privateDetailsRow = SettingSwitchRow(
            title: "Show sensitive titles and previews",
            detail: "Only while the Mac is unlocked.",
            isOn: preferences.localAlertDetailsEnabled
        ) { [weak self, weak previewLengthRow] enabled in
            guard let self else { return }
            preferences.localAlertDetailsEnabled = enabled
            previewLengthRow?.controlsEnabled = enabled
            onDeliveryPreferencesChanged()
        }

        let disclaimer = WarningCalloutView(
            text:
                "Sensitive Previews are off by default. They may reveal conversation titles, questions, commands, or filenames. Turnring removes detailed alerts when the screen locks. Also set macOS notification previews to When Unlocked."
        )

        let appsTitle = NSTextField(labelWithString: "Notify for")
        appsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        appsTitle.textColor = .secondaryLabelColor

        let notificationRows = NotificationSurface.supportedCases.map { surface in
            SettingSwitchRow(
                title: surface.displayName,
                detail: nil,
                isOn: preferences.notificationsEnabled(for: surface)
            ) { [weak self] enabled in
                guard let self else { return }
                preferences.setNotificationsEnabled(enabled, for: surface)
                onDeliveryPreferencesChanged()
            }
        }

        let durationDetail = NSTextField(
            wrappingLabelWithString:
                "Set 0 to always notify. Shorter tasks stay in dashboard history."
        )
        durationDetail.font = .systemFont(ofSize: 10)
        durationDetail.textColor = .tertiaryLabelColor
        durationDetail.maximumNumberOfLines = 2

        let durationRow = NumericPreferenceRow(
            title: "Minimum task duration",
            value: preferences.minimumTaskDuration,
            minimum: 0,
            maximum: 3_600,
            increment: 0.5,
            allowsDecimals: true,
            unit: "seconds"
        ) { [weak self] duration in
            guard let self else { return }
            preferences.setMinimumTaskDuration(duration)
            onDeliveryPreferencesChanged()
        }

        let stack = NSStackView(
            views: [
                title,
                privateDetailsRow,
                disclaimer,
                previewLengthRow,
                appsTitle,
            ] + notificationRows + [
                durationDetail,
                durationRow,
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: 26
            ),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -26
            ),
            stack.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: 24
            ),
            privateDetailsRow.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ),
            disclaimer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewLengthRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            durationDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            durationRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ] + notificationRows.map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        })
        return container
    }

    private func buildIntegrationView() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "Integration")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        integrationStatusLabel.font = .systemFont(
            ofSize: 15,
            weight: .semibold
        )
        integrationStatusLabel.maximumNumberOfLines = 2

        integrationDetailLabel.font = .systemFont(ofSize: 11)
        integrationDetailLabel.textColor = .secondaryLabelColor
        integrationDetailLabel.maximumNumberOfLines = 5

        let explanation = NSTextField(
            wrappingLabelWithString:
                "Turnring-owned hooks receive bounded lifecycle metadata from Codex and Claude Code. Repairing replaces only Turnring-owned entries and preserves unrelated configuration."
        )
        explanation.font = .systemFont(ofSize: 10.5)
        explanation.textColor = .tertiaryLabelColor
        explanation.maximumNumberOfLines = 4

        let providerChoices = AgentProvider.allCases.map { provider in
            CallbackCheckbox(
                title: provider == .codex ? "Codex" : "Claude Code",
                isOn: preferences.integrationEnabled(for: provider)
            ) { [weak self] enabled in
                guard let self else { return }
                preferences.setIntegrationEnabled(enabled, for: provider)
                updateIntegrationPresentation()
            }
        }
        let providers = NSStackView(views: providerChoices)
        providers.orientation = .horizontal
        providers.distribution = .fillEqually
        providers.spacing = 12

        let actionButton = SettingsActionButton(
            title: "Repair Integration",
            style: .primary
        ) { [weak self] in
            self?.repairIntegration()
        }
        integrationActionButton = actionButton

        let stack = NSStackView(
            views: [
                title,
                integrationStatusLabel,
                integrationDetailLabel,
                explanation,
                providers,
                actionButton,
                codexTrustNotice,
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: 26
            ),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -26
            ),
            stack.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: 24
            ),
            integrationStatusLabel.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ),
            integrationDetailLabel.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            providers.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codexTrustNotice.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateIntegrationPresentation()
        return container
    }

    private func buildInfoView() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "Info")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        let name = NSTextField(labelWithString: "Turnring")
        name.font = .systemFont(ofSize: 18, weight: .semibold)
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let versionLabel = NSTextField(
            labelWithString: "Version \(version) (build \(build))"
        )
        versionLabel.textColor = .secondaryLabelColor

        let detail = NSTextField(
            wrappingLabelWithString: "A private macOS notifier for Codex and Claude Code. Native details are opt-in and lock-aware. ntfy is optional, minimal by default, and Keychain-protected."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 4

        let resetButton = SettingsActionButton(
            title: "Reset All Settings…"
        ) { [weak self] in
            self?.onResetSettings()
        }

        let uninstallButton = SettingsActionButton(
            title: "Uninstall Turnring…",
            style: .destructive
        ) { [weak self] in
            self?.onUninstall()
        }

        let stack = NSStackView(
            views: [
                title,
                icon,
                name,
                versionLabel,
                detail,
                resetButton,
                uninstallButton,
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 82),
            icon.heightAnchor.constraint(equalToConstant: 82),
            icon.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 12),
            resetButton.widthAnchor.constraint(equalToConstant: 180),
            resetButton.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            uninstallButton.widthAnchor.constraint(equalToConstant: 180),
        ])
        return container
    }

    private func show(_ section: SettingsSection) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let selectedView: NSView
        switch section {
        case .general:
            selectedView = generalView
        case .notifications:
            selectedView = notificationsView
        case .phone:
            selectedView = phoneView
        case .integration:
            selectedView = integrationView
        case .testing:
            selectedView = testingView
        case .info:
            selectedView = infoView
        }
        selectedView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(selectedView)
        NSLayoutConstraint.activate([
            selectedView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            selectedView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            selectedView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            selectedView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        generalButton.isSelected = section == .general
        notificationsButton.isSelected = section == .notifications
        phoneButton.isSelected = section == .phone
        integrationButton.isSelected = section == .integration
        testingButton.isSelected = section == .testing
        infoButton.isSelected = section == .info
    }

    @objc private func showGeneral() {
        show(.general)
    }

    @objc private func showInfo() {
        show(.info)
    }

    @objc private func showNotifications() {
        show(.notifications)
    }

    @objc private func showPhone() {
        show(.phone)
    }

    @objc private func showIntegration() {
        show(.integration)
    }

    @objc private func showTesting() {
        show(.testing)
    }

    private func repairIntegration() {
        guard integrationActionTask == nil else { return }
        integrationActionButton?.isEnabled = false
        integrationStatusLabel.stringValue = "Repairing integration…"
        integrationStatusLabel.textColor = .secondaryLabelColor
        integrationActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                integrationStatus = try await onRepairIntegration()
                guard !Task.isCancelled else { return }
                updateIntegrationPresentation()
            } catch {
                guard !Task.isCancelled else { return }
                integrationStatusLabel.stringValue =
                    "Integration could not be repaired"
                integrationStatusLabel.textColor = .systemRed
                integrationDetailLabel.stringValue =
                    error.localizedDescription
            }
            integrationActionButton?.isEnabled = true
            integrationActionTask = nil
        }
    }

    private func updateIntegrationPresentation() {
        let selected = preferences.selectedIntegrations
        let installed = !selected.isEmpty && selected.allSatisfy { provider in
            provider == .codex ? integrationStatus.codex : integrationStatus.claude
        }
        integrationStatusLabel.stringValue = selected.isEmpty
            ? "Choose at least one integration"
            : installed
            ? "Integration installed"
            : "Integration needs setup or repair"
        integrationStatusLabel.textColor = selected.isEmpty
            ? .secondaryLabelColor
            : installed
            ? .systemGreen
            : .systemOrange
        integrationDetailLabel.stringValue = [
            "Codex hooks: \(preferences.integrationEnabled(for: .codex) ? (integrationStatus.codex ? "Installed" : "Missing") : "Not selected")",
            "Claude Code hooks: \(preferences.integrationEnabled(for: .claude) ? (integrationStatus.claude ? "Installed" : "Missing") : "Not selected")",
            "VS Code focus companion: \(integrationStatus.vscode ? "Installed" : "Not installed (optional)")",
        ].joined(separator: "\n")
        integrationActionButton?.title = installed
            ? "Repair Integration"
            : "Install Integration"
        integrationActionButton?.isEnabled = !selected.isEmpty
        codexTrustNotice.isHidden = !preferences.integrationEnabled(for: .codex)
    }

    private func copyNtfyTopic() {
        let topic = preferences.ntfyTopic
        guard NtfyRequestBuilder.isValidTopic(topic) else {
            setPhoneStatus(
                "The secure topic is unavailable. Check Keychain access and reopen Turnring.",
                isError: true
            )
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(topic, forType: .string)
        topicClipboardClearTask?.cancel()
        topicClipboardClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            let currentPasteboard = NSPasteboard.general
            if currentPasteboard.string(forType: .string) == topic {
                currentPasteboard.clearContents()
            }
            self?.topicClipboardClearTask = nil
        }
        setPhoneStatus(
            "Topic copied. The clipboard copy will clear after 60 seconds."
        )
    }

    private func showPhoneConnection() {
        let topic = preferences.ntfyTopic
        guard let setupURL = NtfyDeviceSetupLink.makeURL(
            serverURL: NotificationPreferences.ntfyServerURL,
            topic: topic
        ),
            let qrImage = makeQRCode(for: setupURL)
        else {
            setPhoneStatus(
                "The secure phone setup link is unavailable.",
                isError: true
            )
            return
        }

        let qrView = NSImageView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        qrView.image = qrImage
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.setAccessibilityLabel("Turnring random ntfy topic QR code")

        let alert = NSAlert()
        alert.messageText = "Connect this phone"
        alert.informativeText =
            "Treat this QR code like a password. Scan it only on the intended iPhone or Android device. In ntfy, subscribe to the opened Turnring topic and allow notifications. Then use Test Phone Alert to verify receipt."
        alert.alertStyle = .informational
        alert.accessoryView = qrView
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    private func makeQRCode(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 9, y: 9)
        ) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        image.isTemplate = false
        return image
    }

    private func saveNtfyAccessToken() {
        do {
            try ntfyAccessTokenStore.saveToken(ntfyTokenField.stringValue)
            view.window?.makeFirstResponder(nil)
            setPhoneStatus("Access token saved securely in macOS Keychain.")
        } catch {
            setPhoneStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeNtfyAccessToken() {
        do {
            try ntfyAccessTokenStore.deleteToken()
            ntfyTokenField.stringValue = ""
            ntfyTokenField.placeholderString = "Paste an ntfy publish token"
            setPhoneStatus("Access token removed from macOS Keychain.")
        } catch {
            setPhoneStatus(error.localizedDescription, isError: true)
        }
    }

    private func codexInstructions() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.systemYellow,
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.systemYellow,
        ]
        result.append(NSAttributedString(string: "Codex Desktop\n", attributes: heading))
        result.append(NSAttributedString(
            string: "In Codex Desktop, go to Settings, click Hooks under Coding, and approve all six hooks.\n\n",
            attributes: body
        ))
        result.append(NSAttributedString(string: "Codex CLI\nRun ", attributes: heading))
        result.append(NSAttributedString(
            string: "/hooks",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.systemYellow,
            ]
        ))
        result.append(NSAttributedString(
            string: " and approve all hooks.",
            attributes: body
        ))
        return result
    }

    private func testPhoneAlert() {
        phoneActionTask?.cancel()
        setPhoneStatus("Sending test alert…", autoHide: false)
        phoneActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await onTestPhoneAlert()
                guard !Task.isCancelled else { return }
                setPhoneStatus(
                    "Test sent. Confirm that it appeared on the phone you connected."
                )
            } catch {
                guard !Task.isCancelled else { return }
                setPhoneStatus(
                    "Could not send: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
    }

    private func setPhoneStatus(
        _ message: String,
        isError: Bool = false,
        autoHide: Bool = true
    ) {
        phoneStatusHideTask?.cancel()
        phoneStatusLabel.stringValue = message
        phoneStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        guard autoHide else { return }
        phoneStatusHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.phoneStatusLabel.stringValue = ""
        }
    }
}

@MainActor
private final class SettingsNavigationButton: LiquidGlassButton {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(title: String, symbol: String) {
        super.init(title: title, glassStyle: .navigation)
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 14, weight: .medium)
        alignGlassContentLeading(inset: 12)
        layer?.cornerRadius = 12
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateLayer() {
        isSelectedGlass = isSelected
        super.updateLayer()
    }

}
@MainActor
private final class SettingSwitchRow: NSView {
    init(
        title: String,
        detail: String?,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let labels: NSStackView
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            labels = NSStackView(views: [titleLabel, detailLabel])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2
        } else {
            labels = NSStackView(views: [titleLabel])
        }

        let toggle = CallbackSwitch(isOn: isOn, onChange: onChange)
        let spacer = NSView()
        let row = NSStackView(views: [labels, spacer, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        wantsLayer = true
        layer?.cornerRadius = 10
        needsDisplay = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: detail == nil ? 34 : 50),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

@MainActor
private final class NumericPreferenceRow: NSView, NSTextFieldDelegate {
    private let onChange: (Double) -> Void
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let minimum: Double
    private let maximum: Double
    private let allowsDecimals: Bool
    var controlsEnabled = true {
        didSet {
            field.isEnabled = controlsEnabled
            stepper.isEnabled = controlsEnabled
            alphaValue = controlsEnabled ? 1 : 0.5
        }
    }

    init(
        title: String,
        value: Double,
        minimum: Double,
        maximum: Double,
        increment: Double,
        allowsDecimals: Bool,
        unit: String,
        onChange: @escaping (Double) -> Void
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.allowsDecimals = allowsDecimals
        self.onChange = onChange
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = allowsDecimals
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = allowsDecimals ? 2 : 0
        formatter.usesGroupingSeparator = false
        formatter.minimum = NSNumber(value: minimum)
        formatter.maximum = NSNumber(value: maximum)

        field.formatter = formatter
        field.alignment = .right
        field.doubleValue = normalized(value)
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 68).isActive = true

        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = max(0.01, increment)
        stepper.doubleValue = field.doubleValue
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = .systemFont(ofSize: 11)
        unitLabel.textColor = .secondaryLabelColor

        let row = NSStackView(
            views: [titleLabel, NSView(), field, stepper, unitLabel]
        )
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        wantsLayer = true
        layer?.cornerRadius = 10
        needsDisplay = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    @objc private func stepperChanged() {
        field.doubleValue = stepper.doubleValue
        publishValue()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        publishValue()
    }

    private func publishValue() {
        let value = normalized(field.doubleValue)
        field.doubleValue = value
        stepper.doubleValue = value
        onChange(value)
    }

    private func normalized(_ value: Double) -> Double {
        let clamped = max(minimum, min(maximum, value))
        return allowsDecimals ? clamped : clamped.rounded()
    }
}

@MainActor
private final class CallbackSwitch: NSSwitch {
    private let onChange: (Bool) -> Void

    init(isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        state = isOn ? .on : .off
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func changed() {
        onChange(state == .on)
    }
}

@MainActor
private final class CallbackCheckbox: NSButton {
    private let onChange: (Bool) -> Void

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        state = isOn ? .on : .off
        font = .systemFont(ofSize: 11)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func changed() {
        onChange(state == .on)
    }
}

@MainActor
private final class SettingsActionButton: LiquidGlassButton {
    enum Style {
        case secondary
        case primary
        case destructive
    }

    private let onPress: () -> Void
    init(
        title: String,
        style: Style = .secondary,
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress
        super.init(title: title, glassStyle: style.glassStyle)
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 12, weight: .medium)
        alignment = .center
        target = self
        action = #selector(pressed)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func pressed() {
        onPress()
    }
}

private extension SettingsActionButton.Style {
    var glassStyle: LiquidGlassButton.GlassStyle {
        switch self {
        case .secondary: .secondary
        case .primary: .primary
        case .destructive: .destructive
        }
    }
}
