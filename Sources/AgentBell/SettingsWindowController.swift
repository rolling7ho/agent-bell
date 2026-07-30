import AgentBellCore
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
        window.title = "AgentBell Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(SettingsMetrics.windowSize)
        window.minSize = SettingsMetrics.windowSize
        window.maxSize = SettingsMetrics.windowSize
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
private enum SettingsMetrics {
    static let windowSize = NSSize(width: 560, height: 660)
    static let sidebarWidth: CGFloat = 168
    static let navigationRowWidth: CGFloat = 144
    static let contentInset = Theme.Metrics.sectionInset
    static let topInset: CGFloat = 32
    static let bottomInset: CGFloat = 24
    static let groupSpacing: CGFloat = 16
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
    private var currentSection: SettingsSection?
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
    private let integrationSummary = IntegrationSummaryView()
    private let codexStatusRow = StatusRow(title: "Codex hooks")
    private let claudeStatusRow = StatusRow(title: "Claude Code hooks")
    private let vscodeStatusRow = StatusRow(
        title: "VS Code focus companion",
        isOptional: true
    )
    private var integrationActionButton: PillButton?
    private var phoneActionTask: Task<Void, Never>?
    private var phoneStatusHideTask: Task<Void, Never>?
    private var topicClipboardClearTask: Task<Void, Never>?
    private var integrationActionTask: Task<Void, Never>?
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
        view = NSView(
            frame: NSRect(
                origin: .zero,
                size: SettingsMetrics.windowSize
            )
        )
        buildInterface()
        show(initialSection)
    }

    private func buildInterface() {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow

        let appIcon = NSImageView()
        appIcon.image = NSApplication.shared.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown

        let heading = NSTextField(labelWithString: "AgentBell")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let headingRow = NSStackView(views: [appIcon, heading])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = 7
        headingRow.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 0)

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
                headingRow,
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
        navigation.spacing = 4
        navigation.edgeInsets = NSEdgeInsets(top: 30, left: 12, bottom: 12, right: 12)

        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        sidebar.addSubview(navigation)
        view.addSubview(contentContainer)

        let navigationButtons = [
            generalButton,
            notificationsButton,
            phoneButton,
            integrationButton,
            testingButton,
            infoButton,
        ]

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(
                equalToConstant: SettingsMetrics.sidebarWidth
            ),

            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 22),
            appIcon.heightAnchor.constraint(equalToConstant: 22),

            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ] + navigationButtons.map {
            $0.widthAnchor.constraint(
                equalToConstant: SettingsMetrics.navigationRowWidth
            )
        })
    }

    // MARK: - Sections

    private func buildGeneralView() -> NSView {
        let header = SectionHeaderView(
            title: "General",
            subtitle: "How AgentBell starts up and how long it keeps history."
        )

        let launchRow = SettingSwitchRow(
            title: "Launch at login",
            detail: "Keep AgentBell running after you sign in.",
            isOn: preferences.launchAtLogin
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.launchAtLogin = enabled
            onLaunchAtLoginChanged(enabled)
        }

        let confirmQuitRow = SettingSwitchRow(
            title: "Confirm before quitting",
            detail: "Ask before stopping AgentBell. On by default.",
            isOn: preferences.confirmBeforeQuit
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.confirmBeforeQuit = enabled
        }

        let retentionRow = NumericPreferenceRow(
            title: "Remove after",
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
            title: "Remove completed items automatically",
            detail: "Finished, failed, ended, and test items only.",
            isOn: preferences.automaticHistoryCleanupEnabled
        ) { [weak self, weak retentionRow] enabled in
            guard let self else { return }
            preferences.automaticHistoryCleanupEnabled = enabled
            retentionRow?.controlsEnabled = enabled
            onHistoryPreferencesChanged()
        }

        return makeSection(
            header: header,
            blocks: [
                SettingsGroup(title: "Startup", rows: [launchRow]),
                SettingsGroup(title: "Behavior", rows: [confirmQuitRow]),
                SettingsGroup(
                    title: "Dashboard history",
                    rows: [cleanupRow, retentionRow]
                ),
                makeFootnote(
                    "Active work and unresolved Needs attention items are never removed automatically. Default: 30 minutes."
                ),
            ]
        )
    }

    private func buildNotificationsView() -> NSView {
        let header = SectionHeaderView(
            title: "Notifications",
            subtitle: "Native alerts on this Mac, and how much they may reveal."
        )

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
            detail: "Only while the Mac is unlocked. Off by default.",
            isOn: preferences.localAlertDetailsEnabled
        ) { [weak self, weak previewLengthRow] enabled in
            guard let self else { return }
            preferences.localAlertDetailsEnabled = enabled
            previewLengthRow?.controlsEnabled = enabled
            onDeliveryPreferencesChanged()
        }

        let notificationRows = NotificationSurface.allCases.map { surface in
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

        let durationSurfaces: [NotificationSurface] = [
            .chatGPTDesktop,
            .claudeDesktop,
        ]
        let durationRows = durationSurfaces.map { surface in
            NumericPreferenceRow(
                title: surface.displayName,
                value: preferences.minimumTaskDuration(for: surface),
                minimum: 0,
                maximum: 3_600,
                increment: 0.5,
                allowsDecimals: true,
                unit: "seconds"
            ) { [weak self] duration in
                guard let self else { return }
                preferences.setMinimumTaskDuration(duration, for: surface)
                onDeliveryPreferencesChanged()
            }
        }

        return makeSection(
            header: header,
            blocks: [
                SettingsGroup(
                    title: "Privacy",
                    rows: [privateDetailsRow, previewLengthRow]
                ),
                InlineNoticeView(
                    style: .info,
                    text: "Sensitive previews may reveal conversation titles, questions, commands, or filenames. AgentBell removes detailed alerts when the screen locks; also set macOS notification previews to When Unlocked.",
                    maximumLines: 4
                ),
                SettingsGroup(title: "Notify for", rows: notificationRows),
                SettingsGroup(
                    title: "Minimum task duration",
                    rows: durationRows
                ),
                makeFootnote(
                    "Set 0 to always notify. Shorter tasks stay in dashboard history."
                ),
            ]
        )
    }

    private func buildPhoneView() -> NSView {
        let header = SectionHeaderView(
            title: "Phone",
            subtitle: "Optional ntfy.sh alerts. The topic and token stay in Keychain."
        )

        let enabledRow = SettingSwitchRow(
            title: "Phone alerts",
            detail: "No network request is made while this is off.",
            isOn: preferences.phoneAlertsEnabled
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.phoneAlertsEnabled = enabled
            onDeliveryPreferencesChanged()
        }

        let alertStates: [(AgentState, String)] = [
            (.attention, "Needs attention"),
            (.finished, "Finished"),
            (.failed, "Failed"),
        ]
        let eventRows = alertStates.map { state, label in
            SettingSwitchRow(
                title: label,
                detail: nil,
                isOn: preferences.phoneAlertEnabled(for: state)
            ) { [weak self] enabled in
                guard let self else { return }
                preferences.setPhoneAlertEnabled(enabled, for: state)
                onDeliveryPreferencesChanged()
            }
        }

        let detailsRow = SettingSwitchRow(
            title: "Include task titles and previews",
            detail: "Off by default. Details may appear on a lock screen.",
            isOn: preferences.phoneAlertDetailsEnabled
        ) { [weak self] enabled in
            guard let self else { return }
            preferences.phoneAlertDetailsEnabled = enabled
            onDeliveryPreferencesChanged()
        }

        ntfyTokenField.placeholderString = ntfyAccessTokenStore.hasToken()
            ? "Token saved in macOS Keychain"
            : "Paste an ntfy publish token"
        ntfyTokenField.usesSingleLineMode = true
        ntfyTokenField.maximumNumberOfLines = 1
        ntfyTokenField.font = .systemFont(ofSize: 12)

        let saveTokenButton = PillButton(
            title: "Save",
            width: 62
        ) { [weak self] in
            self?.saveNtfyAccessToken()
        }
        let removeTokenButton = PillButton(
            title: "Remove",
            width: 74
        ) { [weak self] in
            self?.removeNtfyAccessToken()
        }
        let tokenRow = FieldRow(
            title: "Publish access token",
            detail: "Required for reserved or protected topics.",
            field: ntfyTokenField,
            accessories: [saveTokenButton, removeTokenButton]
        )

        let secureTopic = preferences.ntfyTopic
        let maskedTopic = secureTopic.isEmpty
            ? "Secure topic unavailable"
            : "\(SecureNtfyTopic.prefix)••••••••\(secureTopic.suffix(8))"
        let copyButton = IconButton(
            symbol: "doc.on.doc",
            accessibilityDescription: "Copy topic",
            pointSize: 12,
            size: 26
        )
        copyButton.target = self
        copyButton.action = #selector(copyTopicPressed)
        copyButton.isEnabled = !secureTopic.isEmpty
        let topicRow = ValueRow(
            title: "Random ntfy topic",
            value: maskedTopic,
            monospaced: true,
            accessory: copyButton
        )
        topicRow.toolTip = secureTopic.isEmpty
            ? nil
            : "Stored securely in macOS Keychain"

        let serverRow = ValueRow(
            title: "Server",
            value: NotificationPreferences.ntfyServerURL,
            monospaced: false,
            accessory: nil
        )

        let connectButton = PillButton(
            title: "Connect Phone…",
            style: .primary,
            symbol: "qrcode"
        ) { [weak self] in
            self?.showPhoneConnection()
        }
        connectButton.isEnabled = !secureTopic.isEmpty
        let testButton = PillButton(
            title: "Test Phone Alert",
            symbol: "paperplane"
        ) { [weak self] in
            self?.testPhoneAlert()
        }
        let actionRow = NSStackView(views: [connectButton, testButton])
        actionRow.orientation = .horizontal
        actionRow.distribution = .fillEqually
        actionRow.spacing = 8

        phoneStatusLabel.font = .systemFont(ofSize: 11)
        phoneStatusLabel.textColor = .secondaryLabelColor
        phoneStatusLabel.maximumNumberOfLines = 2
        phoneStatusLabel.lineBreakMode = .byWordWrapping

        return makeSection(
            header: header,
            blocks: [
                SettingsGroup(title: "Delivery", rows: [enabledRow] + eventRows),
                SettingsGroup(title: "Privacy", rows: [detailsRow]),
                InlineNoticeView(
                    style: .info,
                    text: "Previews can expose task names, questions, commands, or filenames on your phone. Leave this off unless your phone previews are private.",
                    maximumLines: 3
                ),
                SettingsGroup(
                    title: "Connection",
                    rows: [tokenRow, topicRow, serverRow]
                ),
                actionRow,
                InlineNoticeView(
                    style: .warning,
                    text: "An unreserved ntfy.sh topic acts like a password, not an authorization boundary. Treat the topic and QR code as secrets. For enforced access control, reserve and protect the topic in ntfy or use a deny-by-default self-hosted server.",
                    maximumLines: 4
                ),
                phoneStatusLabel,
            ]
        )
    }

    private func buildIntegrationView() -> NSView {
        let header = SectionHeaderView(
            title: "Integration",
            subtitle: "Hooks that let Codex and Claude Code report lifecycle events."
        )

        let actionButton = PillButton(
            title: "Repair Integration",
            style: .primary,
            symbol: "wrench.and.screwdriver"
        ) { [weak self] in
            self?.repairIntegration()
        }
        integrationActionButton = actionButton

        let section = makeSection(
            header: header,
            blocks: [
                integrationSummary,
                SettingsGroup(
                    title: "Installed hooks",
                    rows: [codexStatusRow, claudeStatusRow, vscodeStatusRow]
                ),
                actionButton,
                makeFootnote(
                    "Repairing replaces only AgentBell-owned entries and preserves unrelated configuration."
                ),
                InlineNoticeView(
                    style: .info,
                    text: "After installing or repairing Codex hooks, open /hooks in Codex and approve AgentBell if Codex asks you to trust the integration.",
                    maximumLines: 3
                ),
            ]
        )
        updateIntegrationPresentation()
        return section
    }

    private func buildTestingView() -> NSView {
        let header = SectionHeaderView(
            title: "Testing",
            subtitle: "Send native notifications and add matching dashboard entries."
        )

        let alertRow = ActionRow(
            title: "Generic alert",
            detail: "One notification with no app-specific routing.",
            buttonTitle: "Send"
        ) { [weak self] in
            self?.onTestAlert()
        }
        let allAppsRow = ActionRow(
            title: "Every app at once",
            detail: "One notification per supported surface.",
            buttonTitle: "Send All"
        ) { [weak self] in
            self?.onTestAllApps()
        }
        let surfaceRows = NotificationSurface.allCases.map { surface in
            ActionRow(
                title: surface.displayName,
                detail: nil,
                buttonTitle: "Send"
            ) { [weak self] in
                self?.onTestSurface(surface)
            }
        }

        return makeSection(
            header: header,
            blocks: [
                SettingsGroup(
                    title: "Quick checks",
                    rows: [alertRow, allAppsRow]
                ),
                SettingsGroup(title: "Single surface", rows: surfaceRows),
                makeFootnote(
                    "If macOS accepts an alert but no banner appears, turn off Focus or allow AgentBell in the active Focus mode."
                ),
            ]
        )
    }

    private func buildInfoView() -> NSView {
        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        let name = NSTextField(labelWithString: "AgentBell")
        name.font = .systemFont(ofSize: 18, weight: .semibold)
        name.alignment = .center

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let versionLabel = NSTextField(
            labelWithString: "Version \(version) (build \(build))"
        )
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let detail = NSTextField(
            wrappingLabelWithString: "A private macOS notifier for ChatGPT Desktop, Codex, Claude Desktop, and Claude Code. Native details are opt-in and lock-aware. ntfy is optional, minimal by default, and Keychain-protected."
        )
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 4

        let about = NSStackView(views: [icon, name, versionLabel, detail])
        about.orientation = .vertical
        about.alignment = .centerX
        about.spacing = 6
        about.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        let resetRow = ActionRow(
            title: "Reset all settings",
            detail: "Restores defaults and creates a new secure topic.",
            buttonTitle: "Reset…"
        ) { [weak self] in
            self?.onResetSettings()
        }
        let uninstallRow = ActionRow(
            title: "Uninstall AgentBell",
            detail: "Removes hooks, history, and stored secrets.",
            buttonTitle: "Uninstall…",
            buttonStyle: .destructive
        ) { [weak self] in
            self?.onUninstall()
        }

        let section = makeSection(
            header: SectionHeaderView(title: "Info", subtitle: nil),
            blocks: [
                about,
                SettingsGroup(
                    title: "Reset and removal",
                    rows: [resetRow, uninstallRow]
                ),
            ]
        )
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 76),
            icon.heightAnchor.constraint(equalToConstant: 76),
        ])
        return section
    }

    // MARK: - Section scaffolding

    /// Lays out a section header plus content blocks inside a scroll view so
    /// long sections stay reachable in the fixed-size window.
    private func makeSection(
        header: SectionHeaderView,
        blocks: [NSView]
    ) -> NSView {
        let container = NSView()
        let stack = NSStackView(views: [header] + blocks)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.groupSpacing
        stack.setCustomSpacing(20, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: SettingsMetrics.contentInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -SettingsMetrics.contentInset
            ),
            stack.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: SettingsMetrics.topInset
            ),
            stack.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -SettingsMetrics.bottomInset
            ),
        ] + ([header] + blocks).map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        })
        return Theme.makeScrollView(content: container)
    }

    private func makeFootnote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.Text.footnote
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 4
        return label
    }

    private func show(_ section: SettingsSection) {
        guard currentSection != section else { return }
        currentSection = section
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
        selectedView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            selectedView.animator().alphaValue = 1
        }

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

    // MARK: - Actions

    private func repairIntegration() {
        guard integrationActionTask == nil else { return }
        integrationActionButton?.isEnabled = false
        integrationSummary.update(
            state: .working,
            message: "Repairing integration…"
        )
        integrationActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                integrationStatus = try await onRepairIntegration()
                guard !Task.isCancelled else { return }
                updateIntegrationPresentation()
            } catch {
                guard !Task.isCancelled else { return }
                integrationSummary.update(
                    state: .failed,
                    message: "Integration could not be repaired",
                    detail: error.localizedDescription
                )
            }
            integrationActionButton?.isEnabled = true
            integrationActionTask = nil
        }
    }

    private func updateIntegrationPresentation() {
        let installed = integrationStatus.codex && integrationStatus.claude
        integrationSummary.update(
            state: installed ? .installed : .needsSetup,
            message: installed
                ? "Integration installed"
                : "Integration needs setup or repair",
            detail: installed
                ? "AgentBell owns its hook entries in both providers."
                : "Install the hooks so lifecycle events reach AgentBell."
        )
        codexStatusRow.update(isInstalled: integrationStatus.codex)
        claudeStatusRow.update(isInstalled: integrationStatus.claude)
        vscodeStatusRow.update(isInstalled: integrationStatus.vscode)
        integrationActionButton?.title = installed
            ? "Repair Integration"
            : "Install Integration"
    }

    @objc private func copyTopicPressed() {
        copyNtfyTopic()
    }

    private func copyNtfyTopic() {
        let topic = preferences.ntfyTopic
        guard NtfyRequestBuilder.isValidTopic(topic) else {
            setPhoneStatus(
                "The secure topic is unavailable. Check Keychain access and reopen AgentBell.",
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
        qrView.setAccessibilityLabel("AgentBell random ntfy topic QR code")

        let alert = NSAlert()
        alert.messageText = "Connect this phone"
        alert.informativeText =
            "Treat this QR code like a password. Scan it only on the intended iPhone or Android device. In ntfy, subscribe to the opened AgentBell topic and allow notifications. Then use Test Phone Alert to verify receipt."
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
            ntfyTokenField.stringValue = ""
            ntfyTokenField.placeholderString = "Token saved in macOS Keychain"
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
