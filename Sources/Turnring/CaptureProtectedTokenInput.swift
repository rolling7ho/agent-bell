import TurnringCore
import AppKit

@MainActor
final class CaptureProtectedSecretField: NSView {
    private let maskedField = NSTextField(labelWithString: "")
    private let revealedField = NSTextField(labelWithString: "")
    private let revealButton = LiquidGlassButton(title: "")
    private var revealTask: Task<Void, Never>?
    nonisolated(unsafe) private var localKeyMonitor: Any?
    private var secretValue = ""
    private var maskedValue = ""

    var stringValue: String {
        get { secretValue }
        set {
            secretValue = newValue
            revealedField.stringValue = newValue
            updateRevealAvailability()
        }
    }

    var maskedStringValue: String {
        get { maskedValue }
        set {
            maskedValue = newValue
            maskedField.stringValue = newValue
        }
    }

    var isRevealed: Bool { !revealedField.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        revealTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    func obscure() {
        revealTask?.cancel()
        revealTask = nil
        guard isRevealed else { return }
        revealedField.isHidden = true
        maskedField.isHidden = false
        revealButton.image = eyeImage(named: "eye")
        revealButton.toolTip = "Reveal topic for 60 seconds"
    }

    private func configure() {
        maskedField.usesSingleLineMode = true
        maskedField.maximumNumberOfLines = 1
        maskedField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        maskedField.lineBreakMode = .byTruncatingMiddle

        revealedField.usesSingleLineMode = true
        revealedField.maximumNumberOfLines = 1
        revealedField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        revealedField.lineBreakMode = .byTruncatingMiddle
        revealedField.isSelectable = true
        revealedField.isHidden = true

        revealButton.glassStyle = .secondary
        revealButton.layer?.cornerRadius = 13
        revealButton.image = eyeImage(named: "eye")
        revealButton.imagePosition = .imageOnly
        revealButton.toolTip = "Reveal topic for 60 seconds"
        revealButton.setAccessibilityLabel("Reveal random ntfy topic")
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)

        [maskedField, revealedField, revealButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            maskedField.leadingAnchor.constraint(equalTo: leadingAnchor),
            maskedField.topAnchor.constraint(equalTo: topAnchor),
            maskedField.bottomAnchor.constraint(equalTo: bottomAnchor),
            maskedField.trailingAnchor.constraint(
                equalTo: revealButton.leadingAnchor,
                constant: -7
            ),
            revealedField.leadingAnchor.constraint(equalTo: maskedField.leadingAnchor),
            revealedField.trailingAnchor.constraint(equalTo: maskedField.trailingAnchor),
            revealedField.topAnchor.constraint(equalTo: maskedField.topAnchor),
            revealedField.bottomAnchor.constraint(equalTo: maskedField.bottomAnchor),
            revealButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            revealButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            revealButton.widthAnchor.constraint(equalToConstant: 28),
            revealButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(privacyStateChanged),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(captureApplicationChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(captureApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(captureApplicationChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(privacyStateChanged),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(privacyStateChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            if SecureRevealPolicy.isScreenshotShortcut(
                command: event.modifierFlags.contains(.command),
                shift: event.modifierFlags.contains(.shift),
                keyCode: event.keyCode
            ) {
                self?.obscure()
            }
            return event
        }
        updateRevealAvailability()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            obscure()
        }
    }

    @objc private func toggleReveal() {
        if isRevealed {
            obscure()
            return
        }
        guard !secretValue.isEmpty,
              !knownCaptureApplicationIsRunning()
        else {
            NSSound.beep()
            updateRevealAvailability()
            return
        }
        revealedField.stringValue = secretValue
        maskedField.isHidden = true
        revealedField.isHidden = false
        revealButton.image = eyeImage(named: "eye.slash")
        revealButton.toolTip = "Hide topic"
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            let pollingInterval: UInt64 = 250_000_000
            var elapsed: UInt64 = 0
            while elapsed < SecureRevealPolicy.maximumDurationNanoseconds {
                try? await Task.sleep(nanoseconds: pollingInterval)
                guard !Task.isCancelled, let self else { return }
                elapsed += pollingInterval
                if self.knownCaptureApplicationIsRunning()
                    || !NSApplication.shared.isActive
                    || self.window?.isKeyWindow != true
                {
                    self.obscure()
                    return
                }
            }
            self?.obscure()
        }
    }

    @objc private func privacyStateChanged() {
        obscure()
    }

    @objc private func captureApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication,
            let identifier = application.bundleIdentifier
        else {
            updateRevealAvailability()
            return
        }
        if SecureRevealPolicy.isKnownCaptureBundleIdentifier(identifier) {
            obscure()
        }
        updateRevealAvailability()
    }

    private func updateRevealAvailability() {
        let captureRisk = knownCaptureApplicationIsRunning()
        revealButton.isEnabled = !secretValue.isEmpty && !captureRisk
        revealButton.toolTip = captureRisk
            ? "Close active screen-capture software to reveal the topic"
            : isRevealed ? "Hide topic" : "Reveal topic for 60 seconds"
    }

    private func knownCaptureApplicationIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            SecureRevealPolicy.isKnownCaptureBundleIdentifier(
                $0.bundleIdentifier
            )
        }
    }

    private func eyeImage(named name: String) -> NSImage? {
        NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
    }
}
