import AppKit

@MainActor
final class MenuBarPanelController: NSWindowController {
    private let panelSize: NSSize
    private weak var anchorWindow: NSWindow?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    override var contentViewController: NSViewController? {
        get { window?.contentViewController }
        set { window?.contentViewController = newValue }
    }

    var isShown: Bool { window?.isVisible == true }

    init(contentSize: NSSize) {
        panelSize = contentSize
        let panel = TurnringMenuPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [
            .transient,
            .moveToActiveSpace,
            .fullScreenAuxiliary,
        ]
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { nil }

    func show(relativeTo button: NSButton) {
        guard let panel = window,
              let anchorWindow = button.window
        else {
            return
        }
        self.anchorWindow = anchorWindow
        panel.setFrame(
            positionedFrame(relativeTo: button, window: anchorWindow),
            display: true
        )
        startEventMonitoring()
        panel.makeKeyAndOrderFront(nil)
    }

    override func close() {
        window?.orderOut(nil)
        stopEventMonitoring()
    }

    private func positionedFrame(
        relativeTo button: NSButton,
        window anchorWindow: NSWindow
    ) -> NSRect {
        let rectInWindow = button.convert(button.bounds, to: nil)
        let anchor = anchorWindow.convertToScreen(rectInWindow)
        let screenFrame = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        let margin: CGFloat = 8
        let proposedX = anchor.midX - panelSize.width / 2
        let x = min(
            max(proposedX, screenFrame.minX + margin),
            screenFrame.maxX - panelSize.width - margin
        )
        let proposedY = anchor.minY - panelSize.height - 7
        let y = max(proposedY, screenFrame.minY + margin)
        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }

    private func startEventMonitoring() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window !== window, event.window !== anchorWindow {
                close()
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }
    }

    private func stopEventMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

@MainActor
private final class TurnringMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
