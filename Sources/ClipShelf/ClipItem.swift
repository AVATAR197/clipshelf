import AppKit

enum ClipKind: String, Codable {
    case text
    case image
}

struct ClipItem: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: ClipKind
    var text: String?
    var imageFilename: String?
    var createdAt: Date
    var category: String
    var favorite: Bool

    var title: String {
        switch kind {
        case .text:
            let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "Empty text" : raw
        case .image:
            return "Image"
        }
    }
}
