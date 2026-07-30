import AgentBellCore
import AppKit

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
