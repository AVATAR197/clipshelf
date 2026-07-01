import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private var monitor: ClipboardMonitor?
    private var hotKeyManager: HotKeyManager?
    private var launcher: LauncherWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store.load()
        monitor = ClipboardMonitor(store: store)
        monitor?.start()

        launcher = LauncherWindowController(store: store)
        hotKeyManager = HotKeyManager(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggleLauncher()
        }
        hotKeyManager?.register()

        buildStatusMenu()
    }

    private func buildStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ClipShelf"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show ClipShelf", action: #selector(showLauncher), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Request Paste Permission", action: #selector(requestAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    @objc private func showLauncher() {
        toggleLauncher()
    }

    private func toggleLauncher() {
        guard let launcher else { return }
        if launcher.isVisible {
            launcher.hide()
        } else {
            launcher.show()
        }
    }

    @objc private func requestAccessibility() {
        PasteController.requestAccessibilityPermission()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
