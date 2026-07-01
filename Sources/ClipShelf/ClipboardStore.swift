import AppKit

@MainActor
final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    private(set) var categories: [String] = ["Inbox"]

    private let maxItems = 250
    private let fileManager = FileManager.default
    private lazy var supportDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClipShelf", isDirectory: true)
    }()
    private lazy var imagesDirectory: URL = supportDirectory.appendingPathComponent("Images", isDirectory: true)
    private lazy var storeURL: URL = supportDirectory.appendingPathComponent("clips.json")

    func load() {
        ensureDirectories()
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let snapshot = try JSONDecoder.clipShelf.decode(StoreSnapshot.self, from: data)
            items = snapshot.items
            categories = snapshot.categories.isEmpty ? ["Inbox"] : snapshot.categories
        } catch {
            NSLog("ClipShelf load failed: \(error.localizedDescription)")
        }
    }

    func save() {
        ensureDirectories()
        let snapshot = StoreSnapshot(items: items, categories: categories)
        do {
            let data = try JSONEncoder.clipShelf.encode(snapshot)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            NSLog("ClipShelf save failed: \(error.localizedDescription)")
        }
    }

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if items.first?.kind == .text, items.first?.text == text { return }
        removeDuplicateText(text)
        items.insert(ClipItem(id: UUID(), kind: .text, text: text, imageFilename: nil, createdAt: Date(), category: "Inbox", favorite: false), at: 0)
        trim()
        save()
        NotificationCenter.default.post(name: .clipShelfStoreDidChange, object: self)
    }

    func addImage(_ image: NSImage) {
        guard let data = image.pngData else { return }
        let filename = "\(UUID().uuidString).png"
        ensureDirectories()
        do {
            try data.write(to: imagesDirectory.appendingPathComponent(filename), options: [.atomic])
            items.insert(ClipItem(id: UUID(), kind: .image, text: nil, imageFilename: filename, createdAt: Date(), category: "Inbox", favorite: false), at: 0)
            trim()
            save()
            NotificationCenter.default.post(name: .clipShelfStoreDidChange, object: self)
        } catch {
            NSLog("ClipShelf image write failed: \(error.localizedDescription)")
        }
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let filename = item.imageFilename else { return nil }
        return NSImage(contentsOf: imagesDirectory.appendingPathComponent(filename))
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let filename = item.imageFilename else { return nil }
        return imagesDirectory.appendingPathComponent(filename)
    }

    func addCategory(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !categories.contains(clean) else { return }
        categories.append(clean)
        categories.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if let inboxIndex = categories.firstIndex(of: "Inbox") {
            categories.remove(at: inboxIndex)
            categories.insert("Inbox", at: 0)
        }
        saveAndNotify()
    }

    func setCategory(_ category: String, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        addCategory(category)
        items[index].category = category
        saveAndNotify()
    }

    func toggleFavorite(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].favorite.toggle()
        saveAndNotify()
    }

    func delete(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = items.remove(at: index)
        if let url = imageURL(for: item) {
            try? fileManager.removeItem(at: url)
        }
        saveAndNotify()
    }

    func filteredItems(query: String, category: String?) -> [ClipItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            let categoryMatches = category == nil || item.category == category
            let queryMatches = cleanQuery.isEmpty || item.title.localizedCaseInsensitiveContains(cleanQuery) || item.category.localizedCaseInsensitiveContains(cleanQuery)
            return categoryMatches && queryMatches
        }
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    private func trim() {
        guard items.count > maxItems else { return }
        let removed = items.suffix(from: maxItems)
        items = Array(items.prefix(maxItems))
        for item in removed {
            if let url = imageURL(for: item) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func removeDuplicateText(_ text: String) {
        items.removeAll { $0.kind == .text && $0.text == text }
    }

    private func saveAndNotify() {
        save()
        NotificationCenter.default.post(name: .clipShelfStoreDidChange, object: self)
    }
}

private struct StoreSnapshot: Codable {
    var items: [ClipItem]
    var categories: [String]
}

private extension JSONEncoder {
    static var clipShelf: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var clipShelf: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Notification.Name {
    static let clipShelfStoreDidChange = Notification.Name("clipShelfStoreDidChange")
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
