import TurnringCore
import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private lazy var sessionStore = SessionStore()
    private let conversationTitleResolver = ConversationTitleResolver()
    private let navigationRouter = NavigationRouter()
    private let notificationPreferences = NotificationPreferences()
    private let ntfyPublisher = NtfyPublisher()
    private let ntfyAccessTokenStore = NtfyAccessTokenStore()
    private lazy var ntfyOutbox = NtfyOutbox()
    private lazy var screenLockMonitor: ScreenLockMonitor = {
        let monitor = ScreenLockMonitor()
        monitor.onLock = { [weak self] in
            self?.removeSensitiveDeliveredNotifications()
        }
        return monitor
    }()
    private var instanceLock: SingleInstanceLock?
    private var configurationInstaller: ConfigurationInstaller!
    private var settingsWindowController: SettingsWindowController?
    private var onboardingViewController: OnboardingViewController?
    private var statusItem: NSStatusItem!
    private let menuPanel = MenuBarPanelController(
        contentSize: NSSize(width: 430, height: 480)
    )
    private let dashboard = DashboardViewController()
    private var queueTimer: Timer?
    private var livenessTimer: Timer?
    private var historyCleanupTimer: Timer?
    private var phoneDeliveryTimer: Timer?
    private var livenessTracker = SessionLivenessTracker()
    private var pendingNotificationKeys = Set<String>()
    private var isDrainingQueue = false
    private var isDrainingPhoneOutbox = false
    private var phoneDeliveryTask: Task<Void, Never>?
    private var isUninstalling = false
    private var lastSystemWakeAt: Date?
    private var integrationStatus = IntegrationStatus(
        codex: false,
        claude: false,
        vscode: false
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BundleIntegrityVerifier.isValidAppBundle(
            at: Bundle.main.bundleURL
        ) else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Turnring was modified"
            alert.informativeText =
                "The application signature or a bundled resource is invalid. Turnring will not run. Delete this copy and obtain a verified build from the original distributor."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }

        _ = try? notificationPreferences.prepareSecureNtfyTopic()
        do {
            try TurnringPaths.prepareRuntimeDirectories()
            TurnringPaths.cleanupStaleRuntimeFiles()
        } catch {
            showError("Turnring could not prepare its private data directory.")
        }
        guard let lock = SingleInstanceLock(
            url: TurnringPaths.instanceLockFile
        ) else {
            NSApplication.shared.terminate(nil)
            return
        }
        instanceLock = lock

        let bundledHookExecutable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/TurnringHook").path
        do {
            try ConfigurationInstaller.preparePersistentHookLauncher(
                at: TurnringPaths.integrationHookLauncher,
                bundledHookExecutablePath: bundledHookExecutable
            )
        } catch {
            showError(error.localizedDescription)
        }
        configurationInstaller = ConfigurationInstaller(
            hookExecutablePath: TurnringPaths.integrationHookLauncher.path,
            vscodeVSIXPath: Bundle.main.resourceURL?
                .appendingPathComponent("VSCode/turnring-focus.vsix").path
        )

        prefillExistingIntegrationSelectionIfNeeded()

        configureMenuBar()
        configureDashboard()
        configureNotifications()
        _ = screenLockMonitor
        registerAtLogin()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receivedHookEvent),
            name: TurnringPaths.eventNotificationName,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        queueTimer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(drainQueue),
            userInfo: nil,
            repeats: true
        )
        phoneDeliveryTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(drainPhoneOutbox),
            userInfo: nil,
            repeats: true
        )

        livenessTracker = SessionLivenessTracker(
            sessions: sessionStore.allSessions()
        )
        updateLivenessTimer()
        updateHistoryCleanupTimer()
        reconcilePhoneOutbox()
        refreshStoredConversationTitlesInBackground()
        drainQueue()
        refreshDashboard()
        refreshIntegrationHealth()
        presentOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        queueTimer?.invalidate()
        livenessTimer?.invalidate()
        historyCleanupTimer?.invalidate()
        phoneDeliveryTimer?.invalidate()
        phoneDeliveryTask?.cancel()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        drainQueue()
        drainPhoneOutbox()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshNotificationDeliveryStatus()
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = menuBarIcon(needsAttention: false)
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Turnring"
        }

        menuPanel.contentViewController = notificationPreferences.onboardingCompleted
            ? dashboard
            : nil
    }

    private func configureDashboard() {
        dashboard.onOpenSession = { [weak self] session in
            guard let self else { return }
            guard !session.isTest else { return }
            self.menuPanel.close()
            let result = self.navigationRouter.open(session)
            if case .unavailable(let message) = result {
                self.showError(message)
            }
        }
        dashboard.onClearSession = { [weak self] session in
            guard let self else { return }
            let matchingSnapshots = sessionStore.allSessions().filter {
                SessionPresentation.representsSameInstance($0, session)
            }
            for snapshot in matchingSnapshots {
                guard sessionStore.remove(
                    sessionKey: snapshot.sessionKey,
                    ifUpdatedAt: snapshot.updatedAt
                ) else {
                    continue
                }
                livenessTracker.remove(snapshot.sessionKey)
                try? ntfyOutbox.discard(
                    id: alertIdentifier(for: snapshot)
                )
                removeNotifications(for: snapshot)
            }
            updateLivenessTimer()
            refreshDashboard()
        }
        dashboard.onClearHistory = { [weak self] snapshots in
            guard let self else { return }
            for snapshot in snapshots {
                guard sessionStore.remove(
                    sessionKey: snapshot.sessionKey,
                    ifUpdatedAt: snapshot.updatedAt
                ) else {
                    continue
                }
                livenessTracker.remove(snapshot.sessionKey)
                try? ntfyOutbox.discard(
                    id: alertIdentifier(for: snapshot)
                )
                removeNotifications(for: snapshot)
            }
            updateLivenessTimer()
            refreshDashboard()
        }
        dashboard.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        dashboard.onQuit = { [weak self] in
            self?.quitTurnring()
        }
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        clearLegacyProjectSubtitleNotificationsIfNeeded(center)
        let openAction = UNNotificationAction(
            identifier: "OPEN_SESSION",
            title: "Open Session",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "AGENT_EVENT",
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        if notificationPreferences.onboardingCompleted {
            requestNotificationAuthorization()
        }
    }

    private func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDashboard()
                if let error {
                    self.dashboard.setBusy(
                        false,
                        message: "macOS notification permission failed: \(error.localizedDescription)"
                    )
                } else if !granted {
                    self.showNotificationSettingsWarning()
                } else {
                    self.refreshNotificationDeliveryStatus()
                }
            }
        }
    }

    private func refreshNotificationDeliveryStatus() {
        guard notificationPreferences.onboardingCompleted else { return }
        UNUserNotificationCenter.current().getNotificationSettings {
            [weak self] settings in
            let authorizationStatus = settings.authorizationStatus
            let alertsAreDisabled = settings.alertSetting == .disabled
            Task { @MainActor in
                guard let self else { return }
                switch authorizationStatus {
                case .denied:
                    self.showNotificationSettingsWarning()
                case .authorized, .provisional, .ephemeral:
                    if alertsAreDisabled {
                        self.showNotificationSettingsWarning()
                    }
                case .notDetermined:
                    self.requestNotificationAuthorization()
                @unknown default:
                    self.showNotificationSettingsWarning()
                }
            }
        }
    }

    private func showNotificationSettingsWarning() {
        dashboard.setBusy(
            false,
            message: "macOS banners are off for Turnring. Enable Allow Notifications and Banners in System Settings → Notifications → Turnring."
        )
    }

    private func clearLegacyProjectSubtitleNotificationsIfNeeded(
        _ center: UNUserNotificationCenter
    ) {
        let migrationKey = "clearedLegacyRawRoutingNotificationsBuild22"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        center.removeAllDeliveredNotifications()
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private func registerAtLogin() {
        if notificationPreferences.launchAtLogin {
            guard SMAppService.mainApp.status != .enabled else { return }
            do {
                try SMAppService.mainApp.register()
            } catch {
                // The setting remains available if macOS requires approval.
            }
        } else if SMAppService.mainApp.status == .enabled {
            Task {
                try? await SMAppService.mainApp.unregister()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        drainQueue()
        if menuPanel.isShown {
            menuPanel.close()
        } else {
            if notificationPreferences.onboardingCompleted {
                refreshDashboard()
            }
            menuPanel.show(relativeTo: button)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    @objc private func receivedHookEvent(_ notification: Notification) {
        guard !isUninstalling else { return }
        drainQueue()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        livenessTracker.resetDeadObservations()
        livenessTimer?.invalidate()
        livenessTimer = nil
    }

    @objc private func systemDidWake(_ notification: Notification) {
        lastSystemWakeAt = Date()
        livenessTracker.resetDeadObservations()
        drainQueue()
        checkTrackedProcesses()
        updateLivenessTimer()
    }

    @objc private func drainQueue() {
        guard !isUninstalling, !isDrainingQueue else { return }
        isDrainingQueue = true
        defer { isDrainingQueue = false }

        var handledAnyEvent = false
        do {
            while let claim = try EventQueue.claim() {
                for event in claim.events {
                    handledAnyEvent = true
                    var enrichedEvent = event
                    enrichedEvent.displayTitle = conversationTitleResolver.title(
                        provider: event.provider,
                        sessionID: event.sessionID,
                        cwd: event.cwd
                    )
                    enrichGhosttyOrigin(&enrichedEvent)
                    let result = sessionStore.apply(enrichedEvent)
                    if result.didApply {
                        livenessTracker.track(result.summary)
                    }
                    if result.shouldNotify {
                        scheduleAlerts(for: result.summary)
                    }
                }
                try EventQueue.acknowledge(claim)
            }
        } catch {
            dashboard.setBusy(
                false,
                message: "An event remains safely queued and will be retried."
            )
        }
        updateLivenessTimer()
        if handledAnyEvent {
            refreshDashboard()
        }
    }

    @objc private func checkTrackedProcesses() {
        guard !isUninstalling, !livenessTracker.isEmpty else { return }
        for key in Array(livenessTracker.trackedKeys) {
            guard let session = sessionStore.allSessions().first(where: { $0.sessionKey == key })
            else {
                livenessTracker.remove(key)
                continue
            }
            let observation = livenessTracker.observe(
                sessionKey: key,
                isAlive: ProcessInspector.isAlive(session.origin.agentProcess)
            )
            if observation == .confirmedDead {
                let wakeRelated = lastSystemWakeAt.map {
                    Date().timeIntervalSince($0) < 90
                } ?? false
                let preview = wakeRelated
                    ? "Agent process was no longer running after the Mac woke."
                    : "Agent process exited before completing."
                if let failed = sessionStore.markUnexpectedExit(
                    sessionKey: key,
                    preview: preview
                ) {
                    scheduleAlerts(for: failed)
                }
            }
        }
        updateLivenessTimer()
        refreshDashboard()
    }

    private func updateLivenessTimer() {
        if livenessTracker.isEmpty {
            livenessTimer?.invalidate()
            livenessTimer = nil
        } else if livenessTimer == nil {
            livenessTimer = Timer.scheduledTimer(
                timeInterval: 15,
                target: self,
                selector: #selector(checkTrackedProcesses),
                userInfo: nil,
                repeats: true
            )
        }
    }

    private func updateHistoryCleanupTimer() {
        if notificationPreferences.automaticHistoryCleanupEnabled {
            if historyCleanupTimer == nil {
                historyCleanupTimer = Timer.scheduledTimer(
                    timeInterval: 60,
                    target: self,
                    selector: #selector(cleanupExpiredHistory),
                    userInfo: nil,
                    repeats: true
                )
            }
            cleanupExpiredHistory()
        } else {
            historyCleanupTimer?.invalidate()
            historyCleanupTimer = nil
        }
    }

    @objc private func cleanupExpiredHistory() {
        guard !isUninstalling,
              notificationPreferences.automaticHistoryCleanupEnabled
        else {
            return
        }
        let expired = SessionHistoryRetentionPolicy.expiredSessions(
            from: sessionStore.allSessions(),
            retention: notificationPreferences.historyRetentionInterval
        )
        guard !expired.isEmpty else { return }
        var removedAny = false
        for snapshot in expired {
            guard sessionStore.remove(
                sessionKey: snapshot.sessionKey,
                ifUpdatedAt: snapshot.updatedAt
            ) else {
                continue
            }
            removedAny = true
            livenessTracker.remove(snapshot.sessionKey)
            try? ntfyOutbox.discard(id: alertIdentifier(for: snapshot))
            removeNotifications(for: snapshot)
        }
        guard removedAny else { return }
        updateLivenessTimer()
        refreshDashboard()
    }

    private func historyPreferencesChanged() {
        updateHistoryCleanupTimer()
        refreshDashboard()
    }

    private func quitTurnring() {
        if notificationPreferences.confirmBeforeQuit {
            let alert = NSAlert()
            alert.messageText = "Quit Turnring?"
            alert.informativeText =
                "Turnring will stop receiving and forwarding hook notifications until it is opened again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }
        NSApplication.shared.terminate(nil)
    }

    private func menuBarIcon(needsAttention: Bool) -> NSImage? {
        let image = needsAttention
            ? NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: "Turnring needs attention"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            )
            : TurnringBrand.monochromeMark()
        image?.isTemplate = true
        return image
    }

    private func scheduleNotification(
        for session: SessionSummary,
        isTest: Bool = false
    ) {
        screenLockMonitor.refresh()
        let includesPrivateDetails = !isTest
            && notificationPreferences.localAlertDetailsEnabled
            && !screenLockMonitor.isLocked
        let content = UNMutableNotificationContent()
        content.title = isTest || includesPrivateDetails
            ? session.formattedTitle
            : session.genericNotificationTitle
        content.subtitle = ""
        let body = isTest || includesPrivateDetails
            ? session.dashboardPreview(
                includesPrivateDetails: true,
                maximumCharacters:
                    notificationPreferences.localPreviewCharacterLimit
            )
            : session.genericNotificationBody
        guard let body else { return }
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        content.categoryIdentifier = "AGENT_EVENT"
        content.threadIdentifier = routingIdentifier(for: session)
        content.userInfo = [
            "routeID": routingIdentifier(for: session),
            "containsPrivateDetails": includesPrivateDetails,
        ]

        let request = UNNotificationRequest(
            identifier: alertIdentifier(for: session),
            content: content,
            trigger: nil
        )
        addNotificationRequest(request, isTest: isTest)
    }

    private func scheduleAlerts(for session: SessionSummary) {
        guard !isUninstalling else { return }
        let surfaceEnabled = notificationPreferences.shouldDeliverNotification(
            for: session
        )
        let shouldPublishToPhone = surfaceEnabled
            && notificationPreferences.shouldPublishPhoneAlert(for: session)
        guard surfaceEnabled || shouldPublishToPhone else { return }
        let notificationKey = alertIdentifier(for: session)
        guard pendingNotificationKeys.insert(notificationKey).inserted else { return }

        defer { pendingNotificationKeys.remove(notificationKey) }
        if surfaceEnabled {
            scheduleNotification(for: session)
        }
        if shouldPublishToPhone {
            do {
                try enqueuePhoneAlert(for: session)
                drainPhoneOutbox()
            } catch {
                dashboard.setBusy(
                    false,
                    message: "Phone alert could not be queued: \(error.localizedDescription)",
                    autoHideAfter: 5
                )
            }
        }
    }

    private func alertBody(for session: SessionSummary) -> String? {
        session.notificationBody
    }

    private func alertIdentifier(for session: SessionSummary) -> String {
        let timestamp = String(
            format: "%.6f",
            session.updatedAt.timeIntervalSince1970
        )
        let material = [
            session.sessionKey,
            session.state.rawValue,
            timestamp,
            session.contentPreview ?? "",
        ].joined(separator: "\u{1F}")
        return NtfyMessage.opaqueSequenceID(for: material)
    }

    private func routingIdentifier(for session: SessionSummary) -> String {
        NtfyMessage.opaqueSequenceID(for: session.sessionKey)
    }

    private func phoneMessage(
        for session: SessionSummary,
        sequenceID: String
    ) -> NtfyMessage? {
        guard let body = alertBody(for: session) else { return nil }
        let priority: NtfyPriority
        switch session.state {
        case .attention:
            priority = .high
        case .failed:
            priority = .urgent
        case .finished:
            priority = .default
        default:
            return nil
        }
        let includeDetails = notificationPreferences.phoneAlertDetailsEnabled
            || session.isTest
        let phoneTitle = includeDetails
            ? session.formattedTitle
            : "\(session.appDisplayName) • \(session.dashboardStateName)"
        let phoneBody = includeDetails
            ? body
            : genericPhoneBody(for: session)
        return NtfyMessage(
            title: phoneTitle,
            message: phoneBody,
            priority: priority,
            tags: [],
            sequenceID: sequenceID
        )
    }

    private func genericPhoneBody(for session: SessionSummary) -> String {
        switch session.state {
        case .attention:
            session.genericNotificationBody
                ?? "\(session.appDisplayName) needs your attention."
        case .finished:
            {
                let duration = session.formattedElapsedDuration.map {
                    " (\($0))"
                } ?? ""
                return "\(session.appDisplayName) - Finished\(duration)"
            }()
        case .failed:
            session.genericNotificationBody
                ?? "\(session.appDisplayName) stopped unexpectedly."
        default:
            "Turnring received an agent update."
        }
    }

    private func publishPhoneAlert(for session: SessionSummary) async throws {
        let sequenceID = alertIdentifier(for: session)
        guard let message = phoneMessage(
            for: session,
            sequenceID: sequenceID
        ) else {
            return
        }
        let delays: [UInt64] = [0, 1_000_000_000, 3_000_000_000]
        var lastError: Error?
        for delay in delays {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                try await ntfyPublisher.publish(
                    serverURL: NotificationPreferences.ntfyServerURL,
                    topic:
                        try notificationPreferences.prepareSecureNtfyTopic(),
                    message: message,
                    accessToken: try ntfyAccessTokenStore.loadToken()
                )
                return
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
    }

    private func enqueuePhoneAlert(for session: SessionSummary) throws {
        let identifier = alertIdentifier(for: session)
        let topic = try notificationPreferences.prepareSecureNtfyTopic()
        guard NtfyRequestBuilder.isValidTopic(topic) else {
            throw NtfyPublishError.invalidTopic
        }
        guard let message = phoneMessage(
            for: session,
            sequenceID: identifier
        ) else {
            return
        }
        try ntfyOutbox.enqueue(
            NtfyDelivery(
                id: identifier,
                serverURL: NotificationPreferences.ntfyServerURL,
                message: message,
                surfaceKey: NotificationSurface(session: session).rawValue,
                state: session.state,
                includesDetails: notificationPreferences.phoneAlertDetailsEnabled,
                createdAt: Date()
            )
        )
    }

    @objc private func drainPhoneOutbox() {
        guard !isUninstalling,
              notificationPreferences.phoneAlertsEnabled,
              !isDrainingPhoneOutbox
        else {
            return
        }
        let deliveries = ntfyOutbox.dueDeliveries()
        guard !deliveries.isEmpty else { return }
        isDrainingPhoneOutbox = true

        phoneDeliveryTask = Task { [weak self] in
            guard let self else { return }
            var retainedFailure = false
            for delivery in deliveries {
                guard !Task.isCancelled, !isUninstalling else { break }
                guard notificationPreferences.phoneAlertEnabled(
                    for: delivery.state
                ),
                    let surface = NotificationSurface(
                        rawValue: delivery.surfaceKey
                    ),
                    notificationPreferences.notificationsEnabled(
                        for: surface
                    )
                else {
                    try? ntfyOutbox.discard(id: delivery.id)
                    continue
                }

                do {
                    try await ntfyPublisher.publish(
                        serverURL: delivery.serverURL,
                        topic:
                            try notificationPreferences
                                .prepareSecureNtfyTopic(),
                        message: delivery.message,
                        accessToken: try ntfyAccessTokenStore.loadToken()
                    )
                    guard !Task.isCancelled, !isUninstalling else { break }
                    try ntfyOutbox.markSucceeded(id: delivery.id)
                } catch {
                    guard !Task.isCancelled, !isUninstalling else { break }
                    retainedFailure = true
                    try? ntfyOutbox.markFailed(id: delivery.id)
                }
            }
            isDrainingPhoneOutbox = false
            phoneDeliveryTask = nil
            guard !isUninstalling else { return }
            if retainedFailure {
                dashboard.setBusy(
                    false,
                    message: "Phone alert queued; Turnring will retry automatically.",
                    autoHideAfter: 5
                )
            } else if !ntfyOutbox.dueDeliveries().isEmpty {
                drainPhoneOutbox()
            }
        }
    }

    private func reconcilePhoneOutbox() {
        guard !isUninstalling else { return }
        if !notificationPreferences.phoneAlertsEnabled {
            try? ntfyOutbox.clear()
            return
        }
        try? ntfyOutbox.discard { [notificationPreferences] delivery in
            if !notificationPreferences.phoneAlertDetailsEnabled,
               delivery.includesDetails == true
            {
                return true
            }
            guard notificationPreferences.phoneAlertEnabled(
                for: delivery.state
            ),
                let surface = NotificationSurface(
                    rawValue: delivery.surfaceKey
                )
            else {
                return true
            }
            return !notificationPreferences.notificationsEnabled(
                for: surface
            )
        }
        drainPhoneOutbox()
    }

    private func deliveryPreferencesChanged() {
        reconcilePhoneOutbox()
        if !notificationPreferences.localAlertDetailsEnabled {
            removeSensitiveDeliveredNotifications()
        }
        refreshDashboard()
    }

    private func enrichGhosttyOrigin(_ event: inout AgentEvent) {
        guard event.origin.hostBundleIdentifier == "com.mitchellh.ghostty",
              event.origin.ghosttyTerminalID == nil
        else {
            return
        }
        if let captured = sessionStore.session(
            provider: event.provider,
            sessionID: event.sessionID
        )?.origin.ghosttyTerminalID {
            event.origin.ghosttyTerminalID = captured
            return
        }
        event.origin.ghosttyTerminalID = navigationRouter.captureGhosttyTerminalID(
            expectedCWD: event.cwd
        )
    }

    private func refreshStoredConversationTitlesInBackground() {
        let sessions = sessionStore.allSessions()
        let resolver = conversationTitleResolver
        Task { [weak self] in
            let titles = await Task.detached {
                sessions.compactMap { session -> (AgentProvider, String, String)? in
                    guard let title = resolver.title(
                        provider: session.provider,
                        sessionID: session.sessionID,
                        cwd: session.cwd
                    ) else {
                        return nil
                    }
                    return (session.provider, session.sessionID, title)
                }
            }.value
            guard let self, !isUninstalling else { return }
            for (provider, sessionID, title) in titles {
                guard !isUninstalling else { return }
                sessionStore.updateDisplayTitle(
                    provider: provider,
                    sessionID: sessionID,
                    title: title
                )
            }
            refreshDashboard()
        }
    }

    private func sendTestNotification(surface: NotificationSurface? = nil) {
        let displayName = surface?.displayName ?? "Turnring"
        let provider = surface?.provider ?? .codex
        let event = AgentEvent(
            provider: provider,
            state: .attention,
            hookEventName: "TurnringTest",
            sessionID: "turnring-test-\(surface?.rawValue ?? "alert")-\(UUID().uuidString)",
            turnID: nil,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            projectName: "Turnring",
            timestamp: Date(),
            notificationType: surface?.rawValue ?? "alert",
            displayTitle: "Test alert",
            contentPreview: "Turnring is connected.",
            testDisplayName: displayName,
            origin: OriginMetadata(
                hostBundleIdentifier: surface?.hostBundleIdentifier
            )
        )
        let result = sessionStore.apply(event)
        scheduleNotification(for: result.summary, isTest: true)
        refreshDashboard(preserveMessage: true)
    }

    private func sendTestNotificationsForAllSurfaces() {
        NotificationSurface.supportedCases.forEach { surface in
            sendTestNotification(surface: surface)
        }
    }

    private func sendTestPhoneAlert() async throws {
        let event = AgentEvent(
            provider: .codex,
            state: .attention,
            hookEventName: "TurnringPhoneTest",
            sessionID: "turnring-phone-test-\(UUID().uuidString)",
            turnID: nil,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            projectName: "Turnring",
            timestamp: Date(),
            notificationType: "phone",
            displayTitle: "Phone test",
            contentPreview: "Turnring is connected.",
            testDisplayName: "Turnring",
            origin: OriginMetadata()
        )
        let result = sessionStore.apply(event)
        refreshDashboard(preserveMessage: true)
        try await publishPhoneAlert(for: result.summary)
    }

    private func removeNotifications(for session: SessionSummary) {
        let center = UNUserNotificationCenter.current()
        let expectedRouteID = routingIdentifier(for: session)
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.compactMap { notification -> String? in
                let info = notification.request.content.userInfo
                guard info["routeID"] as? String == expectedRouteID else {
                    return nil
                }
                return notification.request.identifier
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
        center.getPendingNotificationRequests { pending in
            let identifiers = pending.compactMap { request -> String? in
                let info = request.content.userInfo
                guard info["routeID"] as? String == expectedRouteID else {
                    return nil
                }
                return request.identifier
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }
    }

    private func removeSensitiveDeliveredNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.compactMap { notification -> String? in
                notification.request.content.userInfo["containsPrivateDetails"]
                    as? Bool == true
                    ? notification.request.identifier
                    : nil
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: identifiers
                )
            }
        }
        center.getPendingNotificationRequests { pending in
            let identifiers = pending.compactMap { request -> String? in
                request.content.userInfo["containsPrivateDetails"] as? Bool
                    == true
                    ? request.identifier
                    : nil
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(
                    withIdentifiers: identifiers
                )
            }
        }
    }

    private func showSettings(
        initialSection: SettingsSection = .general
    ) {
        menuPanel.close()
        settingsWindowController?.close()
        settingsWindowController = SettingsWindowController(
            preferences: notificationPreferences,
            ntfyAccessTokenStore: ntfyAccessTokenStore,
            integrationStatus: integrationStatus,
            initialSection: initialSection
        ) { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        } onDeliveryPreferencesChanged: { [weak self] in
            self?.deliveryPreferencesChanged()
        } onHistoryPreferencesChanged: { [weak self] in
            self?.historyPreferencesChanged()
        } onRepairIntegration: { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            return try await self.repairIntegration()
        } onTestAlert: { [weak self] in
            self?.sendTestNotification()
        } onTestAllApps: { [weak self] in
            self?.sendTestNotificationsForAllSurfaces()
        } onTestSurface: { [weak self] surface in
            self?.sendTestNotification(surface: surface)
        } onTestPhoneAlert: { [weak self] in
            guard let self else { return }
            try await self.sendTestPhoneAlert()
        } onResetSettings: { [weak self] in
            self?.confirmResetSettings()
        } onUninstall: { [weak self] in
            self?.confirmUninstall()
        }
        settingsWindowController?.present()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        notificationPreferences.launchAtLogin = enabled
        Task { [weak self] in
            guard let self else { return }
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status != .notRegistered {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                showError(
                    enabled
                        ? "macOS could not enable launch at login. Check System Settings → General → Login Items."
                        : "macOS could not disable launch at login."
                )
            }
        }
    }

    private func addNotificationRequest(
        _ request: UNNotificationRequest,
        isTest: Bool = false
    ) {
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let errorDescription {
                    self.dashboard.setBusy(
                        false,
                        message: "Notification delivery failed: \(errorDescription)",
                        autoHideAfter: isTest ? 5 : nil
                    )
                } else if isTest {
                    self.dashboard.setBusy(
                        false,
                        message: "Test alert submitted to macOS. If no banner appears, check Focus and System Settings → Notifications → Turnring.",
                        autoHideAfter: 5
                    )
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let routeID = info["routeID"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            guard let self,
                  let routeID,
                  let session = self.sessionStore.allSessions().first(
                    where: {
                        self.routingIdentifier(for: $0) == routeID
                    }
                  )
            else {
                return
            }
            guard !session.isTest else { return }
            let result = self.navigationRouter.open(session)
            if case .unavailable(let message) = result {
                self.showError(message)
            }
        }
    }

    private func repairIntegration() async throws -> IntegrationStatus {
        let installer = configurationInstaller!
        let selected = notificationPreferences.selectedIntegrations
        _ = try await Task.detached {
            try installer.install(providers: selected)
        }.value
        let status = await Task.detached {
            installer.integrationStatus()
        }.value
        integrationStatus = status
        navigationRouter.setVSCodeCompanionAvailable(status.vscode)
        refreshDashboard()
        return status
    }

    private func confirmResetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText =
            "Notification choices, timers, privacy options, the ntfy token, and the private topic will return to defaults. Your phone must subscribe to the newly generated topic. Integration hooks and dashboard history are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        phoneDeliveryTask?.cancel()
        phoneDeliveryTask = nil
        do {
            try ntfyOutbox.clear()
            try ntfyAccessTokenStore.deleteToken()
            try notificationPreferences.resetToDefaults()
            _ = try notificationPreferences.prepareSecureNtfyTopic()
            setLaunchAtLogin(true)
            updateHistoryCleanupTimer()
            reconcilePhoneOutbox()
            removeSensitiveDeliveredNotifications()
            refreshDashboard()

            settingsWindowController?.close()
            settingsWindowController = nil
            showSettings(initialSection: .general)

            let completed = NSAlert()
            completed.messageText = "Settings reset"
            completed.informativeText =
                "Defaults were restored and a new private phone topic was generated. Use Settings → Phone → Connect Phone to subscribe your device again."
            completed.alertStyle = .informational
            completed.addButton(withTitle: "OK")
            completed.runModal()
        } catch {
            showError(
                "Turnring could not reset every setting securely: \(error.localizedDescription)"
            )
        }
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Turnring?"
        alert.informativeText = "This removes Turnring-owned hooks, the VS Code companion, startup registration, and local session history. Existing unrelated settings and backups are preserved."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isUninstalling = true
        phoneDeliveryTask?.cancel()
        phoneDeliveryTask = nil
        settingsWindowController?.close()
        dashboard.setBusy(true, message: "Removing Turnring integration…")
        let installer = configurationInstaller!
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached {
                    try installer.uninstall()
                }.value
                if SMAppService.mainApp.status != .notRegistered {
                    try await SMAppService.mainApp.unregister()
                }
                sessionStore.clear()
                livenessTracker.removeAll()
                updateLivenessTimer()
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                try? ntfyOutbox.clear()
                try? ntfyAccessTokenStore.deleteToken()
                try? notificationPreferences.deleteSecureNtfyTopic()
                try? FileManager.default.removeItem(at: TurnringPaths.applicationSupportDirectory)
                let bundleURL = Bundle.main.bundleURL
                NSWorkspace.shared.recycle([bundleURL]) { _, error in
                    Task { @MainActor in
                        if let error {
                            self.isUninstalling = false
                            self.dashboard.setBusy(
                                false,
                                message: "Integration was removed, but the app could not be moved to Trash."
                            )
                            self.showError(error.localizedDescription)
                            return
                        }
                        if let identifier = Bundle.main.bundleIdentifier {
                            UserDefaults.standard.removePersistentDomain(
                                forName: identifier
                            )
                        }
                        NSApplication.shared.terminate(nil)
                    }
                }
            } catch {
                isUninstalling = false
                dashboard.setBusy(false, message: "Turnring was not uninstalled.")
                showError(error.localizedDescription)
            }
        }
    }

    private func refreshDashboard(preserveMessage: Bool = false) {
        dashboard.update(
            sessions: sessionStore.allSessions(),
            includesPrivateDetails:
                notificationPreferences.localAlertDetailsEnabled,
            maximumPreviewCharacters:
                notificationPreferences.localPreviewCharacterLimit,
            preserveMessage: preserveMessage
        )

        let attentionCount = sessionStore.allSessions().filter { $0.state == .attention }.count
        statusItem.button?.image = menuBarIcon(
            needsAttention: attentionCount > 0
        )
    }

    private func refreshIntegrationHealth(
        preserveMessage: Bool = false
    ) {
        let installer = configurationInstaller!
        let selected = notificationPreferences.selectedIntegrations
        Task { [weak self] in
            var status = await Task.detached {
                installer.integrationStatus()
            }.value
            let needsPathMigration = selected.contains { provider in
                let healthy = provider == .codex
                    ? status.codex
                    : status.claude
                let url = provider == .codex
                    ? TurnringPaths.codexHooksFile
                    : TurnringPaths.claudeSettingsFile
                return !healthy && installer.containsOwnedHook(at: url)
            }
            if needsPathMigration {
                _ = try? await Task.detached {
                    try installer.install(providers: selected)
                }.value
                status = await Task.detached {
                    installer.integrationStatus()
                }.value
            }
            guard let self else { return }
            integrationStatus = status
            navigationRouter.setVSCodeCompanionAvailable(status.vscode)
            refreshDashboard(preserveMessage: preserveMessage)
            let incompleteSelection = selected.contains { provider in
                provider == .codex ? !status.codex : !status.claude
            }
            if incompleteSelection {
                dashboard.setBusy(
                    false,
                    message: "A selected integration needs setup. Open Settings to review it."
                )
            }
        }
    }

    private func prefillExistingIntegrationSelectionIfNeeded() {
        guard !notificationPreferences.onboardingCompleted else { return }
        let installer = configurationInstaller!
        var providers: [AgentProvider] = []
        if installer.containsOwnedHook(at: TurnringPaths.codexHooksFile) {
            providers.append(.codex)
        }
        if installer.containsOwnedHook(at: TurnringPaths.claudeSettingsFile) {
            providers.append(.claude)
        }
        guard !providers.isEmpty else { return }
        notificationPreferences.setSelectedIntegrations(providers)
    }

    private func presentOnboardingIfNeeded() {
        guard !notificationPreferences.onboardingCompleted,
              let button = statusItem.button
        else {
            return
        }
        let controller = OnboardingViewController(
            preferences: notificationPreferences,
            ntfyAccessTokenStore: ntfyAccessTokenStore
        ) { [weak self] providers in
            guard let self else { throw CancellationError() }
            let installer = configurationInstaller!
            _ = try await Task.detached {
                try installer.install(providers: providers)
            }.value
            let status = await Task.detached {
                installer.integrationStatus()
            }.value
            integrationStatus = status
            navigationRouter.setVSCodeCompanionAvailable(status.vscode)
            notificationPreferences.onboardingCompleted = true
            requestNotificationAuthorization()
            completeOnboardingTransition()
        }
        onboardingViewController = controller
        menuPanel.contentViewController = controller
        menuPanel.show(relativeTo: button)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func completeOnboardingTransition() {
        guard let currentView = menuPanel.contentViewController?.view else {
            menuPanel.contentViewController = dashboard
            onboardingViewController = nil
            refreshDashboard()
            return
        }
        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            menuPanel.contentViewController = dashboard
            onboardingViewController = nil
            refreshDashboard()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            currentView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                menuPanel.contentViewController = dashboard
                dashboard.view.alphaValue = 0
                onboardingViewController = nil
                refreshDashboard()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    dashboard.view.animator().alphaValue = 1
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Turnring"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
