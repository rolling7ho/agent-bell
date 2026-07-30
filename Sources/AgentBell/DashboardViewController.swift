import AgentBellCore
import AppKit
import QuartzCore

@MainActor
final class DashboardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenSession: ((SessionSummary) -> Void)?
    var onClearSession: ((SessionSummary) -> Void)?
    var onClearHistory: (([SessionSummary]) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var sessions: [SessionSummary] = []
    private var allSessionSnapshots: [SessionSummary] = []
    private var manualSessionOrder: [String] = []
    private var includesPrivateDetails = false
    private var maximumPreviewCharacters = 50
    private let tableView = NSTableView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let attentionBadge = AttentionBadge()
    private let clearButton = IconButton(
        symbol: "trash",
        accessibilityDescription: "Clear all activity",
        tint: .destructive
    )
    private let settingsButton = IconButton(
        symbol: "gearshape",
        accessibilityDescription: "Settings"
    )
    private let quitButton = PillButton(title: "Quit", style: .destructive)
    private let versionLabel = NSTextField(labelWithString: "")
    private let emptyStateView = EmptyStateView()
    private var detailClearTask: Task<Void, Never>?
    private var clearAllTask: Task<Void, Never>?
    private var isBusy = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 500))
        buildInterface()
    }

    func update(
        sessions: [SessionSummary],
        includesPrivateDetails: Bool,
        maximumPreviewCharacters: Int,
        preserveMessage: Bool
    ) {
        allSessionSnapshots = sessions
        let presentedSessions = SessionPresentation.rows(from: sessions)
        let presentedKeys = Set(presentedSessions.map(\.sessionKey))
        manualSessionOrder.removeAll { !presentedKeys.contains($0) }
        let knownKeys = Set(manualSessionOrder)
        let newKeys = presentedSessions
            .map(\.sessionKey)
            .filter { !knownKeys.contains($0) }
        manualSessionOrder.insert(contentsOf: newKeys, at: 0)
        let sessionsByKey = Dictionary(
            uniqueKeysWithValues: presentedSessions.map {
                ($0.sessionKey, $0)
            }
        )
        self.sessions = manualSessionOrder.compactMap { sessionsByKey[$0] }
        self.includesPrivateDetails = includesPrivateDetails
        self.maximumPreviewCharacters = maximumPreviewCharacters
        tableView.reloadData()
        emptyStateView.isHidden = !self.sessions.isEmpty
        clearButton.isEnabled = !isBusy && !self.sessions.isEmpty
        attentionBadge.update(
            count: self.sessions.filter { $0.state == .attention }.count
        )

        if !preserveMessage && !isBusy {
            hideDetailMessage()
        }
    }

    func setBusy(
        _ busy: Bool,
        message: String,
        autoHideAfter delay: TimeInterval? = nil
    ) {
        detailClearTask?.cancel()
        detailClearTask = nil
        isBusy = busy
        clearButton.isEnabled = !busy && !sessions.isEmpty
        settingsButton.isEnabled = !busy
        detailLabel.stringValue = message
        detailLabel.isHidden = message.isEmpty

        guard !busy, !message.isEmpty, let delay else { return }
        detailClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.hideDetailMessage()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sessions.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        80
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard sessions.indices.contains(row) else { return nil }
        let session = sessions[row]
        let cell = SessionCellView()
        cell.configure(
            with: session,
            includesPrivateDetails: includesPrivateDetails,
            maximumPreviewCharacters: maximumPreviewCharacters
        )
        cell.onClear = { [weak self] in
            self?.clearSession(session, animatedIn: cell)
        }
        return cell
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        PlainRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard sessions.indices.contains(row) else { return }
        let session = sessions[row]
        tableView.deselectRow(row)
        onOpenSession?(session)
    }

    func tableView(
        _ tableView: NSTableView,
        rowActionsForRow row: Int,
        edge: NSTableView.RowActionEdge
    ) -> [NSTableViewRowAction] {
        guard sessions.indices.contains(row) else { return [] }
        let session = sessions[row]
        if edge == .leading {
            guard row < sessions.index(before: sessions.endIndex) else {
                return []
            }
            let action = NSTableViewRowAction(
                style: .regular,
                title: "Move Down"
            ) { [weak self] _, _ in
                self?.moveSessionDown(session)
            }
            action.image = NSImage(
                systemSymbolName: "arrow.down",
                accessibilityDescription: "Move Down"
            )
            action.backgroundColor = .systemBlue
            return [action]
        }
        guard edge == .trailing else { return [] }
        let action = NSTableViewRowAction(
            style: .destructive,
            title: "Clear"
        ) { [weak self] _, _ in
            self?.clearSession(session)
        }
        action.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Clear"
        )
        action.backgroundColor = NSColor.systemRed
        return [action]
    }

    private func clearSession(
        _ session: SessionSummary,
        animatedIn providedCell: SessionCellView? = nil
    ) {
        let cell = providedCell ?? currentCell(for: session)
        guard let cell else {
            onClearSession?(session)
            return
        }
        cell.animateFallingBackward { [weak self] in
            self?.onClearSession?(session)
        }
    }

    private func currentCell(for session: SessionSummary) -> SessionCellView? {
        guard let row = sessions.firstIndex(
            where: { $0.sessionKey == session.sessionKey }
        ) else {
            return nil
        }
        return tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: false
        ) as? SessionCellView
    }

    private func moveSessionDown(_ session: SessionSummary) {
        guard let index = sessions.firstIndex(
            where: { $0.sessionKey == session.sessionKey }
        ),
            index + 1 < sessions.count,
            let orderIndex = manualSessionOrder.firstIndex(
                of: session.sessionKey
            )
        else {
            return
        }

        let nextSession = sessions[index + 1]
        guard let nextOrderIndex = manualSessionOrder.firstIndex(
            of: nextSession.sessionKey
        ) else {
            return
        }
        manualSessionOrder.swapAt(orderIndex, nextOrderIndex)
        sessions.swapAt(index, index + 1)
        tableView.reloadData()
    }

    private func buildInterface() {
        let title = NSTextField(labelWithString: "AgentBell")
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        let titleSymbol = NSImageView()
        titleSymbol.image = Theme.symbolImage(
            "bell.fill",
            pointSize: 16,
            weight: .semibold,
            accessibilityDescription: "AgentBell"
        )
        titleSymbol.contentTintColor = .controlAccentColor

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.isHidden = true

        clearButton.target = self
        clearButton.action = #selector(clearPressed)
        clearButton.isEnabled = false

        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)

        quitButton.target = self
        quitButton.action = #selector(quitPressed)

        let headerButtons = NSStackView(
            views: [clearButton, settingsButton]
        )
        headerButtons.orientation = .horizontal
        headerButtons.spacing = 6

        let heading = NSStackView(views: [titleSymbol, title, attentionBadge])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 7

        let headerTop = NSStackView(views: [heading, NSView(), headerButtons])
        headerTop.orientation = .horizontal
        headerTop.alignment = .centerY

        let header = NSStackView(views: [headerTop, detailLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3

        let headerSeparator = SeparatorView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 6,
            left: 0,
            bottom: 6,
            right: 0
        )

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        versionLabel.stringValue = "v\(version) (build \(build))"
        versionLabel.font = .systemFont(ofSize: 9.5)
        versionLabel.textColor = .tertiaryLabelColor

        let footerSeparator = SeparatorView()
        let footer = NSStackView(views: [versionLabel, NSView(), quitButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        [
            header,
            headerSeparator,
            scrollView,
            emptyStateView,
            footerSeparator,
            footer,
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            headerTop.widthAnchor.constraint(equalTo: header.widthAnchor),

            headerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerSeparator.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: 10
            ),
            headerSeparator.heightAnchor.constraint(
                equalToConstant: Theme.Metrics.hairline
            ),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: footerSeparator.topAnchor
            ),

            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateView.widthAnchor.constraint(equalToConstant: 260),

            footerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerSeparator.bottomAnchor.constraint(
                equalTo: footer.topAnchor,
                constant: -8
            ),
            footerSeparator.heightAnchor.constraint(
                equalToConstant: Theme.Metrics.hairline
            ),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 30),
            titleSymbol.widthAnchor.constraint(equalToConstant: 20),
            titleSymbol.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @objc private func clearPressed() {
        guard clearAllTask == nil else { return }
        let snapshots = allSessionSnapshots
        let visibleCells = sessions.indices.compactMap { row in
            tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? SessionCellView
        }
        guard !visibleCells.isEmpty else {
            onClearHistory?(snapshots)
            return
        }

        clearButton.isEnabled = false
        visibleCells.forEach { cell in
            cell.animateFallingBackward {}
        }
        clearAllTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled, let self else { return }
            clearButton.isEnabled = !isBusy && !sessions.isEmpty
            clearAllTask = nil
            onClearHistory?(snapshots)
        }
    }

    @objc private func settingsPressed() {
        onOpenSettings?()
    }

    @objc private func quitPressed() {
        onQuit?()
    }

    private func hideDetailMessage() {
        detailClearTask?.cancel()
        detailClearTask = nil
        detailLabel.stringValue = ""
        detailLabel.isHidden = true
    }
}

/// Header badge that makes the "attention first" ordering visible at a glance.
@MainActor
private final class AttentionBadge: NSView {
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
private final class EmptyStateView: NSView {
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
private final class SessionCardView: NSView {
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
private final class AccentBarView: NSView {
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
private final class PlainRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

@MainActor
private final class SessionCellView: NSTableCellView {
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
private enum ProviderIcon {
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
