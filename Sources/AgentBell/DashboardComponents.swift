import AgentBellCore
import AppKit
import QuartzCore

/// Header badge that makes the "attention first" ordering visible at a glance.
@MainActor
final class AttentionBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        isHidden = true

        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    func update(count: Int) {
        isHidden = count == 0
        guard count > 0 else { return }
        let text = count == 1
            ? "1 needs you"
            : "\(count) need you"
        label.stringValue = text
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(0.14)
            .cgColor
    }
}

@MainActor
final class EmptyStateView: NSView {
    init() {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = Theme.symbolImage(
            "bell.slash",
            pointSize: 26,
            weight: .regular,
            accessibilityDescription: nil
        )
        icon.contentTintColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyDown

        let title = NSTextField(labelWithString: "No agent activity yet")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let hint = NSTextField(
            wrappingLabelWithString:
                "Runs from Codex, Claude Code, and the desktop apps show up here as soon as they need you."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.maximumNumberOfLines = 3

        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// Card background for one dashboard row. Colors are assigned in `updateLayer`
/// so AppKit resolves them against the correct effective appearance.
@MainActor
final class SessionCardView: NSView {
    var state: AgentState = .working {
        didSet { needsDisplay = true }
    }

    var isHovered = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Metrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else { return }
        var background = Theme.Palette.card
        if state == .attention {
            background = background.blended(
                withFraction: 0.06,
                of: .systemOrange
            ) ?? background
        }
        if isHovered {
            background = background.blended(
                withFraction: 0.07,
                of: .labelColor
            ) ?? background
        }
        layer.backgroundColor = background.cgColor
        layer.shadowOpacity = isHovered ? 0.13 : 0
    }
}

/// Thin state-colored bar marking rows that are waiting on the user.
@MainActor
final class AccentBarView: NSView {
    var tint: NSColor = .systemOrange {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Metrics.accentBarWidth / 2
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = tint.cgColor
    }
}

/// Table row view that never paints a selection fill: rows act as buttons and
/// the blue flash read as a stuck selection.
@MainActor
final class PlainRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

@MainActor
final class SessionCellView: NSTableCellView {
    var onClear: (() -> Void)?

    private let cardView = SessionCardView()
    private let accentBar = AccentBarView()
    private let iconTile = TintedTileView()
    private let providerIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let statePill = StatePill()
    private let clearButton = IconButton(
        symbol: "xmark",
        accessibilityDescription: "Clear this item",
        pointSize: 9,
        size: 20
    )
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        clearButton.isHidden = false
        cardView.isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearButton.isHidden = true
        cardView.isHovered = false
    }

    func configure(
        with session: SessionSummary,
        includesPrivateDetails: Bool,
        maximumPreviewCharacters: Int
    ) {
        providerIcon.image = session.testDisplayName == "AgentBell"
            ? NSApplication.shared.applicationIconImage
            : ProviderIcon.image(for: session.provider)
        let headline = session.dashboardHeadline(
            includesPrivateDetails: includesPrivateDetails
        )
        titleLabel.stringValue = headline
        previewLabel.stringValue = session.dashboardPreview(
            includesPrivateDetails: includesPrivateDetails,
            maximumCharacters: maximumPreviewCharacters
        )
        previewLabel.textColor = includesPrivateDetails || session.isTest
            ? .secondaryLabelColor
            : .tertiaryLabelColor
        statePill.configure(state: session.state)

        var metadata = [Theme.relativeTime(for: session.updatedAt)]
        metadata.append(
            contentsOf: session.dashboardMetadata(
                includesPrivateDetails: includesPrivateDetails
            )
        )
        metaLabel.stringValue = metadata.joined(separator: " · ")

        accentBar.isHidden = session.state != .attention
        accentBar.tint = Theme.color(for: session.state)
        cardView.state = session.state
        let accessibleSummary = [
            headline,
            session.state.displayName,
            previewLabel.stringValue,
        ].joined(separator: ", ")
        toolTip = accessibleSummary
        setAccessibilityLabel(accessibleSummary)
    }

    private func build() {
        providerIcon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = Theme.Text.cardTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = Theme.Text.cardPreview
        previewLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = Theme.Text.cardMeta
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, previewLabel, metaLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        accentBar.isHidden = true
        clearButton.isHidden = true
        clearButton.target = self
        clearButton.action = #selector(clearPressed)

        [cardView, accentBar, iconTile, providerIcon, labels, statePill, clearButton]
            .forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        addSubview(cardView)
        cardView.addSubview(accentBar)
        cardView.addSubview(iconTile)
        iconTile.addSubview(providerIcon)
        cardView.addSubview(labels)
        cardView.addSubview(statePill)
        cardView.addSubview(clearButton)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            accentBar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            accentBar.bottomAnchor.constraint(
                equalTo: cardView.bottomAnchor,
                constant: -12
            ),
            accentBar.widthAnchor.constraint(
                equalToConstant: Theme.Metrics.accentBarWidth
            ),

            iconTile.leadingAnchor.constraint(
                equalTo: cardView.leadingAnchor,
                constant: 12
            ),
            iconTile.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 30),
            iconTile.heightAnchor.constraint(equalToConstant: 30),
            providerIcon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            providerIcon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            providerIcon.widthAnchor.constraint(equalToConstant: 19),
            providerIcon.heightAnchor.constraint(equalToConstant: 19),

            labels.leadingAnchor.constraint(
                equalTo: iconTile.trailingAnchor,
                constant: 10
            ),
            labels.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            labels.trailingAnchor.constraint(
                lessThanOrEqualTo: statePill.leadingAnchor,
                constant: -8
            ),

            statePill.trailingAnchor.constraint(
                equalTo: cardView.trailingAnchor,
                constant: -12
            ),
            statePill.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),

            clearButton.trailingAnchor.constraint(
                equalTo: cardView.trailingAnchor,
                constant: -12
            ),
            clearButton.bottomAnchor.constraint(
                equalTo: cardView.bottomAnchor,
                constant: -11
            ),
        ])
    }

    @objc private func clearPressed() {
        onClear?()
    }

    func animateFallingBackward(completion: @escaping () -> Void) {
        guard let layer = cardView.layer else {
            completion()
            return
        }

        var finalTransform = CATransform3DIdentity
        finalTransform.m34 = -1 / 450
        finalTransform = CATransform3DTranslate(finalTransform, 0, 10, -45)
        finalTransform = CATransform3DRotate(
            finalTransform,
            CGFloat.pi * 0.42,
            1,
            0,
            0
        )
        finalTransform = CATransform3DScale(finalTransform, 0.96, 0.96, 1)

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
        transform.toValue = NSValue(caTransform3D: finalTransform)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [transform, fade]
        group.duration = 0.38
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(group, forKey: "agentbell-fall-back")
        CATransaction.commit()
    }
}

@MainActor
enum ProviderIcon {
    private static var cache: [AgentProvider: NSImage] = [:]

    static func image(for provider: AgentProvider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let resourceName = provider == .codex ? "Codex" : "Claude"
        if let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ),
            let image = NSImage(contentsOf: url)
        {
            image.size = NSSize(width: 24, height: 24)
            image.accessibilityDescription = provider.displayName
            cache[provider] = image
            return image
        }

        let fallback = NSImage(
            systemSymbolName: provider == .codex
                ? "chevron.left.forwardslash.chevron.right"
                : "sparkles",
            accessibilityDescription: provider.displayName
        )
        cache[provider] = fallback
        return fallback
    }
}
