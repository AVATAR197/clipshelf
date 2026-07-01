import AppKit

struct PasteTarget {
    var app: NSRunningApplication?
    var focusedElement: AXUIElement?
}

enum PasteController {
    @MainActor
    static func captureTarget(app: NSRunningApplication?) -> PasteTarget {
        PasteTarget(app: app, focusedElement: captureFocusedElement())
    }

    @MainActor
    static func paste(_ item: ClipItem, store: ClipboardStore, target: PasteTarget?) {
        let pasteboard = NSPasteboard.general
        ClipboardCaptureGate.suppressBriefly()
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let image = store.image(for: item) {
                pasteboard.writeObjects([image])
            }
        }

        if item.kind == .text,
           let text = item.text,
           let focusedElement = target?.focusedElement,
           insertText(text, into: focusedElement) {
            return
        }

        target?.app?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let didPaste = sendPasteWithSystemEvents(targetBundleID: target?.app?.bundleIdentifier)
            if !didPaste {
                sendCommandV(targetPID: target?.app?.processIdentifier)
            }
        }
    }

    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func sendCommandV(targetPID: pid_t?) {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            NSLog("ClipShelf paste blocked because macOS reports Accessibility access is not trusted for this app build.")
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        if let targetPID {
            keyDown?.postToPid(targetPID)
            keyUp?.postToPid(targetPID)
        }

        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private static func sendPasteWithSystemEvents(targetBundleID: String?) -> Bool {
        let activateLine: String
        if let targetBundleID {
            activateLine = "tell application id \"\(targetBundleID)\" to activate\n"
        } else {
            activateLine = ""
        }

        let source = """
        \(activateLine)delay 0.08
        tell application "System Events"
            key code 9 using {command down}
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("ClipShelf System Events paste failed: \(error)")
            return false
        }
        return true
    }

    private static func captureFocusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = focusedValue else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private static func insertText(_ text: String, into element: AXUIElement) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else {
            return false
        }

        var range = CFRange(location: currentValue.utf16.count, length: 0)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let axRange = rangeRef {
            _ = AXValueGetValue(axRange as! AXValue, .cfRange, &range)
        }

        let nsValue = currentValue as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= nsValue.length else {
            return false
        }

        let nextValue = nsValue.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, nextValue as CFString) == .success else {
            return false
        }

        var nextRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let axNextRange = AXValueCreate(.cfRange, &nextRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axNextRange)
        }
        return true
    }
}
