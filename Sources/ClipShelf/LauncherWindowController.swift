import AppKit

@MainActor
final class LauncherWindowController: NSWindowController {
    private let store: ClipboardStore
    private let contentView: LauncherView
    private var pasteTarget: PasteTarget?
    private var visibleFrame = NSRect.zero
    private var hiddenFrame = NSRect.zero
    private var outsideClickMonitor: Any?

    var isVisible: Bool {
        window?.isVisible == true
    }

    init(store: ClipboardStore) {
        self.store = store
        self.contentView = LauncherView(store: store)

        let window = LauncherPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = contentView

        super.init(window: window)
        contentView.onClose = { [weak self] in self?.hide() }
        contentView.onPaste = { [weak self] item in
            guard let self else { return }
            closeImmediatelyForPaste()
            PasteController.paste(item, store: store, target: pasteTarget)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let screen = NSScreen.main, let window else { return }
        pasteTarget = PasteController.captureTarget(app: NSWorkspace.shared.frontmostApplication)
        let visible = screen.visibleFrame
        let height = min(CGFloat(390), visible.height * 0.42)
        visibleFrame = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        hiddenFrame = NSRect(x: visible.minX, y: visible.minY - height - 8, width: visible.width, height: height)

        window.alphaValue = 0
        window.setFrame(hiddenFrame, display: true)
        contentView.refresh()
        window.makeFirstResponder(nil)
        window.orderFrontRegardless()
        installOutsideClickMonitor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(visibleFrame, display: true)
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window else { return }
        removeOutsideClickMonitor()
        let targetFrame = hiddenFrame == .zero
            ? window.frame.offsetBy(dx: 0, dy: -window.frame.height - 8)
            : hiddenFrame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(targetFrame, display: true)
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
                window.alphaValue = 1
            }
        }
    }

    private func closeImmediatelyForPaste() {
        guard let window else { return }
        removeOutsideClickMonitor()
        window.orderOut(nil)
        window.alphaValue = 1
        if hiddenFrame != .zero {
            window.setFrame(hiddenFrame, display: false)
        }
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, let window = self.window, window.isVisible else { return }
                if !window.frame.contains(event.locationInWindow) {
                    self.hide()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

enum ClipShelfDrag {
    static let clipIDType = NSPasteboard.PasteboardType("local.clipshelf.clip-id")
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LauncherView: NSView, NSSearchFieldDelegate {
    private let store: ClipboardStore
    private let searchField = NSSearchField()
    private let categoryStack = NSStackView()
    private let categoryScroll = NSScrollView()
    private let cardStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Copy text or images to start building your clipboard history.")
    private var displayedItems: [ClipItem] = []
    private var selectedCategory: String?
    private var categoryButtons: [CategoryDropButton] = []

    var onClose: (() -> Void)?
    var onPaste: ((ClipItem) -> Void)?

    init(store: ClipboardStore) {
        self.store = store
        super.init(frame: .zero)
        setup()
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(storeDidChange), name: .clipShelfStoreDidChange, object: store)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        rebuildCategories()
        applyFilter()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.72, alpha: 0.45).cgColor

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur, positioned: .below, relativeTo: nil)

        let grabber = NSView()
        grabber.wantsLayer = true
        grabber.layer?.backgroundColor = NSColor(calibratedWhite: 0.55, alpha: 0.35).cgColor
        grabber.layer?.cornerRadius = 2
        grabber.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 13, weight: .regular)
        searchField.bezelStyle = .roundedBezel
        searchField.controlSize = .small
        searchField.focusRingType = .default
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        categoryStack.orientation = .horizontal
        categoryStack.spacing = 12
        categoryStack.alignment = .centerY
        categoryStack.translatesAutoresizingMaskIntoConstraints = false

        categoryScroll.documentView = categoryStack
        categoryScroll.hasHorizontalScroller = false
        categoryScroll.hasVerticalScroller = false
        categoryScroll.drawsBackground = false
        categoryScroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New category") ?? NSImage(), target: self, action: #selector(createCategory))
        styleToolbarButton(addButton)
        addButton.toolTip = "New category"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView(views: [searchField, categoryScroll, addButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        cardStack.orientation = .horizontal
        cardStack.alignment = .top
        cardStack.spacing = 24
        cardStack.edgeInsets = NSEdgeInsets(top: 4, left: 30, bottom: 16, right: 30)
        cardStack.translatesAutoresizingMaskIntoConstraints = true

        scrollView.documentView = cardStack
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(grabber)
        addSubview(toolbar)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grabber.widthAnchor.constraint(equalToConstant: 56),
            grabber.heightAnchor.constraint(equalToConstant: 4),

            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            toolbar.heightAnchor.constraint(equalToConstant: 26),

            searchField.widthAnchor.constraint(equalToConstant: 250),
            searchField.heightAnchor.constraint(equalToConstant: 24),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 20),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    private func rebuildCategories() {
        categoryStack.arrangedSubviews.forEach { view in
            categoryStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        categoryButtons = []

        addCategoryButton(title: "Clipboard History", category: nil)
        for category in store.categories {
            addCategoryButton(title: category, category: category)
        }
    }

    private func addCategoryButton(title: String, category: String?) {
        let button = CategoryDropButton(title: title, target: self, action: #selector(categoryButtonPressed(_:)))
        button.setButtonType(.momentaryChange)
        button.font = .systemFont(ofSize: 13, weight: category == selectedCategory ? .semibold : .medium)
        button.contentTintColor = category == selectedCategory ? .controlAccentColor : .labelColor
        button.identifier = NSUserInterfaceItemIdentifier(category ?? "__all__")
        button.category = category
        button.horizontalPadding = category == nil ? 20 : 18
        button.onDropClip = { [weak self] clipID, category in
            guard let self, let category else { return }
            self.store.setCategory(category, for: clipID)
        }
        styleCategoryButton(button, selected: category == selectedCategory)
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        categoryStack.addArrangedSubview(button)
        categoryButtons.append(button)
    }

    private func styleToolbarButton(_ button: NSButton) {
        button.isBordered = false
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
    }

    private func styleCategoryButton(_ button: NSButton, selected: Bool) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 13
        button.layer?.backgroundColor = selected
            ? NSColor.white.withAlphaComponent(0.82).cgColor
            : NSColor.white.withAlphaComponent(0.34).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.8 : 0.35).cgColor
    }

    @objc private func storeDidChange() {
        refresh()
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    @objc private func categoryButtonPressed(_ sender: NSButton) {
        let value = sender.identifier?.rawValue
        selectedCategory = value == "__all__" ? nil : value
        rebuildCategories()
        applyFilter()
    }

    @objc private func close() {
        onClose?()
    }

    @objc private func createCategory() {
        let alert = NSAlert()
        alert.messageText = "New Category"
        alert.informativeText = "Name this category."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.addCategory(input.stringValue)
            selectedCategory = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            refresh()
        }
    }

    private func applyFilter() {
        displayedItems = store.filteredItems(query: searchField.stringValue, category: selectedCategory)
        emptyLabel.isHidden = !displayedItems.isEmpty
        scrollView.isHidden = displayedItems.isEmpty
        rebuildCards()
    }

    private func rebuildCards() {
        cardStack.arrangedSubviews.forEach { view in
            cardStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in displayedItems {
            let card = ClipCardView(item: item, store: store)
            card.onPaste = { [weak self] item in self?.onPaste?(item) }
            card.onDelete = { [weak self] item in self?.store.delete(item.id) }
            card.onCategory = { [weak self] item, category in self?.store.setCategory(category, for: item.id) }
            card.widthAnchor.constraint(equalToConstant: 292).isActive = true
            card.heightAnchor.constraint(equalToConstant: 288).isActive = true
            cardStack.addArrangedSubview(card)
        }

        let count = CGFloat(displayedItems.count)
        let width = count > 0 ? count * 292 + max(0, count - 1) * 24 + 60 : 1
        cardStack.setFrameSize(NSSize(width: width, height: 308))
    }
}

private final class ClipCardView: NSView, NSDraggingSource {
    private let item: ClipItem
    private let store: ClipboardStore
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let actionRow = NSStackView()
    private var mouseDownPoint: NSPoint?
    private var pendingPasteWorkItem: DispatchWorkItem?
    private var didStartDrag = false

    var onPaste: ((ClipItem) -> Void)?
    var onDelete: ((ClipItem) -> Void)?
    var onCategory: ((ClipItem, String) -> Void)?

    init(item: ClipItem, store: ClipboardStore) {
        self.item = item
        self.store = store
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let deletePoint = deleteButton.convert(point, from: self)
        if !actionRow.isHidden, deleteButton.bounds.contains(deletePoint) {
            return deleteButton
        }
        return self
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = color(for: item).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let typeLabel = NSTextField(labelWithString: item.kind == .image ? "Image" : "Text")
        typeLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        typeLabel.textColor = .white
        typeLabel.translatesAutoresizingMaskIntoConstraints = false

        let ageLabel = NSTextField(labelWithString: Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
        ageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        ageLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        ageLabel.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSView()
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: title(for: item))
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: item.kind == .text ? cleanedPreview(item.text ?? "") : "")
        body.font = .systemFont(ofSize: 13, weight: .regular)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 5
        body.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = item.kind == .image ? store.image(for: item) : nil
        imageView.isHidden = item.kind != .image
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let characterCount = item.text?.count ?? 0
        let footer = NSTextField(labelWithString: item.kind == .text ? "\(item.category)    \(characterCount) characters" : item.category)
        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isBordered = false
        deleteButton.font = .systemFont(ofSize: 12, weight: .semibold)
        deleteButton.contentTintColor = .white
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = 8
        deleteButton.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.22, blue: 0.24, alpha: 1).cgColor

        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.addArrangedSubview(deleteButton)
        actionRow.isHidden = true
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        header.addSubview(typeLabel)
        header.addSubview(ageLabel)
        addSubview(preview)
        preview.addSubview(title)
        preview.addSubview(body)
        preview.addSubview(imageView)
        addSubview(footer)
        addSubview(actionRow)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 68),

            typeLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            typeLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            ageLabel.leadingAnchor.constraint(equalTo: typeLabel.leadingAnchor),
            ageLabel.topAnchor.constraint(equalTo: typeLabel.bottomAnchor, constant: 1),

            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor),
            preview.heightAnchor.constraint(equalToConstant: 150),

            title.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: preview.topAnchor, constant: 22),

            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),

            imageView.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: preview.topAnchor, constant: 14),
            imageView.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            footer.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),

            actionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
            deleteButton.heightAnchor.constraint(equalToConstant: 26)
        ])

        let trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        actionRow.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        actionRow.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didStartDrag = false
        pendingPasteWorkItem?.cancel()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint, !didStartDrag else { return }
        let current = event.locationInWindow
        guard hypot(current.x - mouseDownPoint.x, current.y - mouseDownPoint.y) > 10 else { return }
        didStartDrag = true

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id.uuidString, forType: ClipShelfDrag.clipIDType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !didStartDrag else { return }
        onPaste?(item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    @objc private func deleteClicked() {
        onDelete?(item)
    }

    private func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }

    private func title(for item: ClipItem) -> String {
        if item.kind == .image { return "" }
        let lines = cleanedPreview(item.text ?? "").split(separator: "\n", maxSplits: 1)
        return lines.first.map(String.init) ?? "Copied Text"
    }

    private func cleanedPreview(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\t", with: " ")
    }

    private func color(for item: ClipItem) -> NSColor {
        switch item.kind {
        case .image:
            return NSColor(calibratedRed: 0.22, green: 0.62, blue: 0.86, alpha: 1)
        case .text:
            return NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.78, alpha: 1)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

extension LauncherView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ClipCell.identifier, for: indexPath)
        guard let cell = item as? ClipCell else { return item }
        cell.configure(with: displayedItems[indexPath.item], store: store)
        cell.onPaste = { [weak self] item in self?.onPaste?(item) }
        cell.onDelete = { [weak self] item in self?.store.delete(item.id) }
        cell.onCategory = { [weak self] item, category in self?.store.setCategory(category, for: item.id) }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let first = indexPaths.first else { return }
        onPaste?(displayedItems[first.item])
    }
}

private final class CategoryDropButton: NSButton {
    var category: String?
    var onDropClip: ((UUID, String?) -> Void)?
    var horizontalPadding: CGFloat = 18 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + horizontalPadding * 2, height: max(base.height, 26))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([ClipShelfDrag.clipIDType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([ClipShelfDrag.clipIDType])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard category != nil, sender.draggingPasteboard.string(forType: ClipShelfDrag.clipIDType) != nil else {
            return []
        }
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        }
        guard let raw = sender.draggingPasteboard.string(forType: ClipShelfDrag.clipIDType),
              let id = UUID(uuidString: raw),
              category != nil else {
            return false
        }
        onDropClip?(id, category)
        return true
    }
}
