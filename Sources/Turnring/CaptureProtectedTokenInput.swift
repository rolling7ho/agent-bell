import TurnringCore
import AppKit

@MainActor
final class CaptureProtectedSecretField: NSView {
    private let maskedField = NSTextField(labelWithString: "")
    private let revealedField = NSTextField(labelWithString: "")
    private let revealButton = LiquidGlassButton(title: "")
    private var previousSharingType: NSWindow.SharingType?
    private var revealTask: Task<Void, Never>?
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
    }

    func obscure() {
        revealTask?.cancel()
        revealTask = nil
        guard isRevealed else { return }
        revealedField.isHidden = true
        maskedField.isHidden = false
        revealButton.image = eyeImage(named: "eye")
        revealButton.toolTip = "Reveal topic for 60 seconds"
        if let previousSharingType {
            window?.sharingType = previousSharingType
        }
        previousSharingType = nil
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
            selector: #selector(captureApplicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(captureApplicationLaunched(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
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
        guard !secretValue.isEmpty else { return }
        revealedField.stringValue = secretValue
        maskedField.isHidden = true
        revealedField.isHidden = false
        revealButton.image = eyeImage(named: "eye.slash")
        revealButton.toolTip = "Hide topic"
        previousSharingType = window?.sharingType
        window?.sharingType = .none
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: SecureRevealPolicy.maximumDurationNanoseconds
            )
            guard !Task.isCancelled else { return }
            self?.obscure()
        }
    }

    @objc private func privacyStateChanged() {
        obscure()
    }

    @objc private func captureApplicationLaunched(_ notification: Notification) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication,
            let identifier = application.bundleIdentifier
        else {
            return
        }
        if identifier == "com.apple.screencaptureui"
            || identifier == "com.apple.QuickTimePlayerX"
            || identifier == "com.obsproject.obs-studio"
        {
            obscure()
        }
    }

    private func updateRevealAvailability() {
        revealButton.isEnabled = !secretValue.isEmpty
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
