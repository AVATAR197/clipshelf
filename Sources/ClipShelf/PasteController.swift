import AppKit

struct PasteTarget {
    var app: NSRunningApplication?
    var processIdentifier: pid_t?
    var bundleIdentifier: String?
    var bundleURL: URL?
}

enum PasteController {
    @MainActor
    static func captureTarget(app: NSRunningApplication?) -> PasteTarget {
        PasteTarget(
            app: app,
            processIdentifier: app?.processIdentifier,
            bundleIdentifier: app?.bundleIdentifier,
            bundleURL: app?.bundleURL
        )
    }

    @MainActor
    static func paste(_ item: ClipItem, store: ClipboardStore, target: PasteTarget?) {
        guard write(item, from: store, to: NSPasteboard.general) else {
            NSSound.beep()
            return
        }

        guard AXIsProcessTrusted() else {
            // The clip is on the clipboard so a manual Cmd+V still works;
            // surface the system prompt so auto-paste works next time.
            NSLog("ClipShelf paste blocked: Accessibility access is not granted for this build.")
            requestAccessibilityPermission()
            return
        }

        activate(target)
        Task { @MainActor in
            let targetPID = target?.processIdentifier
            if let targetPID {
                for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            // Give the target a beat to finish fielding focus before the key event lands.
            try? await Task.sleep(nanoseconds: 80_000_000)
            sendCommandV(targetPID: targetPID)
        }
    }

    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    private static func write(_ item: ClipItem, from store: ClipboardStore, to pasteboard: NSPasteboard) -> Bool {
        ClipboardCaptureGate.suppressBriefly()
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            return pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            guard let image = store.image(for: item) else { return false }
            return pasteboard.writeObjects([image])
        }
    }

    @MainActor
    private static func activate(_ target: PasteTarget?) {
        guard let target else { return }

        if let app = target.app, !app.isTerminated {
            app.activate()
            return
        }

        if let bundleURL = target.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("ClipShelf failed to reactivate target app \(target.bundleIdentifier ?? "unknown"): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func sendCommandV(targetPID: pid_t?) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        if targetPID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
            keyDown?.post(tap: .cgSessionEventTap)
            keyUp?.post(tap: .cgSessionEventTap)
        } else if let targetPID {
            // Target never came frontmost; deliver directly so we don't paste into the wrong app.
            keyDown?.postToPid(targetPID)
            keyUp?.postToPid(targetPID)
        }
    }
}
