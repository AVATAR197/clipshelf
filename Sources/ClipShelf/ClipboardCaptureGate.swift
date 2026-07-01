import Foundation

@MainActor
enum ClipboardCaptureGate {
    static var suppressUntil = Date.distantPast

    static func suppressBriefly() {
        suppressUntil = Date().addingTimeInterval(1.2)
    }

    static var isSuppressed: Bool {
        Date() < suppressUntil
    }
}
