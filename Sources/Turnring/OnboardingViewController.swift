import TurnringCore
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

@MainActor
final class OnboardingViewController: NSViewController {
    private enum Page: Int, CaseIterable {
        case welcome
        case phone
        case previews
        case apps
    }

    private let preferences: NotificationPreferences
    private let ntfyAccessTokenStore: NtfyAccessTokenStore
    private let onComplete: ([AgentProvider]) async throws -> Void
    private let content = NSView()
    private let backButton = LiquidGlassButton(title: "Back")
    private let continueButton = LiquidGlassButton(
        title: "Continue",
        glassStyle: .primary
    )
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let tokenInput = NSSecureTextField()
    private var page: Page = .welcome
    private var phoneAlertsEnabled = false
    private var sensitivePreviewsEnabled = false
    private var selectedProviders = Set<String>()
    private var completionTask: Task<Void, Never>?

    init(
        preferences: NotificationPreferences,
        ntfyAccessTokenStore: NtfyAccessTokenStore,
        onComplete: @escaping ([AgentProvider]) async throws -> Void
    ) {
        self.preferences = preferences
        self.ntfyAccessTokenStore = ntfyAccessTokenStore
        self.onComplete = onComplete
        phoneAlertsEnabled = preferences.phoneAlertsEnabled
        sensitivePreviewsEnabled = preferences.localAlertDetailsEnabled
        selectedProviders = Set(
            preferences.selectedIntegrations.map(\.rawValue)
        )
        super.init(nibName: nil, bundle: nil)
        tokenInput.stringValue = (try? ntfyAccessTokenStore.loadToken()) ?? ""
        tokenInput.placeholderString = "Optional publish token"
        tokenInput.usesSingleLineMode = true
        tokenInput.maximumNumberOfLines = 1
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        completionTask?.cancel()
    }

    override func loadView() {
        view = TurnringMenuSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 430, height: 480)
        )
        guard let contentRoot = (view as? TurnringMenuSurfaceView)?.contentView
        else {
            return
        }

        backButton.layer?.cornerRadius = 15
        backButton.target = self
        backButton.action = #selector(goBack)
        continueButton.layer?.cornerRadius = 15
        continueButton.target = self
        continueButton.action = #selector(continuePressed)

        errorLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.alignment = .center

        let footer = NSStackView(
            views: [backButton, NSView(), continueButton]
        )
        footer.orientation = .horizontal
        footer.alignment = .centerY

        [content, errorLabel, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentRoot.addSubview($0)
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: contentRoot.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -8),
            errorLabel.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor, constant: -24),
            errorLabel.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 30),
            backButton.widthAnchor.constraint(equalToConstant: 78),
            backButton.heightAnchor.constraint(equalToConstant: 30),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            continueButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        showPage(animated: false)
    }

    private func showPage(animated: Bool) {
        errorLabel.stringValue = ""
        let next = pageView()
        next.translatesAutoresizingMaskIntoConstraints = false
        next.alphaValue = animated ? 0 : 1
        let previous = content.subviews.first
        content.addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            next.topAnchor.constraint(equalTo: content.topAnchor),
            next.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        backButton.isHidden = page == .welcome
        continueButton.title = page == .apps ? "Finish" : "Continue"
        continueButton.isEnabled = page != .apps || !selectedProviders.isEmpty

        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            previous?.removeFromSuperview()
            next.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            previous?.animator().alphaValue = 0
            next.animator().alphaValue = 1
        } completionHandler: {
            Task { @MainActor in
                previous?.removeFromSuperview()
            }
        }
    }

    private func pageView() -> NSView {
        switch page {
        case .welcome:
            welcomeView()
        case .phone:
            phoneView()
        case .previews:
            previewsView()
        case .apps:
            appsView()
        }
    }

    private func welcomeView() -> NSView {
        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "Hello from Turnring")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        let detail = NSTextField(
            wrappingLabelWithString:
                "Get a quiet alert when your coding agents finish or need your attention."
        )
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 54, left: 18, bottom: 0, right: 18)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 92),
            icon.heightAnchor.constraint(equalToConstant: 92),
            detail.widthAnchor.constraint(equalToConstant: 300),
        ])
        return stack
    }

    private func phoneView() -> NSView {
        let title = onboardingTitle("Do you want phone alerts?")
        let detail = onboardingDetail(
            "Optional alerts use a private ntfy topic. Phone alerts stay off unless you enable them."
        )
        let toggle = OnboardingToggleRow(
            title: "Phone alerts",
            detail: "Nothing leaves your Mac while this is off.",
            isOn: phoneAlertsEnabled
        ) { [weak self] enabled in
            guard let self else { return }
            phoneAlertsEnabled = enabled
            showPage(animated: true)
        }

        var views: [NSView] = [title, detail, toggle]
        if phoneAlertsEnabled {
            let topic = preferences.ntfyTopic
            if let url = NtfyDeviceSetupLink.makeURL(
                serverURL: NotificationPreferences.ntfyServerURL,
                topic: topic
            ),
                let qr = makeQRCode(for: url)
            {
                let qrView = NSImageView()
                qrView.image = qr
                qrView.imageScaling = .scaleProportionallyUpOrDown
                qrView.setAccessibilityLabel("Turnring private ntfy topic QR code")

                let scanTitle = NSTextField(labelWithString: "Scan in ntfy")
                scanTitle.font = .systemFont(ofSize: 13, weight: .semibold)
                let scanDetail = onboardingDetail(
                    "Subscribe to the opened topic, allow notifications, then continue."
                )
                let tokenTitle = NSTextField(
                    labelWithString: "Protected topic token (optional)"
                )
                tokenTitle.font = .systemFont(ofSize: 10.5, weight: .medium)
                tokenTitle.textColor = .secondaryLabelColor
                let setupText = NSStackView(
                    views: [scanTitle, scanDetail, tokenTitle, tokenInput]
                )
                setupText.orientation = .vertical
                setupText.alignment = .leading
                setupText.spacing = 6
                let setup = NSStackView(views: [qrView, setupText])
                setup.orientation = .horizontal
                setup.alignment = .centerY
                setup.spacing = 14
                NSLayoutConstraint.activate([
                    qrView.widthAnchor.constraint(equalToConstant: 132),
                    qrView.heightAnchor.constraint(equalToConstant: 132),
                    setupText.widthAnchor.constraint(equalToConstant: 208),
                    tokenInput.widthAnchor.constraint(equalTo: setupText.widthAnchor),
                    tokenInput.heightAnchor.constraint(equalToConstant: 28),
                ])
                views.append(setup)
            } else {
                views.append(
                    WarningCalloutView(
                        text: "The private ntfy setup link is unavailable. Check Keychain access before enabling phone alerts."
                    )
                )
            }
        }

        let stack = onboardingStack(views)
        views.dropFirst(2).forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func previewsView() -> NSView {
        let title = onboardingTitle(
            "Do you want to see previews of the message in notifications?"
        )
        let warning = WarningCalloutView(
            text: "Note: This may reveal sensitive information.",
            maximumNumberOfLines: 2
        )
        warning.label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let toggle = OnboardingToggleRow(
            title: "Sensitive Previews",
            detail: "Show sanitized titles, questions, commands, and filenames.",
            isOn: sensitivePreviewsEnabled
        ) { [weak self] enabled in
            self?.sensitivePreviewsEnabled = enabled
        }
        let detail = onboardingDetail(
            "Turnring hides details while the Mac is locked and removes already delivered detailed alerts when it detects a lock."
        )
        let stack = onboardingStack([title, warning, toggle, detail])
        [warning, toggle, detail].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func appsView() -> NSView {
        let title = onboardingTitle(
            "Choose which apps you want notifications for."
        )
        let detail = onboardingDetail(
            "Turnring supports Codex and Claude Code hooks. Unreliable desktop-only integrations are not offered."
        )
        let codex = OnboardingCheckbox(
            title: "Codex",
            isOn: selectedProviders.contains(AgentProvider.codex.rawValue)
        ) { [weak self] enabled in
            self?.setProvider(.codex, enabled: enabled)
        }
        let claude = OnboardingCheckbox(
            title: "Claude Code",
            isOn: selectedProviders.contains(AgentProvider.claude.rawValue)
        ) { [weak self] enabled in
            self?.setProvider(.claude, enabled: enabled)
        }
        let choices = NSStackView(views: [codex, claude])
        choices.orientation = .horizontal
        choices.alignment = .centerY
        choices.distribution = .fillEqually
        choices.spacing = 10

        var views: [NSView] = [title, detail, choices]
        if selectedProviders.contains(AgentProvider.codex.rawValue) {
            views.append(WarningCalloutView(attributedText: codexInstructions()))
        }
        let stack = onboardingStack(views)
        [detail, choices].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let notice = views.last as? WarningCalloutView {
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func codexInstructions() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.systemYellow,
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.systemYellow,
        ]
        text.append(NSAttributedString(string: "Codex Desktop\n", attributes: heading))
        text.append(
            NSAttributedString(
                string: "In Codex Desktop, go to Settings, click Hooks under Coding, and approve all six hooks.\n\n",
                attributes: body
            )
        )
        text.append(NSAttributedString(string: "Codex CLI\n", attributes: heading))
        text.append(NSAttributedString(string: "Run ", attributes: body))
        text.append(
            NSAttributedString(
                string: "/hooks",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: NSColor.systemYellow,
                ]
            )
        )
        text.append(
            NSAttributedString(
                string: " and approve all hooks.",
                attributes: body
            )
        )
        return text
    }

    private func onboardingTitle(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.maximumNumberOfLines = 3
        return label
    }

    private func onboardingDetail(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 4
        return label
    }

    private func onboardingStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        return stack
    }

    private func setProvider(_ provider: AgentProvider, enabled: Bool) {
        if enabled {
            selectedProviders.insert(provider.rawValue)
        } else {
            selectedProviders.remove(provider.rawValue)
        }
        showPage(animated: true)
    }

    @objc private func goBack() {
        guard let previous = Page(rawValue: page.rawValue - 1) else { return }
        page = previous
        showPage(animated: true)
    }

    @objc private func continuePressed() {
        guard completionTask == nil else { return }
        if let next = Page(rawValue: page.rawValue + 1) {
            page = next
            showPage(animated: true)
            return
        }
        finish()
    }

    private func finish() {
        let providers = AgentProvider.allCases.filter {
            selectedProviders.contains($0.rawValue)
        }
        guard !providers.isEmpty else { return }
        continueButton.isEnabled = false
        backButton.isEnabled = false
        errorLabel.stringValue = "Finishing setup…"
        errorLabel.textColor = .secondaryLabelColor
        completionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = tokenInput.stringValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if token.isEmpty {
                    try ntfyAccessTokenStore.deleteToken()
                } else {
                    try ntfyAccessTokenStore.saveToken(token)
                }
                preferences.phoneAlertsEnabled = phoneAlertsEnabled
                preferences.localAlertDetailsEnabled = sensitivePreviewsEnabled
                preferences.setSelectedIntegrations(providers)
                try await onComplete(providers)
            } catch {
                guard !Task.isCancelled else { return }
                errorLabel.textColor = .systemRed
                errorLabel.stringValue = error.localizedDescription
                continueButton.isEnabled = true
                backButton.isEnabled = true
                completionTask = nil
            }
        }
    }

    private func makeQRCode(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        ) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        image.isTemplate = false
        return image
    }
}

@MainActor
private final class OnboardingToggleRow: NSView {
    init(
        title: String,
        detail: String,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        layer?.borderWidth = 0.75
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let toggle = OnboardingSwitch(isOn: isOn, onChange: onChange)
        let row = NSStackView(views: [labels, NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class OnboardingSwitch: NSSwitch {
    private let onChange: (Bool) -> Void

    init(isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        state = isOn ? .on : .off
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func changed() {
        onChange(state == .on)
    }
}

@MainActor
private final class OnboardingCheckbox: LiquidGlassButton {
    private let onChange: (Bool) -> Void
    private var selected: Bool

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        selected = isOn
        super.init(title: title, glassStyle: .navigation)
        layer?.cornerRadius = 12
        isSelectedGlass = isOn
        image = checkImage(isOn: isOn)
        imagePosition = .imageLeading
        font = .systemFont(ofSize: 12.5, weight: .medium)
        target = self
        action = #selector(changed)
        heightAnchor.constraint(equalToConstant: 42).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func changed() {
        selected.toggle()
        isSelectedGlass = selected
        image = checkImage(isOn: selected)
        onChange(selected)
    }

    private func checkImage(isOn: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: isOn ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: nil
        )
    }
}
