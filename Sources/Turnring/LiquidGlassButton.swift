import AppKit

@MainActor
class LiquidGlassButton: NSButton {
    enum GlassStyle {
        case secondary
        case primary
        case destructive
        case navigation
    }

    var glassStyle: GlassStyle {
        didSet {
            guard oldValue != glassStyle else { return }
            needsDisplay = true
        }
    }

    var isSelectedGlass = false {
        didSet {
            guard oldValue != isSelectedGlass else { return }
            needsDisplay = true
        }
    }

    private let glassContent = MouseTransparentView()
    private let contentLabel = NSTextField(labelWithString: "")
    private let contentImage = NSImageView()
    private let contentStack = MouseTransparentStackView()
    private var glassHost: TurnringGlassHostView!
    private var centerConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var storedTitle = ""

    override var title: String {
        get { storedTitle }
        set {
            storedTitle = newValue
            contentLabel.stringValue = newValue
            contentLabel.isHidden = newValue.isEmpty
            super.title = ""
            invalidateIntrinsicContentSize()
        }
    }

    override var image: NSImage? {
        get { contentImage.image }
        set {
            contentImage.image = newValue
            contentImage.isHidden = newValue == nil
            super.image = nil
            invalidateIntrinsicContentSize()
        }
    }

    init(
        title: String,
        glassStyle: GlassStyle = .secondary
    ) {
        self.glassStyle = glassStyle
        storedTitle = title
        super.init(frame: .zero)
        configureLiquidGlass()
        self.title = title
    }

    required init?(coder: NSCoder) {
        glassStyle = .secondary
        super.init(coder: coder)
        configureLiquidGlass()
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = storedTitle.isEmpty
            ? 0
            : contentLabel.intrinsicContentSize.width
        let imageWidth = contentImage.image == nil ? 0 : CGFloat(16)
        let spacing = textWidth > 0 && imageWidth > 0 ? contentStack.spacing : 0
        return NSSize(
            width: max(30, textWidth + imageWidth + spacing + 20),
            height: 30
        )
    }

    func alignGlassContentLeading(inset: CGFloat = 12) {
        centerConstraint.isActive = false
        leadingConstraint.constant = inset
        leadingConstraint.isActive = true
        trailingConstraint.isActive = true
    }

    private func configureLiquidGlass() {
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 15

        glassContent.wantsLayer = true
        glassContent.layer?.backgroundColor = NSColor.clear.cgColor
        contentLabel.alignment = .center
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.usesSingleLineMode = true
        contentImage.imageScaling = .scaleProportionallyDown
        contentStack.setViews([contentImage, contentLabel], in: .leading)
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        glassContent.addSubview(contentStack)

        centerConstraint = contentStack.centerXAnchor.constraint(
            equalTo: glassContent.centerXAnchor
        )
        leadingConstraint = contentStack.leadingAnchor.constraint(
            equalTo: glassContent.leadingAnchor,
            constant: 9
        )
        trailingConstraint = contentStack.trailingAnchor.constraint(
            lessThanOrEqualTo: glassContent.trailingAnchor,
            constant: -9
        )
        NSLayoutConstraint.activate([
            centerConstraint,
            contentStack.centerYAnchor.constraint(equalTo: glassContent.centerYAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: glassContent.leadingAnchor,
                constant: 9
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: glassContent.trailingAnchor,
                constant: -9
            ),
            contentImage.widthAnchor.constraint(lessThanOrEqualToConstant: 16),
            contentImage.heightAnchor.constraint(lessThanOrEqualToConstant: 16),
        ])

        glassHost = TurnringGlassHostView(
            contentView: glassContent,
            cornerRadius: 15,
            ignoresHitTesting: true
        )
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassHost)
        NSLayoutConstraint.activate([
            glassHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassHost.topAnchor.constraint(equalTo: topAnchor),
            glassHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        contentImage.isHidden = true
        contentLabel.isHidden = storedTitle.isEmpty
    }

    override func layout() {
        super.layout()
        updateGlassAppearance()
    }

    override func updateLayer() {
        super.updateLayer()
        updateGlassAppearance()
    }

    private func updateGlassAppearance() {
        let tint: NSColor?
        let style: TurnringGlassStyle
        switch glassStyle {
        case .secondary:
            tint = nil
            style = .regular
            contentTintColor = .labelColor
            hasDestructiveAction = false
        case .primary:
            tint = NSColor.controlAccentColor.withAlphaComponent(0.58)
            style = .regular
            contentTintColor = .white
            hasDestructiveAction = false
        case .destructive:
            tint = NSColor.systemRed.withAlphaComponent(0.22)
            style = .regular
            contentTintColor = .systemRed
            hasDestructiveAction = true
        case .navigation:
            tint = isSelectedGlass
                ? NSColor.controlAccentColor.withAlphaComponent(0.24)
                : nil
            style = isSelectedGlass ? .regular : .clear
            contentTintColor = .labelColor
            hasDestructiveAction = false
        }

        if #available(macOS 26.0, *) {
            switch glassStyle {
            case .primary:
                tintProminence = .primary
            case .navigation where isSelectedGlass:
                tintProminence = .secondary
            default:
                tintProminence = .none
            }
        }
        glassHost.update(
            cornerRadius: layer?.cornerRadius ?? 15,
            tintColor: tint,
            style: style
        )
        alphaValue = isEnabled ? 1 : 0.45
        contentLabel.font = font ?? .systemFont(ofSize: 12, weight: .medium)
        contentLabel.textColor = contentTintColor
        contentImage.contentTintColor = contentTintColor
    }
}

@MainActor
private final class MouseTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class MouseTransparentStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
