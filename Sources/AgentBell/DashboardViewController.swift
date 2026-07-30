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
    private let clearButton = RoundedRectButton(title: "Clear")
    private let settingsButton = RoundedRectButton(
        symbol: "gearshape",
        accessibilityDescription: "Settings"
    )
    private let quitButton = RoundedRectButton(
        title: "Quit",
        emphasis: .destructive
    )
    private let versionLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No agent activity yet")
    private var detailClearTask: Task<Void, Never>?
    private var clearAllTask: Task<Void, Never>?
    private var isBusy = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 480))
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
        emptyLabel.isHidden = !self.sessions.isEmpty

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
        clearButton.isEnabled = !busy
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
        78
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
        return cell
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
            guard let self,
                  let currentRow = sessions.firstIndex(
                    where: { $0.sessionKey == session.sessionKey }
                  )
            else {
                return
            }
            guard let cell = tableView.view(
                atColumn: 0,
                row: currentRow,
                makeIfNecessary: false
            ) as? SessionCellView else {
                onClearSession?(session)
                return
            }
            cell.animateFallingBackward { [weak self] in
                self?.onClearSession?(session)
            }
        }
        action.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Clear"
        )
        action.backgroundColor = NSColor.systemRed
        return [action]
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
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let titleSymbol = NSImageView()
        titleSymbol.image = NSImage(
            systemSymbolName: "bell.fill",
            accessibilityDescription: "AgentBell"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        titleSymbol.contentTintColor = .controlAccentColor

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        clearButton.target = self
        clearButton.action = #selector(clearPressed)

        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)

        quitButton.target = self
        quitButton.action = #selector(quitPressed)

        let headerButtons = NSStackView(
            views: [settingsButton, clearButton]
        )
        headerButtons.orientation = .horizontal
        headerButtons.spacing = 8

        let heading = NSStackView(views: [titleSymbol, title])
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        versionLabel.stringValue = "v\(version) (build \(build))"
        versionLabel.font = .systemFont(ofSize: 9.5)
        versionLabel.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [versionLabel, NSView(), quitButton])
        footer.orientation = .horizontal
        footer.alignment = .bottom

        [header, scrollView, emptyLabel, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            headerTop.widthAnchor.constraint(equalTo: header.widthAnchor),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
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
            clearButton.isEnabled = !isBusy
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

@MainActor
private final class SessionCellView: NSTableCellView {
    private let cardView = NSView()
    private let providerIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cardView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    func configure(
        with session: SessionSummary,
        includesPrivateDetails: Bool,
        maximumPreviewCharacters: Int
    ) {
        providerIcon.image = session.testDisplayName == "AgentBell"
            ? NSApplication.shared.applicationIconImage
            : ProviderIcon.image(for: session.provider)
        let displayedTitle = session.dashboardTitle(
            includesPrivateDetails: includesPrivateDetails
        )
        titleLabel.stringValue = displayedTitle
        titleLabel.toolTip = displayedTitle
        previewLabel.stringValue = session.dashboardPreview(
            includesPrivateDetails: includesPrivateDetails,
            maximumCharacters: maximumPreviewCharacters
        )
        previewLabel.textColor = includesPrivateDetails || session.isTest
            ? .secondaryLabelColor
            : .tertiaryLabelColor
        statusLabel.stringValue = session.state.displayName
        statusLabel.textColor = color(for: session.state)
        timeLabel.stringValue = RelativeDateTimeFormatter().localizedString(
            for: session.updatedAt,
            relativeTo: Date()
        )
    }

    private func build() {
        providerIcon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = .systemFont(ofSize: 10.5)
        previewLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        timeLabel.font = .systemFont(ofSize: 10)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right

        let detail = NSStackView(views: [statusLabel, timeLabel])
        detail.orientation = .horizontal
        detail.spacing = 8

        let labels = NSStackView(views: [titleLabel, previewLabel, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let row = NSStackView(views: [providerIcon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 14
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)
        cardView.addSubview(row)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            row.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            providerIcon.widthAnchor.constraint(equalToConstant: 24),
            providerIcon.heightAnchor.constraint(equalToConstant: 24),
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor),
        ])
    }

    private func color(for state: AgentState) -> NSColor {
        switch state {
        case .attention: .systemOrange
        case .finished: .systemGreen
        case .failed: .systemRed
        case .working, .started: .systemBlue
        case .ended: .secondaryLabelColor
        }
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
private final class RoundedRectButton: NSButton {
    enum Emphasis {
        case secondary
        case primary
        case destructive
    }

    private let emphasis: Emphasis

    init(title: String, emphasis: Emphasis = .secondary) {
        self.emphasis = emphasis
        super.init(frame: .zero)
        self.title = title
        configure()
    }

    init(symbol: String, accessibilityDescription: String) {
        emphasis = .secondary
        super.init(frame: .zero)
        title = ""
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        alignment = .center
        toolTip = accessibilityDescription
        configure()
        widthAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        guard !title.isEmpty else { return NSSize(width: 30, height: 30) }
        return NSSize(
            width: super.intrinsicContentSize.width + 18,
            height: 30
        )
    }

    private func configure() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 12, weight: .medium)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    override func updateLayer() {
        super.updateLayer()
        switch emphasis {
        case .secondary:
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            contentTintColor = .labelColor
        case .primary:
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            contentTintColor = .white
        case .destructive:
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.13).cgColor
            contentTintColor = .systemRed
        }
        layer?.opacity = isEnabled ? 1 : 0.45
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
