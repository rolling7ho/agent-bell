import AppKit

@MainActor
enum TurnringAppearance {
    static let canvas = NSColor(
        srgbRed: 0.075,
        green: 0.078,
        blue: 0.09,
        alpha: 1
    )
    static let sidebar = NSColor(
        srgbRed: 0.095,
        green: 0.098,
        blue: 0.112,
        alpha: 1
    )
    static let menuTint = NSColor(
        srgbRed: 0.08,
        green: 0.085,
        blue: 0.1,
        alpha: 0.72
    )
    static let menuCornerRadius: CGFloat = 34
}

@MainActor
enum TurnringBrand {
    static func monochromeMark() -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: "TurnringMarkMonochrome",
            withExtension: "svg",
            subdirectory: "Brand"
        ),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

@MainActor
enum TurnringGlassStyle {
    case regular
    case clear
}

/// Hosts content using AppKit's native Liquid Glass API on macOS 26 and
/// provides an accessibility-aware material fallback on earlier systems.
@MainActor
final class TurnringGlassHostView: NSView {
    private let hostedContentView: NSView
    private let ignoresHitTesting: Bool
    private var effectView: NSView!
    private var currentCornerRadius: CGFloat
    private var currentTintColor: NSColor?
    private var currentStyle: TurnringGlassStyle

    init(
        contentView: NSView,
        cornerRadius: CGFloat,
        tintColor: NSColor? = nil,
        style: TurnringGlassStyle = .regular,
        ignoresHitTesting: Bool = false
    ) {
        hostedContentView = contentView
        self.ignoresHitTesting = ignoresHitTesting
        currentCornerRadius = cornerRadius
        currentTintColor = tintColor
        currentStyle = style
        super.init(frame: .zero)
        configureEffect()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        ignoresHitTesting ? nil : super.hitTest(point)
    }

    func update(
        cornerRadius: CGFloat,
        tintColor: NSColor?,
        style: TurnringGlassStyle
    ) {
        currentCornerRadius = cornerRadius
        currentTintColor = tintColor
        currentStyle = style
        applyAppearance()
    }

    private func configureEffect() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        if #available(macOS 26.0, *),
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        {
            let glass = NSGlassEffectView()
            glass.contentView = hostedContentView
            effectView = glass
        } else if !NSWorkspace.shared
            .accessibilityDisplayShouldReduceTransparency
        {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = .active
            material.addSubview(hostedContentView)
            pinHostedContent(to: material)
            effectView = material
        } else {
            let solid = NSView()
            solid.addSubview(hostedContentView)
            pinHostedContent(to: solid)
            effectView = solid
        }

        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyAppearance()
    }

    private func pinHostedContent(to container: NSView) {
        hostedContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostedContentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedContentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedContentView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedContentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func applyAppearance() {
        wantsLayer = true
        layer?.cornerRadius = currentCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        if #available(macOS 26.0, *),
           let glass = effectView as? NSGlassEffectView
        {
            glass.cornerRadius = currentCornerRadius
            glass.tintColor = currentTintColor
            glass.style = currentStyle == .regular ? .regular : .clear
            return
        }

        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = currentCornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.layer?.backgroundColor = (
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                ? TurnringAppearance.canvas
                : currentTintColor ?? NSColor.white.withAlphaComponent(0.07)
        ).cgColor
        effectView.layer?.borderWidth = 0.75
        effectView.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.14).cgColor
    }
}

@MainActor
class TurnringGlassGroupingView: NSView {
    let contentView = NSView()
    private var groupingView: NSView!
    private let surfaceColor: NSColor
    private let surfaceCornerRadius: CGFloat
    private let glassSpacing: CGFloat

    init(
        frame frameRect: NSRect,
        surfaceColor: NSColor,
        cornerRadius: CGFloat,
        glassSpacing: CGFloat = 8
    ) {
        self.surfaceColor = surfaceColor
        surfaceCornerRadius = cornerRadius
        self.glassSpacing = glassSpacing
        super.init(frame: frameRect)
        configureGrouping()
    }

    required init?(coder: NSCoder) { nil }

    private func configureGrouping() {
        wantsLayer = true
        layer?.backgroundColor = surfaceColor.cgColor
        layer?.cornerRadius = surfaceCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        if #available(macOS 26.0, *),
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        {
            let container = NSGlassEffectContainerView()
            container.contentView = contentView
            container.spacing = glassSpacing
            groupingView = container
        } else {
            groupingView = contentView
        }
        groupingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(groupingView)
        NSLayoutConstraint.activate([
            groupingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            groupingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            groupingView.topAnchor.constraint(equalTo: topAnchor),
            groupingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
final class TurnringMenuSurfaceView: TurnringGlassGroupingView {
    init(frame frameRect: NSRect) {
        super.init(
            frame: frameRect,
            surfaceColor: TurnringAppearance.canvas,
            cornerRadius: TurnringAppearance.menuCornerRadius,
            glassSpacing: 8
        )
    }

    required init?(coder: NSCoder) { nil }
}
