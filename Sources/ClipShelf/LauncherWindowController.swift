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
        let height = min(CGFloat(380), visible.height * 0.42)
        visibleFrame = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        hiddenFrame = NSRect(x: visible.minX, y: visible.minY - height - 8, width: visible.width, height: height)

        window.alphaValue = 0
        window.setFrame(hiddenFrame, display: true)
        contentView.prepareForShow()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
        installOutsideClickMonitor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
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
            context.duration = 0.13
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

private enum ShelfStyle {
    static let cardWidth: CGFloat = 252
    static let cardHeight: CGFloat = 272
    static let cardSpacing: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let shelfInset: CGFloat = 28
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
    private var cards: [ClipCardView] = []
    private var selectedIndex: Int? {
        didSet { updateSelectionHighlight() }
    }
    private var selectedCategory: String?
    private var needsRefresh = false
    private var cardBuildGeneration = 0

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

    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        needsRefresh = false
        rebuildCategories()
        applyFilter()
    }

    /// Called right before the shelf appears; skips the expensive rebuild
    /// unless the store changed while the shelf was hidden.
    func prepareForShow() {
        if needsRefresh {
            refresh()
        } else {
            cards.forEach { $0.updateAge() }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onClose?()
        case 36, 76: // Return / Enter
            pasteSelection()
        case 123: // Left arrow
            moveSelection(by: -1)
        case 124: // Right arrow
            moveSelection(by: 1)
        case 51, 117: // Delete / Forward delete
            deleteSelection()
        default:
            if let characters = event.characters,
               !characters.isEmpty,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               characters.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil {
                focusSearch(appending: characters)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func pasteSelection() {
        let item: ClipItem?
        if let selectedIndex, displayedItems.indices.contains(selectedIndex) {
            item = displayedItems[selectedIndex]
        } else {
            item = displayedItems.first
        }
        guard let item else { return }
        onPaste?(item)
    }

    private func moveSelection(by delta: Int) {
        guard !displayedItems.isEmpty else { return }
        let next: Int
        if let selectedIndex {
            next = max(0, min(displayedItems.count - 1, selectedIndex + delta))
        } else {
            next = delta >= 0 ? 0 : displayedItems.count - 1
        }
        selectedIndex = next
        if cards.indices.contains(next) {
            let card = cards[next]
            card.scrollToVisible(card.bounds.insetBy(dx: -ShelfStyle.cardSpacing - 8, dy: 0))
        }
    }

    private func deleteSelection() {
        guard let selectedIndex, displayedItems.indices.contains(selectedIndex) else { return }
        store.delete(displayedItems[selectedIndex].id)
    }

    private func focusSearch(appending characters: String) {
        searchField.stringValue += characters
        window?.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        }
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                onClose?()
                return true
            }
            return false
        case #selector(NSResponder.insertNewline(_:)):
            pasteSelection()
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            guard searchField.stringValue.isEmpty else { return false }
            window?.makeFirstResponder(self)
            moveSelection(by: commandSelector == #selector(NSResponder.moveRight(_:)) ? 1 : -1)
            return true
        default:
            return false
        }
    }

    // MARK: - Layout

    private func setup() {
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur, positioned: .below, relativeTo: nil)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint, positioned: .above, relativeTo: blur)

        let topHairline = NSView()
        topHairline.wantsLayer = true
        topHairline.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        topHairline.translatesAutoresizingMaskIntoConstraints = false

        let grabber = NSView()
        grabber.wantsLayer = true
        grabber.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        grabber.layer?.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false

        categoryStack.orientation = .horizontal
        categoryStack.spacing = 8
        categoryStack.alignment = .centerY
        categoryStack.translatesAutoresizingMaskIntoConstraints = false

        categoryScroll.documentView = categoryStack
        categoryScroll.hasHorizontalScroller = false
        categoryScroll.hasVerticalScroller = false
        categoryScroll.drawsBackground = false
        categoryScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        categoryScroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New pinboard") ?? NSImage(), target: self, action: #selector(createCategory))
        addButton.isBordered = false
        addButton.contentTintColor = NSColor.black.withAlphaComponent(0.6)
        addButton.wantsLayer = true
        addButton.layer?.cornerRadius = 14
        addButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        addButton.toolTip = "New pinboard"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Type to search"
        searchField.font = .systemFont(ofSize: 13)
        searchField.controlSize = .regular
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView(views: [categoryScroll, addButton, searchField])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        cardStack.orientation = .horizontal
        cardStack.alignment = .top
        cardStack.spacing = ShelfStyle.cardSpacing
        cardStack.edgeInsets = NSEdgeInsets(top: 8, left: ShelfStyle.shelfInset, bottom: 18, right: ShelfStyle.shelfInset)
        cardStack.translatesAutoresizingMaskIntoConstraints = true

        scrollView.documentView = cardStack
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topHairline)
        addSubview(grabber)
        addSubview(toolbar)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),

            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.topAnchor.constraint(equalTo: topAnchor),
            topHairline.heightAnchor.constraint(equalToConstant: 1),

            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            grabber.widthAnchor.constraint(equalToConstant: 44),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShelfStyle.shelfInset),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShelfStyle.shelfInset),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            toolbar.heightAnchor.constraint(equalToConstant: 30),

            categoryScroll.heightAnchor.constraint(equalToConstant: 30),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    // MARK: - Pinboard tabs

    private func rebuildCategories() {
        categoryStack.arrangedSubviews.forEach { view in
            categoryStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        addCategoryButton(title: "Clipboard History", category: nil)
        for category in store.categories {
            addCategoryButton(title: category, category: category)
        }
    }

    private func addCategoryButton(title: String, category: String?) {
        let button = CategoryDropButton(title: title, target: self, action: #selector(categoryButtonPressed(_:)))
        button.setButtonType(.momentaryChange)
        button.identifier = NSUserInterfaceItemIdentifier(category ?? "__all__")
        button.category = category
        button.isSelectedCategory = category == selectedCategory
        button.onDropClip = { [weak self] clipID, category in
            guard let self, let category else { return }
            self.store.setCategory(category, for: clipID)
        }
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        categoryStack.addArrangedSubview(button)
    }

    @objc private func storeDidChange() {
        if window?.isVisible == true {
            refresh()
        } else {
            needsRefresh = true
        }
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

    @objc private func createCategory() {
        let alert = NSAlert()
        alert.messageText = "New Pinboard"
        alert.informativeText = "Name this pinboard."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            store.addCategory(name)
            selectedCategory = name
            refresh()
        }
    }

    // MARK: - Cards

    private func applyFilter() {
        displayedItems = store.filteredItems(query: searchField.stringValue, category: selectedCategory)
        emptyLabel.isHidden = !displayedItems.isEmpty
        scrollView.isHidden = displayedItems.isEmpty
        rebuildCards()
    }

    private func rebuildCards() {
        cardBuildGeneration += 1
        let generation = cardBuildGeneration

        cardStack.arrangedSubviews.forEach { view in
            cardStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cards = []

        let count = CGFloat(displayedItems.count)
        let width = count > 0
            ? count * ShelfStyle.cardWidth + max(0, count - 1) * ShelfStyle.cardSpacing + ShelfStyle.shelfInset * 2
            : 1
        cardStack.setFrameSize(NSSize(width: width, height: ShelfStyle.cardHeight + 26))

        // Build only what fits on screen now; stream the rest in so opening stays instant.
        appendCards(upTo: min(displayedItems.count, 20))
        if cards.count < displayedItems.count {
            buildRemainingCards(generation: generation)
        }

        if let current = selectedIndex {
            selectedIndex = displayedItems.isEmpty ? nil : min(current, displayedItems.count - 1)
        } else {
            updateSelectionHighlight()
        }
    }

    private func appendCards(upTo limit: Int) {
        while cards.count < limit {
            let item = displayedItems[cards.count]
            let card = ClipCardView(item: item, store: store)
            card.onPaste = { [weak self] item in self?.onPaste?(item) }
            card.onDelete = { [weak self] item in self?.store.delete(item.id) }
            card.onCategory = { [weak self] item, category in self?.store.setCategory(category, for: item.id) }
            card.widthAnchor.constraint(equalToConstant: ShelfStyle.cardWidth).isActive = true
            card.heightAnchor.constraint(equalToConstant: ShelfStyle.cardHeight).isActive = true
            cardStack.addArrangedSubview(card)
            cards.append(card)
        }
    }

    private func buildRemainingCards(generation: Int) {
        Task { @MainActor [weak self] in
            guard let self, generation == self.cardBuildGeneration else { return }
            self.appendCards(upTo: min(self.displayedItems.count, self.cards.count + 40))
            if self.cards.count < self.displayedItems.count {
                self.buildRemainingCards(generation: generation)
            } else {
                self.updateSelectionHighlight()
            }
        }
    }

    private func updateSelectionHighlight() {
        for (index, card) in cards.enumerated() {
            card.isSelectedCard = index == selectedIndex
        }
    }
}

// MARK: - Card

private final class ClipCardView: NSView, NSDraggingSource {
    private let item: ClipItem
    private let store: ClipboardStore
    private let content = NSView()
    private let ageLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false
    private var isHovered = false {
        didSet { updateChrome() }
    }

    var isSelectedCard = false {
        didSet { updateChrome() }
    }

    var onPaste: ((ClipItem) -> Void)?
    var onDelete: ((ClipItem) -> Void)?
    var onCategory: ((ClipItem, String) -> Void)?

    init(item: ClipItem, store: ClipboardStore) {
        self.item = item
        self.store = store
        super.init(frame: .zero)
        setup()
        menu = buildContextMenu()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space.
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        if !deleteButton.isHidden {
            let pointInButton = deleteButton.convert(localPoint, from: self)
            if deleteButton.bounds.contains(pointInButton) {
                return deleteButton
            }
        }
        return self
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        content.layer?.cornerRadius = ShelfStyle.cardCornerRadius
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor.clear.cgColor
        content.layer?.borderWidth = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = headerColor(for: item).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let typeLabel = NSTextField(labelWithString: item.kind == .image ? "Image" : "Text")
        typeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        typeLabel.textColor = .white
        typeLabel.translatesAutoresizingMaskIntoConstraints = false

        ageLabel.stringValue = Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())
        ageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        ageLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        ageLabel.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSView()
        preview.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: title(for: item))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.isHidden = item.kind == .image
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: item.kind == .text ? cleanedPreview(item.text ?? "") : "")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 7
        body.isHidden = item.kind == .image
        body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        body.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = item.kind == .image ? store.thumbnail(for: item) : nil
        imageView.isHidden = item.kind != .image
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.07).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        let categoryLabel = NSTextField(labelWithString: item.category)
        categoryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        categoryLabel.textColor = .secondaryLabelColor
        categoryLabel.lineBreakMode = .byTruncatingTail
        categoryLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: item.kind == .text ? "\(item.text?.count ?? 0) characters" : "PNG image")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let deleteImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete clip")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        deleteButton.image = deleteImage
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .white
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = 11
        deleteButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        deleteButton.toolTip = "Delete"
        deleteButton.isHidden = true
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        header.addSubview(typeLabel)
        header.addSubview(ageLabel)
        content.addSubview(preview)
        preview.addSubview(title)
        preview.addSubview(body)
        preview.addSubview(imageView)
        content.addSubview(separator)
        content.addSubview(categoryLabel)
        content.addSubview(detailLabel)
        content.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),

            typeLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            typeLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ageLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            ageLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: typeLabel.trailingAnchor, constant: 8),

            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor),
            preview.bottomAnchor.constraint(equalTo: separator.topAnchor),

            title.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: preview.topAnchor, constant: 12),

            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            body.bottomAnchor.constraint(lessThanOrEqualTo: preview.bottomAnchor, constant: -10),

            imageView.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: preview.topAnchor, constant: 10),
            imageView.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -10),

            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -30),

            categoryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            categoryLabel.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),
            categoryLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),

            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),

            deleteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            deleteButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        let trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    func updateAge() {
        ageLabel.stringValue = Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())
    }

    private func updateChrome() {
        deleteButton.isHidden = !isHovered
        ageLabel.isHidden = isHovered
        let ringVisible = isHovered || isSelectedCard
        content.layer?.borderWidth = ringVisible ? 3 : 0
        content.layer?.borderColor = ringVisible ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didStartDrag = false
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

    @objc private func pasteFromMenu() {
        onPaste?(item)
    }

    @objc private func moveToCategory(_ sender: NSMenuItem) {
        guard let category = sender.representedObject as? String else { return }
        onCategory?(item, category)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(pasteFromMenu), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)
        menu.addItem(.separator())

        let categoryMenu = NSMenu()
        for category in store.categories {
            let categoryItem = NSMenuItem(title: category, action: #selector(moveToCategory(_:)), keyEquivalent: "")
            categoryItem.target = self
            categoryItem.representedObject = category
            categoryItem.state = category == item.category ? .on : .off
            categoryMenu.addItem(categoryItem)
        }
        let moveItem = NSMenuItem(title: "Move to Pinboard", action: nil, keyEquivalent: "")
        menu.addItem(moveItem)
        menu.setSubmenu(categoryMenu, for: moveItem)
        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)
        return menu
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

    private func headerColor(for item: ClipItem) -> NSColor {
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

// MARK: - Pinboard pill

private final class CategoryDropButton: NSButton {
    var category: String?
    var onDropClip: ((UUID, String?) -> Void)?
    var isSelectedCategory = false {
        didSet { applyStyle(dropTargeted: false) }
    }

    private let horizontalPadding: CGFloat = 16

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + horizontalPadding * 2, height: max(base.height, 28))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([ClipShelfDrag.clipIDType])
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 14
        applyStyle(dropTargeted: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([ClipShelfDrag.clipIDType])
    }

    private func applyStyle(dropTargeted: Bool) {
        font = .systemFont(ofSize: 12.5, weight: isSelectedCategory ? .semibold : .medium)
        contentTintColor = isSelectedCategory ? .labelColor : .secondaryLabelColor
        if dropTargeted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        } else {
            layer?.backgroundColor = isSelectedCategory
                ? NSColor.white.withAlphaComponent(0.92).cgColor
                : NSColor.white.withAlphaComponent(0.4).cgColor
        }
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(isSelectedCategory ? 0.14 : 0.06).cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard category != nil, sender.draggingPasteboard.string(forType: ClipShelfDrag.clipIDType) != nil else {
            return []
        }
        applyStyle(dropTargeted: true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        applyStyle(dropTargeted: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { applyStyle(dropTargeted: false) }
        guard let raw = sender.draggingPasteboard.string(forType: ClipShelfDrag.clipIDType),
              let id = UUID(uuidString: raw),
              category != nil else {
            return false
        }
        onDropClip?(id, category)
        return true
    }
}
