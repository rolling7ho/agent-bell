import AgentBellCore
import AppKit

/// Shared visual tokens. Keeping metrics, type, and state colors in one place
/// keeps the popover and the settings window reading as the same app.
@MainActor
enum Theme {
    enum Metrics {
        static let cardRadius: CGFloat = 12
        static let groupRadius: CGFloat = 12
        static let tileRadius: CGFloat = 8
        static let controlHeight: CGFloat = 30
        static let iconButtonSize: CGFloat = 28
        static let sectionInset: CGFloat = 24
        static let rowInset: CGFloat = 12
        static let accentBarWidth: CGFloat = 3
        static let hairline: CGFloat = 1
    }

    @MainActor
    enum Text {
        static let sectionTitle = NSFont.systemFont(ofSize: 22, weight: .semibold)
        static let sectionSubtitle = NSFont.systemFont(ofSize: 11)
        static let groupTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let rowTitle = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let rowDetail = NSFont.systemFont(ofSize: 11)
        static let footnote = NSFont.systemFont(ofSize: 10)
        static let cardTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let cardPreview = NSFont.systemFont(ofSize: 11)
        static let cardMeta = NSFont.systemFont(ofSize: 10)
        static let pill = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let control = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    /// Layer colors have to be re-resolved whenever the effective appearance
    /// changes, so every custom view assigns them inside `updateLayer()`.
    enum Palette {
        static var card: NSColor { .controlBackgroundColor }
        static var separator: NSColor { .separatorColor }
        static var hover: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
        static var pressed: NSColor { NSColor.labelColor.withAlphaComponent(0.11) }
        static var quietControl: NSColor { NSColor.quaternaryLabelColor }
        static var tile: NSColor { NSColor.labelColor.withAlphaComponent(0.05) }
    }

    static func color(for state: AgentState) -> NSColor {
        switch state {
        case .attention: .systemOrange
        case .finished: .systemGreen
        case .failed: .systemRed
        case .working, .started: .systemBlue
        case .ended: .secondaryLabelColor
        }
    }

    static func symbol(for state: AgentState) -> String {
        switch state {
        case .attention: "exclamationmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .working: "arrow.triangle.2.circlepath"
        case .started: "play.circle.fill"
        case .ended: "moon.circle.fill"
        }
    }

    static func symbolImage(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .medium,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        )
    }

    /// Wraps section content so long sections scroll instead of clipping.
    static func makeScrollView(content: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor
            ),
            content.trailingAnchor.constraint(
                equalTo: scrollView.contentView.trailingAnchor
            ),
            content.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor
            ),
            content.widthAnchor.constraint(
                equalTo: scrollView.contentView.widthAnchor
            ),
        ])
        return scrollView
    }

    static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    static func relativeTime(for date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 5 else { return "just now" }
        return relativeTimeFormatter.localizedString(for: date, relativeTo: now)
    }
}

/// A view that tracks the pointer and redraws when the hover state changes.
@MainActor
class HoverView: NSView {
    private(set) var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override var wantsUpdateLayer: Bool { true }

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
        guard !isHovered else { return }
        isHovered = true
        hoverDidChange()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        hoverDidChange()
    }

    func hoverDidChange() {
        needsDisplay = true
    }
}

/// Capsule button used for every non-system action in the app.
@MainActor
final class PillButton: NSButton {
    enum Style {
        case secondary
        case primary
        case destructive
        /// Transparent until hovered. Used for low-frequency actions like Quit.
        case quiet
    }

    private let style: Style
    private let onPress: (() -> Void)?
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var fixedWidth: CGFloat?

    init(
        title: String,
        style: Style = .secondary,
        symbol: String? = nil,
        width: CGFloat? = nil,
        onPress: (() -> Void)? = nil
    ) {
        self.style = style
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        fixedWidth = width
        if let symbol {
            image = Theme.symbolImage(symbol, pointSize: 11, weight: .semibold)
            imagePosition = .imageLeading
            imageScaling = .scaleProportionallyDown
        }
        configure()
        if let width {
            widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if onPress != nil {
            target = self
            action = #selector(pressed)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        if let fixedWidth {
            return NSSize(width: fixedWidth, height: Theme.Metrics.controlHeight)
        }
        return NSSize(
            width: super.intrinsicContentSize.width + 20,
            height: Theme.Metrics.controlHeight
        )
    }

    private func configure() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Theme.Metrics.controlHeight / 2
        layer?.cornerCurve = .continuous
        font = Theme.Text.control
        alignment = .center
        heightAnchor.constraint(
            equalToConstant: Theme.Metrics.controlHeight
        ).isActive = true
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
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    override func updateLayer() {
        super.updateLayer()
        let emphasized = isHovered && isEnabled
        switch style {
        case .secondary:
            layer?.backgroundColor = emphasized
                ? NSColor.tertiaryLabelColor.cgColor
                : Theme.Palette.quietControl.cgColor
            contentTintColor = .labelColor
        case .primary:
            let accent = NSColor.controlAccentColor
            layer?.backgroundColor = emphasized
                ? accent.withAlphaComponent(0.86).cgColor
                : accent.cgColor
            contentTintColor = .white
        case .destructive:
            layer?.backgroundColor = NSColor.systemRed
                .withAlphaComponent(emphasized ? 0.22 : 0.13)
                .cgColor
            contentTintColor = .systemRed
        case .quiet:
            layer?.backgroundColor = emphasized
                ? Theme.Palette.hover.cgColor
                : NSColor.clear.cgColor
            contentTintColor = .secondaryLabelColor
        }
        layer?.opacity = isEnabled ? 1 : 0.45
    }

    @objc private func pressed() {
        onPress?()
    }
}

/// Round, icon-only button for compact header actions.
@MainActor
final class IconButton: NSButton {
    enum Tint {
        case neutral
        case destructive
    }

    private let tint: Tint
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    init(
        symbol: String,
        accessibilityDescription: String,
        tint: Tint = .neutral,
        pointSize: CGFloat = 13,
        size: CGFloat = Theme.Metrics.iconButtonSize
    ) {
        self.tint = tint
        super.init(frame: .zero)
        title = ""
        image = Theme.symbolImage(
            symbol,
            pointSize: pointSize,
            accessibilityDescription: accessibilityDescription
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = accessibilityDescription
        setAccessibilityLabel(accessibilityDescription)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.cornerCurve = .continuous
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
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
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    override func updateLayer() {
        super.updateLayer()
        let emphasized = isHovered && isEnabled
        switch tint {
        case .neutral:
            layer?.backgroundColor = emphasized
                ? Theme.Palette.hover.cgColor
                : Theme.Palette.quietControl.cgColor
            contentTintColor = .labelColor
        case .destructive:
            layer?.backgroundColor = emphasized
                ? NSColor.systemRed.withAlphaComponent(0.18).cgColor
                : Theme.Palette.quietControl.cgColor
            contentTintColor = emphasized ? .systemRed : .labelColor
        }
        layer?.opacity = isEnabled ? 1 : 0.4
    }
}

/// Small tinted capsule that carries an agent state.
@MainActor
final class StatePill: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .secondaryLabelColor

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        label.font = Theme.Text.pill
        iconView.imageScaling = .scaleProportionallyDown

        let row = NSStackView(views: [iconView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 10),
            iconView.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    func configure(state: AgentState) {
        tint = Theme.color(for: state)
        label.stringValue = state.displayName
        label.textColor = tint
        iconView.image = Theme.symbolImage(
            Theme.symbol(for: state),
            pointSize: 9,
            weight: .bold,
            accessibilityDescription: state.displayName
        )
        iconView.contentTintColor = tint
        setAccessibilityLabel(state.displayName)
        needsDisplay = true
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
    }
}

/// One rounded card holding hairline-separated setting rows.
@MainActor
final class SettingsGroup: NSView {
    init(title: String? = nil, rows: [NSView]) {
        super.init(frame: .zero)
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = SeparatorView()
                stack.addView(separator, in: .top)
                separator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    separator.heightAnchor.constraint(
                        equalToConstant: Theme.Metrics.hairline
                    ),
                    separator.leadingAnchor.constraint(
                        equalTo: stack.leadingAnchor,
                        constant: Theme.Metrics.rowInset
                    ),
                    separator.trailingAnchor.constraint(
                        equalTo: stack.trailingAnchor
                    ),
                ])
            }
            stack.addView(row, in: .top)
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let container: NSStackView
        if let title {
            let titleLabel = NSTextField(labelWithString: title.uppercased())
            titleLabel.font = Theme.Text.groupTitle
            titleLabel.textColor = .secondaryLabelColor
            let titleInset = NSStackView(views: [titleLabel])
            titleInset.orientation = .horizontal
            titleInset.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
            container = NSStackView(views: [titleInset, card])
            container.spacing = 6
        } else {
            container = NSStackView(views: [card])
            container.spacing = 0
        }
        container.orientation = .vertical
        container.alignment = .leading
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: container.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class CardView: NSView {
    init(radius: CGFloat = Theme.Metrics.groupRadius) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Theme.Palette.card.cgColor
    }
}

/// Faintly filled rounded tile that holds a provider or app icon.
@MainActor
final class TintedTileView: NSView {
    init(radius: CGFloat = Theme.Metrics.tileRadius) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Theme.Palette.tile.cgColor
    }
}

@MainActor
final class SeparatorView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Theme.Palette.separator.cgColor
    }
}

/// Section title with a one-line explanation of what the section does.
@MainActor
final class SectionHeaderView: NSView {
    init(title: String, subtitle: String?) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.Text.sectionTitle

        var views: [NSView] = [titleLabel]
        var subtitleLabel: NSTextField?
        if let subtitle {
            let label = NSTextField(wrappingLabelWithString: subtitle)
            label.font = Theme.Text.sectionSubtitle
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 2
            views.append(label)
            subtitleLabel = label
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let subtitleLabel {
            subtitleLabel.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// Tinted box for privacy and security notices that must not be missed.
@MainActor
final class InlineNoticeView: NSView {
    enum Style {
        case warning
        case info

        var tint: NSColor {
            switch self {
            case .warning: .systemOrange
            case .info: .secondaryLabelColor
            }
        }

        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    private let style: Style

    init(style: Style, text: String, maximumLines: Int = 5) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        let icon = NSImageView()
        icon.image = Theme.symbolImage(style.symbol, pointSize: 11, weight: .semibold)
        icon.contentTintColor = style.tint
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.Text.footnote
        label.textColor = style == .warning ? .systemOrange : .secondaryLabelColor
        label.maximumNumberOfLines = maximumLines

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = style.tint.withAlphaComponent(0.1).cgColor
    }
}
