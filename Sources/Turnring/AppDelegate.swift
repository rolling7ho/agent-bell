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
    private lazy var nativeNotificationOutbox = NativeNotificationOutbox()
    private let displayCaptureMonitor = DisplayCaptureMonitor()
    private lazy var screenLockMonitor: ScreenLockMonitor = {
        let monitor = ScreenLockMonitor()
        monitor.onLock = { [weak self] in
            self?.removeSensitiveDeliveredNotifications()
            self?.drainNativeNotificationOutbox()
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
    private var nativeDeliveryTimer: Timer?
    private var nativeCaptureRetryTask: Task<Void, Never>?
    private var captureFallbackSoundedDeliveryIDs: Set<String> = []
    private var livenessTracker = SessionLivenessTracker()
    private var isDrainingQueue = false
    private var isDrainingNativeNotificationOutbox = false
    private var isDrainingPhoneOutbox = false
    private var phoneDeliveryTask: Task<Void, Never>?
    private var isUninstalling = false
    private var lastSystemWakeAt: Date?
    private var integrationStatus = IntegrationStatus(
        codex: false,
        claude: false,
        vscode: false
    )
    private var usesTimeSensitiveNotifications: Bool {
        Bundle.main.object(
            forInfoDictionaryKey: "TurnringUsesTimeSensitiveNotifications"
        ) as? Bool == true
    }

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
        nativeDeliveryTimer = Timer.scheduledTimer(
            timeInterval: 15,
            target: self,
            selector: #selector(drainNativeNotificationOutbox),
            userInfo: nil,
            repeats: true
        )

        livenessTracker = SessionLivenessTracker(
            sessions: sessionStore.allSessions()
        )
        updateLivenessTimer()
        updateHistoryCleanupTimer()
        reconcilePhoneOutbox()
        reconcileNativeNotificationOutbox()
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
        nativeDeliveryTimer?.invalidate()
        nativeCaptureRetryTask?.cancel()
        phoneDeliveryTask?.cancel()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        drainQueue()
        drainNativeNotificationOutbox()
        drainPhoneOutbox()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshNotificationDeliveryStatus()
        drainNativeNotificationOutbox()
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
                try? nativeNotificationOutbox.discard {
                    $0.routeID == routingIdentifier(for: snapshot)
                }
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
                try? nativeNotificationOutbox.discard {
                    $0.routeID == routingIdentifier(for: snapshot)
                }
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
                    self.drainNativeNotificationOutbox()
                }
            }
        }
    }

    private func refreshNotificationDeliveryStatus() {
        guard notificationPreferences.onboardingCompleted else { return }
        UNUserNotificationCenter.current().getNotificationSettings {
            [weak self] settings in
            let authorizationStatus = settings.authorizationStatus
            let alertSetting = settings.alertSetting
            let alertStyle = settings.alertStyle
            let soundSetting = settings.soundSetting
            let timeSensitiveSetting = settings.timeSensitiveSetting
            Task { @MainActor in
                guard let self else { return }
                switch authorizationStatus {
                case .denied:
                    self.showNotificationSettingsWarning(
                        "Notifications are denied. Turnring is keeping alerts queued until you enable them in System Settings."
                    )
                case .provisional, .ephemeral:
                    self.showNotificationSettingsWarning(
                        "Notifications are set to quiet delivery. Allow Turnring notifications so completion alerts can show banners and play sounds."
                    )
                case .authorized:
                    if alertSetting != .enabled || alertStyle == .none {
                        self.showNotificationSettingsWarning(
                            "Notification style is None. Turnring is keeping alerts queued until Banners or Alerts are enabled."
                        )
                    } else if soundSetting != .enabled {
                        self.showNotificationSettingsWarning(
                            "Notification sounds are off. Banners can arrive, but Turnring cannot audibly ping you."
                        )
                    } else if self.usesTimeSensitiveNotifications,
                              timeSensitiveSetting != .enabled
                    {
                        self.showNotificationSettingsWarning(
                            "Time Sensitive notifications are off. Focus or Scheduled Summary may delay Turnring alerts."
                        )
                    }
                case .notDetermined:
                    self.requestNotificationAuthorization()
                @unknown default:
                    self.showNotificationSettingsWarning()
                }
            }
        }
    }

    private func showNotificationSettingsWarning(
        _ message: String = "macOS banners are off for Turnring. Enable Allow Notifications and Banners in System Settings → Notifications → Turnring."
    ) {
        dashboard.setBusy(
            false,
            message: message
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
                    if result.shouldEnsureDelivery {
                        try enqueueAlerts(for: result.summary)
                    }
                }
                try EventQueue.acknowledge(claim)
            }
            drainNativeNotificationOutbox()
            drainPhoneOutbox()
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
                let event = AgentEvent(
                    provider: session.provider,
                    state: .failed,
                    hookEventName: "UnexpectedExit",
                    sessionID: session.sessionID,
                    turnID: session.turnID,
                    cwd: session.cwd,
                    projectName: session.projectName,
                    timestamp: Date(),
                    notificationType: "unexpected_exit",
                    displayTitle: session.displayTitle,
                    contentPreview: preview,
                    origin: session.origin
                )
                do {
                    try EventQueue.append(event)
                    drainQueue()
                } catch {
                    livenessTracker.track(session)
                    dashboard.setBusy(
                        false,
                        message: "Turnring could not safely queue an unexpected agent exit. It will retry."
                    )
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
            // Session timestamps can predate actual notification delivery.
            // Automatic history cleanup must not erase a newly delivered
            // Notification Center item. Explicit user clears still remove it.
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

    private func nativeNotificationDelivery(
        for session: SessionSummary,
        isTest: Bool = false
    ) -> NativeNotificationDelivery? {
        screenLockMonitor.refresh()
        guard let genericBody = session.genericNotificationBody else {
            return nil
        }
        let includesPrivateDetails = !isTest
            && notificationPreferences.localAlertDetailsEnabled
        let preferredTitle = isTest || includesPrivateDetails
            ? session.formattedTitle
            : session.genericNotificationTitle
        let preferredBody = isTest || includesPrivateDetails
            ? session.dashboardPreview(
                includesPrivateDetails: true,
                maximumCharacters:
                    notificationPreferences.localPreviewCharacterLimit
            )
            : genericBody
        return NativeNotificationDelivery(
            id: alertIdentifier(for: session),
            title: preferredTitle,
            body: preferredBody,
            genericTitle: isTest
                ? session.formattedTitle
                : session.genericNotificationTitle,
            genericBody: isTest
                ? preferredBody
                : genericBody,
            threadIdentifier: routingIdentifier(for: session),
            routeID: routingIdentifier(for: session),
            containsPrivateDetails: includesPrivateDetails,
            isTest: isTest,
            surfaceKey: NotificationSurface(session: session).rawValue,
            createdAt: Date()
        )
    }

    private func enqueueAlerts(for session: SessionSummary) throws {
        guard !isUninstalling else { return }
        let surfaceEnabled = notificationPreferences.shouldDeliverNotification(
            for: session
        )
        let shouldPublishToPhone = surfaceEnabled
            && notificationPreferences.shouldPublishPhoneAlert(for: session)
        guard surfaceEnabled || shouldPublishToPhone else { return }
        if surfaceEnabled,
           let delivery = nativeNotificationDelivery(for: session)
        {
            try nativeNotificationOutbox.enqueue(delivery)
        }
        if shouldPublishToPhone {
            try enqueuePhoneAlert(for: session)
        }
    }

    @objc private func drainNativeNotificationOutbox() {
        guard !isUninstalling,
              !isDrainingNativeNotificationOutbox
        else {
            return
        }
        guard nativeNotificationOutbox.isOperational else {
            dashboard.setBusy(
                false,
                message: "Turnring's saved notification queue needs repair. New agent events remain queued and are not being discarded."
            )
            return
        }
        let deliveries = nativeNotificationOutbox.dueDeliveries()
        guard !deliveries.isEmpty else { return }
        isDrainingNativeNotificationOutbox = true
        displayCaptureMonitor.refresh { [weak self] isCaptureActive in
            guard let self else { return }
            guard !isCaptureActive else {
                self.deferNativeNotificationsForDisplayCapture(deliveries)
                return
            }
            self.loadNativeNotificationSettings(for: deliveries)
        }
    }

    private func loadNativeNotificationSettings(
        for deliveries: [NativeNotificationDelivery]
    ) {
        UNUserNotificationCenter.current().getNotificationSettings {
            [weak self] settings in
            let authorizationStatus = settings.authorizationStatus
            let alertSetting = settings.alertSetting
            let alertStyle = settings.alertStyle
            Task { @MainActor in
                guard let self else { return }
                guard authorizationStatus == .authorized,
                      alertSetting == .enabled,
                      alertStyle != .none
                else {
                    self.isDrainingNativeNotificationOutbox = false
                    self.refreshNotificationDeliveryStatus()
                    return
                }
                self.submitNativeNotifications(
                    deliveries,
                    at: 0,
                    hadPersistenceFailure: false
                )
            }
        }
    }

    private func deferNativeNotificationsForDisplayCapture(
        _ deliveries: [NativeNotificationDelivery]
    ) {
        isDrainingNativeNotificationOutbox = false
        let shouldSoundFallback = deliveries.contains { delivery in
            captureFallbackSoundedDeliveryIDs.insert(delivery.id).inserted
        }
        if shouldSoundFallback {
            NSSound.beep()
        }
        dashboard.setBusy(
            false,
            message: "macOS hides banners while the display is shared. Turnring kept the alert queued and will show it when sharing ends."
        )
        scheduleNativeCaptureRetry()
    }

    private func scheduleNativeCaptureRetry() {
        guard nativeCaptureRetryTask == nil else { return }
        nativeCaptureRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.nativeCaptureRetryTask = nil
            self.drainNativeNotificationOutbox()
        }
    }

    private func submitNativeNotifications(
        _ deliveries: [NativeNotificationDelivery],
        at index: Int,
        hadPersistenceFailure: Bool
    ) {
        guard !isUninstalling else {
            isDrainingNativeNotificationOutbox = false
            return
        }
        guard index < deliveries.count else {
            isDrainingNativeNotificationOutbox = false
            if !hadPersistenceFailure,
               !nativeNotificationOutbox.dueDeliveries().isEmpty
            {
                drainNativeNotificationOutbox()
            }
            return
        }
        let delivery = deliveries[index]
        screenLockMonitor.refresh()
        let includesPrivateDetails = delivery.containsPrivateDetails
            && notificationPreferences.localAlertDetailsEnabled
            && !screenLockMonitor.isLocked
        let content = UNMutableNotificationContent()
        content.title = includesPrivateDetails
            ? delivery.title
            : delivery.genericTitle
        content.body = includesPrivateDetails
            ? delivery.body
            : delivery.genericBody
        content.sound = .default
        content.interruptionLevel = usesTimeSensitiveNotifications
            ? .timeSensitive
            : .active
        content.categoryIdentifier = "AGENT_EVENT"
        content.threadIdentifier = delivery.threadIdentifier
        content.userInfo = [
            "routeID": delivery.routeID,
            "containsPrivateDetails": includesPrivateDetails,
        ]
        let request = UNNotificationRequest(
            identifier: delivery.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                var nextHadPersistenceFailure = hadPersistenceFailure
                do {
                    if let error {
                        try self.nativeNotificationOutbox.markFailed(
                            id: delivery.id
                        )
                        self.dashboard.setBusy(
                            false,
                            message: "macOS rejected a notification. Turnring kept it queued and will retry: \(error.localizedDescription)"
                        )
                    } else {
                        self.confirmNativeNotificationDelivery(
                            delivery,
                            deliveries: deliveries,
                            nextIndex: index + 1,
                            hadPersistenceFailure: hadPersistenceFailure
                        )
                        return
                    }
                } catch {
                    nextHadPersistenceFailure = true
                    self.dashboard.setBusy(
                        false,
                        message: "Turnring could not update its saved notification queue. It retained the alert for recovery."
                    )
                }
                self.submitNativeNotifications(
                    deliveries,
                    at: index + 1,
                    hadPersistenceFailure: nextHadPersistenceFailure
                )
            }
        }
    }

    private func confirmNativeNotificationDelivery(
        _ delivery: NativeNotificationDelivery,
        remainingChecks: Int = 5,
        deliveries: [NativeNotificationDelivery],
        nextIndex: Int,
        hadPersistenceFailure: Bool
    ) {
        UNUserNotificationCenter.current().getDeliveredNotifications {
            [weak self] delivered in
            let isPresent = delivered.contains {
                $0.request.identifier == delivery.id
            }
            Task { @MainActor in
                guard let self else { return }
                if !isPresent, remainingChecks > 1 {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled, let self else { return }
                        self.confirmNativeNotificationDelivery(
                            delivery,
                            remainingChecks: remainingChecks - 1,
                            deliveries: deliveries,
                            nextIndex: nextIndex,
                            hadPersistenceFailure: hadPersistenceFailure
                        )
                    }
                    return
                }
                self.displayCaptureMonitor.refresh {
                    [weak self] isCaptureActive in
                    self?.finishNativeNotificationConfirmation(
                        delivery,
                        isPresent: isPresent,
                        isCaptureActive: isCaptureActive,
                        deliveries: deliveries,
                        nextIndex: nextIndex,
                        hadPersistenceFailure: hadPersistenceFailure
                    )
                }
            }
        }
    }

    private func finishNativeNotificationConfirmation(
        _ delivery: NativeNotificationDelivery,
        isPresent: Bool,
        isCaptureActive: Bool,
        deliveries: [NativeNotificationDelivery],
        nextIndex: Int,
        hadPersistenceFailure: Bool
    ) {
        var nextHadPersistenceFailure = hadPersistenceFailure
        do {
            switch NativeNotificationDeliveryPolicy.disposition(
                isPresentInNotificationCenter: isPresent,
                isDisplayCaptureActive: isCaptureActive
            ) {
            case .acknowledge:
                try nativeNotificationOutbox.markSucceeded(id: delivery.id)
                captureFallbackSoundedDeliveryIDs.remove(delivery.id)
                if delivery.isTest {
                    dashboard.setBusy(
                        false,
                        message: "Test alert delivered to Notification Center.",
                        autoHideAfter: 5
                    )
                }
            case .retry:
                try nativeNotificationOutbox.markFailed(id: delivery.id)
                if isCaptureActive {
                    deferNativeNotificationsForDisplayCapture([delivery])
                    return
                } else {
                    dashboard.setBusy(
                        false,
                        message: "macOS accepted an alert but did not retain it in Notification Center. Turnring kept it queued and will retry."
                    )
                }
            }
        } catch {
            nextHadPersistenceFailure = true
            dashboard.setBusy(
                false,
                message: "Turnring could not update its saved notification queue. It retained the alert for recovery."
            )
        }
        submitNativeNotifications(
            deliveries,
            at: nextIndex,
            hadPersistenceFailure: nextHadPersistenceFailure
        )
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
        let genericMessage = NtfyMessage(
            title: "\(session.appDisplayName) • \(session.dashboardStateName)",
            message: genericPhoneBody(for: session),
            priority: message.priority,
            tags: [],
            sequenceID: identifier
        )
        try ntfyOutbox.enqueue(
            NtfyDelivery(
                id: identifier,
                serverURL: NotificationPreferences.ntfyServerURL,
                message: message,
                genericMessage: genericMessage,
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
        guard ntfyOutbox.isOperational else {
            dashboard.setBusy(
                false,
                message: "Turnring's saved phone-alert queue needs repair. New agent events remain queued and are not being discarded."
            )
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
                        message: notificationPreferences
                            .phoneAlertDetailsEnabled
                            ? delivery.message
                            : (delivery.genericMessage ?? delivery.message),
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

    private func reconcileNativeNotificationOutbox() {
        guard !isUninstalling else { return }
        do {
            try nativeNotificationOutbox.discard {
                [notificationPreferences] delivery in
                guard let surface = NotificationSurface(
                    rawValue: delivery.surfaceKey
                ) else {
                    return true
                }
                return !delivery.isTest
                    && !notificationPreferences.notificationsEnabled(
                        for: surface
                    )
            }
        } catch {
            dashboard.setBusy(
                false,
                message: "Turnring could not reconcile its saved notification queue. Alerts were retained."
            )
        }
        drainNativeNotificationOutbox()
    }

    private func deliveryPreferencesChanged() {
        reconcileNativeNotificationOutbox()
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
        do {
            if let delivery = nativeNotificationDelivery(
                for: result.summary,
                isTest: true
            ) {
                try nativeNotificationOutbox.enqueue(delivery)
                drainNativeNotificationOutbox()
            }
        } catch {
            dashboard.setBusy(
                false,
                message: "Test alert could not be saved for delivery: \(error.localizedDescription)"
            )
        }
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
            try nativeNotificationOutbox.clear()
            try ntfyAccessTokenStore.deleteToken()
            try notificationPreferences.resetToDefaults()
            _ = try notificationPreferences.prepareSecureNtfyTopic()
            setLaunchAtLogin(true)
            updateHistoryCleanupTimer()
            reconcileNativeNotificationOutbox()
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
                try? nativeNotificationOutbox.clear()
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
