import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class DisplayCaptureMonitor {
    private var isRefreshing = false
    private var pendingCompletions: [@MainActor (Bool) -> Void] = []

    func refresh(
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        pendingCompletions.append(completion)
        guard !isRefreshing else { return }
        isRefreshing = true

        let mirrored = NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            else {
                return false
            }
            return CGDisplayIsInMirrorSet(CGDirectDisplayID(number.uint32Value))
                != 0
        }

        guard #available(macOS 14.4, *) else {
            finish(isCaptureActive: mirrored)
            return
        }

        SCShareableContent.getCurrentProcessShareableContent {
            [weak self] content, _ in
            let streamedWindow = content?.windows.contains {
                $0.isActive
            } == true
            Task { @MainActor in
                self?.finish(
                    isCaptureActive: mirrored || streamedWindow
                )
            }
        }
    }

    private func finish(isCaptureActive: Bool) {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        isRefreshing = false
        completions.forEach { $0(isCaptureActive) }
    }
}
