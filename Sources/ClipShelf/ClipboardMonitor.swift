import AppKit

@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.inspectPasteboard()
            }
        }
    }

    func suppressNextCapture() {
        ClipboardCaptureGate.suppressBriefly()
        lastChangeCount = pasteboard.changeCount
    }

    private func inspectPasteboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !ClipboardCaptureGate.isSuppressed else { return }

        if let image = readImage() {
            store.addImage(image)
            return
        }

        if let text = pasteboard.string(forType: .string) {
            store.addText(text)
        }
    }

    private func readImage() -> NSImage? {
        if let data = pasteboard.data(forType: .png), let image = NSImage(data: data) {
            return image
        }
        if let data = pasteboard.data(forType: .tiff), let image = NSImage(data: data) {
            return image
        }
        return nil
    }
}
