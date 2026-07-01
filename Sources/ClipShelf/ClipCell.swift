import AppKit

@MainActor
final class ClipCell: NSCollectionViewItem, NSDraggingSource {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCell")

    private let card = NSView()
    private let header = NSView()
    private let typeLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let previewContainer = NSView()
    private let clipImageView = NSImageView()
    private let textTitle = NSTextField(labelWithString: "")
    private let textPreview = NSTextField(wrappingLabelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let controlRow = NSStackView()
    private var categories: [String] = []
    private var item: ClipItem?
    private var mouseDownPoint: NSPoint?
    private var hasStartedDrag = false
    private var pendingPasteWorkItem: DispatchWorkItem?

    var onPaste: ((ClipItem) -> Void)?
    var onDelete: ((ClipItem) -> Void)?
    var onCategory: ((ClipItem, String) -> Void)?

    override func loadView() {
        let clipView = ClipItemView()
        clipView.owner = self
        view = clipView
        setup()
    }

    func configure(with item: ClipItem, store: ClipboardStore) {
        self.item = item
        categories = store.categories
        let relativeDate = Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())
        let characterCount = item.text?.count ?? 0

        typeLabel.stringValue = item.kind == .image ? "Image" : "Text"
        ageLabel.stringValue = relativeDate
        header.layer?.backgroundColor = color(for: item).cgColor
        clipImageView.image = item.kind == .image ? store.image(for: item) : nil
        clipImageView.isHidden = item.kind != .image
        textTitle.isHidden = item.kind == .image
        textTitle.stringValue = title(for: item)
        textPreview.stringValue = item.kind == .text ? cleanedPreview(item.text ?? "") : "PNG image copied to clipboard"
        textPreview.isHidden = item.kind == .image
        footerLabel.stringValue = item.kind == .text ? "\(item.category)    \(characterCount) characters" : item.category
        view.menu = buildContextMenu(for: item, categories: store.categories)
    }

    private func setup() {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        card.layer?.cornerRadius = 22
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.systemBlue.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        typeLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        typeLabel.textColor = .white
        typeLabel.translatesAutoresizingMaskIntoConstraints = false

        ageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        ageLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        ageLabel.translatesAutoresizingMaskIntoConstraints = false

        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        clipImageView.imageScaling = .scaleProportionallyUpOrDown
        clipImageView.translatesAutoresizingMaskIntoConstraints = false

        textTitle.font = .systemFont(ofSize: 19, weight: .bold)
        textTitle.textColor = .labelColor
        textTitle.lineBreakMode = .byTruncatingTail
        textTitle.translatesAutoresizingMaskIntoConstraints = false

        textPreview.font = .systemFont(ofSize: 13, weight: .regular)
        textPreview.textColor = .secondaryLabelColor
        textPreview.maximumNumberOfLines = 5
        textPreview.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.target = self
        deleteButton.action = #selector(deleteItem)
        styleActionButton(deleteButton, color: NSColor(calibratedRed: 0.88, green: 0.22, blue: 0.24, alpha: 1))

        controlRow.orientation = .horizontal
        controlRow.spacing = 8
        controlRow.alignment = .centerY
        controlRow.addArrangedSubview(deleteButton)
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        controlRow.isHidden = true

        view.addSubview(card)
        card.addSubview(header)
        header.addSubview(typeLabel)
        header.addSubview(ageLabel)
        card.addSubview(previewContainer)
        previewContainer.addSubview(clipImageView)
        previewContainer.addSubview(textTitle)
        previewContainer.addSubview(textPreview)
        card.addSubview(footerLabel)
        card.addSubview(controlRow)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            card.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1),

            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 68),

            typeLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            typeLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),

            ageLabel.leadingAnchor.constraint(equalTo: typeLabel.leadingAnchor),
            ageLabel.topAnchor.constraint(equalTo: typeLabel.bottomAnchor, constant: 1),
            ageLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -14),

            previewContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            previewContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            previewContainer.heightAnchor.constraint(equalToConstant: 150),

            clipImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 16),
            clipImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -16),
            clipImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 14),
            clipImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -14),

            textTitle.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 18),
            textTitle.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -18),
            textTitle.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 22),

            textPreview.leadingAnchor.constraint(equalTo: textTitle.leadingAnchor),
            textPreview.trailingAnchor.constraint(equalTo: textTitle.trailingAnchor),
            textPreview.topAnchor.constraint(equalTo: textTitle.bottomAnchor, constant: 12),

            footerLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            footerLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            footerLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 10),

            controlRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            controlRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            controlRow.heightAnchor.constraint(equalToConstant: 28)
        ])

        installHoverTracking()
    }

    private func styleActionButton(_ button: NSButton, color: NSColor) {
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func installHoverTracking() {
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        controlRow.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        controlRow.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        if isDeleteHit(event) {
            pendingPasteWorkItem?.cancel()
            pendingPasteWorkItem = nil
            deleteItem()
            return
        }

        mouseDownPoint = event.locationInWindow
        hasStartedDrag = false
        pendingPasteWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasStartedDrag, let item = self.item else { return }
                self.pendingPasteWorkItem = nil
                self.onPaste?(item)
            }
        }
        pendingPasteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pendingPasteWorkItem != nil || mouseDownPoint != nil else { return }
        guard let item, let mouseDownPoint, !hasStartedDrag else { return }
        let currentPoint = event.locationInWindow
        guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) > 14 else { return }

        pendingPasteWorkItem?.cancel()
        pendingPasteWorkItem = nil
        hasStartedDrag = true
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id.uuidString, forType: ClipShelfDrag.clipIDType)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(view.bounds, contents: dragImage())
        view.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if isDeleteHit(event) {
            return
        }
        mouseDownPoint = nil
        hasStartedDrag = false
    }

    private func isDeleteHit(_ event: NSEvent) -> Bool {
        guard !controlRow.isHidden else { return false }
        let pointInView = view.convert(event.locationInWindow, from: nil)
        let pointInButton = deleteButton.convert(pointInView, from: view)
        return deleteButton.bounds.contains(pointInButton)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    private func dragImage() -> NSImage {
        let image = NSImage(size: view.bounds.size)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return image
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }

    @objc private func pasteFromMenu() {
        guard let item else { return }
        onPaste?(item)
    }

    @objc private func deleteItem() {
        guard let item else { return }
        onDelete?(item)
    }

    @objc private func moveToCategory(_ sender: NSMenuItem) {
        guard let item, let category = sender.representedObject as? String else { return }
        onCategory?(item, category)
    }

    private func buildContextMenu(for item: ClipItem, categories: [String]) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(pasteFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())

        let categoryMenu = NSMenu()
        for category in categories {
            let categoryItem = NSMenuItem(title: category, action: #selector(moveToCategory(_:)), keyEquivalent: "")
            categoryItem.target = self
            categoryItem.representedObject = category
            categoryItem.state = category == item.category ? .on : .off
            categoryMenu.addItem(categoryItem)
        }
        let moveItem = NSMenuItem(title: "Move to Category", action: nil, keyEquivalent: "")
        menu.setSubmenu(categoryMenu, for: moveItem)
        menu.addItem(moveItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteItem), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func title(for item: ClipItem) -> String {
        switch item.kind {
        case .image:
            return "Copied Image"
        case .text:
            let lines = cleanedPreview(item.text ?? "").split(separator: "\n", maxSplits: 1)
            return lines.first.map(String.init) ?? "Copied Text"
        }
    }

    private func cleanedPreview(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\t", with: " ")
    }

    private func color(for item: ClipItem) -> NSColor {
        switch item.kind {
        case .image:
            return NSColor(calibratedRed: 0.22, green: 0.62, blue: 0.86, alpha: 1)
        case .text:
            let palette = [
                NSColor(calibratedRed: 0.96, green: 0.40, blue: 0.34, alpha: 1),
                NSColor(calibratedRed: 0.95, green: 0.67, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.58, green: 0.38, blue: 0.76, alpha: 1),
                NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.78, alpha: 1)
            ]
            let index = abs(item.category.hashValue) % palette.count
            return palette[index]
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private final class ClipItemView: NSView {
    weak var owner: ClipCell?

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        owner?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.mouseUp(with: event)
    }
}
