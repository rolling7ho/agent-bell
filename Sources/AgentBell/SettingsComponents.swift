import AppKit

// MARK: - Sidebar

@MainActor
final class SettingsNavigationButton: NSButton {
    var isSelected = false {
        didSet {
            applyTint()
            needsDisplay = true
        }
    }

    private let icon = NSImageView()
    private let label: NSTextField
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    init(title: String, symbol: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        self.title = ""
        icon.image = Theme.symbolImage(
            symbol,
            pointSize: 13,
            weight: .medium,
            accessibilityDescription: title
        )
        icon.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let content = MouseTransparentStackView(views: [icon, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
        ])
        applyTint()
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

    private func applyTint() {
        icon.contentTintColor = isSelected
            ? .controlAccentColor
            : .secondaryLabelColor
        label.textColor = isSelected ? .controlAccentColor : .labelColor
    }

    override func updateLayer() {
        super.updateLayer()
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.16)
                .cgColor
        } else {
            layer?.backgroundColor = isHovered
                ? Theme.Palette.hover.cgColor
                : NSColor.clear.cgColor
        }
    }
}

@MainActor
final class MouseTransparentStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Group rows

/// Shared padding and height rules for every row inside a `SettingsGroup`.
@MainActor
enum RowMetrics {
    static let inset = Theme.Metrics.rowInset
    static let compactHeight: CGFloat = 40
    static let regularHeight: CGFloat = 52
}

@MainActor
final class SettingSwitchRow: NSView {
    init(
        title: String,
        detail: String?,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.Text.rowTitle
        let labels: NSStackView
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = Theme.Text.rowDetail
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingTail
            labels = NSStackView(views: [titleLabel, detailLabel])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1
        } else {
            labels = NSStackView(views: [titleLabel])
        }

        let toggle = CallbackSwitch(isOn: isOn, onChange: onChange)
        toggle.setAccessibilityLabel(title)
        let row = NSStackView(views: [labels, NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                equalToConstant: detail == nil
                    ? RowMetrics.compactHeight
                    : RowMetrics.regularHeight
            ),
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RowMetrics.inset
            ),
            row.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RowMetrics.inset
            ),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class NumericPreferenceRow: NSView, NSTextFieldDelegate {
    private let onChange: (Double) -> Void
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let titleLabel: NSTextField
    private let unitLabel: NSTextField
    private let minimum: Double
    private let maximum: Double
    private let allowsDecimals: Bool
    var controlsEnabled = true {
        didSet {
            field.isEnabled = controlsEnabled
            stepper.isEnabled = controlsEnabled
            titleLabel.textColor = controlsEnabled
                ? .labelColor
                : .tertiaryLabelColor
            unitLabel.textColor = controlsEnabled
                ? .secondaryLabelColor
                : .tertiaryLabelColor
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
        titleLabel = NSTextField(labelWithString: title)
        unitLabel = NSTextField(labelWithString: unit)
        super.init(frame: .zero)

        titleLabel.font = Theme.Text.rowTitle

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
        field.setAccessibilityLabel(title)
        field.widthAnchor.constraint(equalToConstant: 66).isActive = true

        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = max(0.01, increment)
        stepper.doubleValue = field.doubleValue
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        unitLabel.font = Theme.Text.rowDetail
        unitLabel.textColor = .secondaryLabelColor

        let row = NSStackView(
            views: [titleLabel, NSView(), field, stepper, unitLabel]
        )
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: RowMetrics.compactHeight),
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RowMetrics.inset
            ),
            row.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RowMetrics.inset
            ),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
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

/// Row whose trailing control is a button, used for tests and destructive work.
@MainActor
final class ActionRow: NSView {
    init(
        title: String,
        detail: String?,
        buttonTitle: String,
        buttonStyle: PillButton.Style = .secondary,
        onPress: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.Text.rowTitle

        let labels: NSStackView
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = Theme.Text.rowDetail
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingTail
            labels = NSStackView(views: [titleLabel, detailLabel])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1
        } else {
            labels = NSStackView(views: [titleLabel])
        }

        let button = PillButton(
            title: buttonTitle,
            style: buttonStyle,
            onPress: onPress
        )
        button.setAccessibilityLabel("\(buttonTitle) \(title)")

        let row = NSStackView(views: [labels, NSView(), button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                equalToConstant: detail == nil
                    ? RowMetrics.compactHeight + 4
                    : RowMetrics.regularHeight
            ),
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RowMetrics.inset
            ),
            row.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RowMetrics.inset
            ),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// Read-only value with an optional trailing accessory, such as Copy.
@MainActor
final class ValueRow: NSView {
    init(
        title: String,
        value: String,
        monospaced: Bool,
        accessory: NSView?
    ) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.Text.rowTitle

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = monospaced
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : Theme.Text.rowDetail
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.usesSingleLineMode = true
        valueLabel.alignment = .right

        var views: [NSView] = [titleLabel, NSView(), valueLabel]
        if let accessory {
            views.append(accessory)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: RowMetrics.compactHeight),
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RowMetrics.inset
            ),
            row.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RowMetrics.inset
            ),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// Two-line row that hosts a text field plus its confirming buttons.
@MainActor
final class FieldRow: NSView {
    init(
        title: String,
        detail: String?,
        field: NSTextField,
        accessories: [NSView]
    ) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.Text.rowTitle
        field.setAccessibilityLabel(title)

        var headerViews: [NSView] = [titleLabel]
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = Theme.Text.rowDetail
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingTail
            headerViews.append(detailLabel)
        }
        let labels = NSStackView(views: headerViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let controls = NSStackView(views: [field] + accessories)
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let stack = NSStackView(views: [labels, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RowMetrics.inset
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RowMetrics.inset
            ),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// Installed / missing indicator for one provider hook.
@MainActor
final class StatusRow: NSView {
    private let indicator = NSImageView()
    private let valueLabel = NSTextField(labelWithString: "")
    private let isOptional: Bool

    init(title: String, isOptional: Bool = false) {
        self.isOptional = isOptional
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.Text.rowTitle
        valueLabel.font = Theme.Text.rowDetail
        indicator.imageScaling = .scaleProportionallyDown

        let row = NSStackView(
            views: [titleLabel, NSView(), valueLabel, indicator]
        )
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: RowMetrics.compactHeight),
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RowMetrics.inset
            ),
            row.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RowMetrics.inset
            ),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 14),
            indicator.heightAnchor.constraint(equalToConstant: 14),
        ])
        update(isInstalled: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(isInstalled: Bool) {
        let tint: NSColor = isInstalled
            ? .systemGreen
            : (isOptional ? .secondaryLabelColor : .systemOrange)
        valueLabel.stringValue = isInstalled
            ? "Installed"
            : (isOptional ? "Not installed" : "Missing")
        valueLabel.textColor = tint
        indicator.image = Theme.symbolImage(
            isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            pointSize: 12,
            weight: .semibold,
            accessibilityDescription: valueLabel.stringValue
        )
        indicator.contentTintColor = tint
    }
}

/// Headline card summarizing overall integration health.
@MainActor
final class IntegrationSummaryView: NSView {
    enum State {
        case installed
        case needsSetup
        case working
        case failed

        var tint: NSColor {
            switch self {
            case .installed: .systemGreen
            case .needsSetup: .systemOrange
            case .working: .secondaryLabelColor
            case .failed: .systemRed
            }
        }

        var symbol: String {
            switch self {
            case .installed: "checkmark.seal.fill"
            case .needsSetup: "exclamationmark.triangle.fill"
            case .working: "arrow.triangle.2.circlepath"
            case .failed: "xmark.octagon.fill"
            }
        }
    }

    private let card = CardView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        detailLabel.font = Theme.Text.rowDetail
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        icon.imageScaling = .scaleProportionallyDown

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        card.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        card.addSubview(row)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.widthAnchor.constraint(
                equalTo: row.widthAnchor,
                constant: -32
            ),
        ])
        update(state: .needsSetup, message: "Checking integration…")
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(state: State, message: String, detail: String? = nil) {
        titleLabel.stringValue = message
        titleLabel.textColor = state.tint
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = (detail ?? "").isEmpty
        icon.image = Theme.symbolImage(
            state.symbol,
            pointSize: 18,
            weight: .semibold,
            accessibilityDescription: message
        )
        icon.contentTintColor = state.tint
    }
}

@MainActor
final class CallbackSwitch: NSSwitch {
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
