import AppKit
import Combine

class KeybindsViewController: NSViewController {
    var onBack: (() -> Void)?

    private var scrollView: NSScrollView!
    private var contentView: FlippedView!
    private var searchField: NSTextField!
    private var clearSearchButton: NSButton!

    private let manager = KeybindingsManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var searchText: String = ""

    // Editing state
    private var editingAction: KeybindAction?
    private var editingIndex: Int? // -1 = new combo
    private var keyRecorder: KeyRecorderView?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0).cgColor

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.contentView = CenteringClipView()
        scrollView.contentView.drawsBackground = false
        container.addSubview(scrollView)

        contentView = FlippedView()
        contentView.wantsLayer = true
        scrollView.documentView = contentView

        self.view = container

        buildContent()

        manager.$data
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildContent() }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scrollView.frame = view.bounds
        layoutContent()
    }

    private func buildContent() {
        contentView.subviews.forEach { $0.removeFromSuperview() }

        let maxW: CGFloat = 600
        let padH: CGFloat = 32
        var y: CGFloat = 120

        // Header: back button + title + Reset All
        let backButton = NSButton()
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        backButton.contentTintColor = .secondaryLabelColor
        backButton.frame = NSRect(x: padH, y: y, width: 28, height: 28)
        backButton.wantsLayer = true
        backButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        backButton.layer?.cornerRadius = 14
        backButton.target = self
        backButton.action = #selector(backClicked)
        contentView.addSubview(backButton)

        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .labelColor
        title.isBezeled = false
        title.isEditable = false
        title.drawsBackground = false
        title.frame = NSRect(x: padH + 40, y: y - 2, width: 400, height: 34)
        contentView.addSubview(title)

        // Reset All capsule button
        let resetButton = NSButton()
        resetButton.isBordered = false
        resetButton.title = "Reset All"
        resetButton.font = .systemFont(ofSize: 12, weight: .medium)
        resetButton.contentTintColor = .secondaryLabelColor
        resetButton.wantsLayer = true
        resetButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        resetButton.layer?.cornerRadius = 11
        let resetW: CGFloat = 80
        resetButton.frame = NSRect(x: padH + maxW - resetW, y: y + 2, width: resetW, height: 24)
        resetButton.target = self
        resetButton.action = #selector(resetAllClicked)
        contentView.addSubview(resetButton)

        y += 28 + 24

        // Search bar: magnifying glass + field + clear button
        let searchContainer = NSView(frame: NSRect(x: padH, y: y, width: maxW, height: 38))
        searchContainer.wantsLayer = true
        searchContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        searchContainer.layer?.cornerRadius = 8
        searchContainer.layer?.cornerCurve = .continuous
        contentView.addSubview(searchContainer)

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.frame = NSRect(x: 12, y: 9, width: 20, height: 20)
        searchContainer.addSubview(searchIcon)

        searchField = NSTextField()
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = .white
        searchField.placeholderString = "Search by name or shortcut (e.g., cmd+w)"
        searchField.frame = NSRect(x: 38, y: 9, width: maxW - 70, height: 20)
        searchField.delegate = self
        searchContainer.addSubview(searchField)

        clearSearchButton = NSButton()
        clearSearchButton.isBordered = false
        clearSearchButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        clearSearchButton.contentTintColor = .secondaryLabelColor
        clearSearchButton.frame = NSRect(x: maxW - 28, y: 9, width: 20, height: 20)
        clearSearchButton.target = self
        clearSearchButton.action = #selector(clearSearch)
        clearSearchButton.isHidden = searchText.isEmpty
        searchContainer.addSubview(clearSearchButton)

        y += 38 + 24

        // Keybind rows in VStack(spacing: 1), bg white 0.05, cornerRadius 8
        let filteredActions = KeybindAction.allCases.filter { action in
            if searchText.isEmpty { return true }
            return KeybindSearchParser.matches(
                action: action,
                combos: manager.combos(for: action),
                query: searchText
            )
        }

        // Calculate row heights: dynamic based on number of combos
        // Original: VStack(alignment: .trailing, spacing: 6) for combos
        var rowHeights: [CGFloat] = []
        for action in filteredActions {
            let combos = manager.combos(for: action)
            let isEditing = editingAction == action
            let comboCount = max(1, combos.count) + (isEditing && editingIndex == -1 ? 1 : 0)
            // Each combo is 24pt, spacing 6, plus top/bottom padding 13
            let h: CGFloat = comboCount <= 1 ? 50 : CGFloat(comboCount) * 24 + CGFloat(comboCount - 1) * 6 + 26
            rowHeights.append(h)
        }
        let listH = rowHeights.reduce(0, +) + CGFloat(max(0, filteredActions.count - 1))

        let listContainer = NSView(frame: NSRect(x: padH, y: y, width: maxW, height: listH))
        listContainer.wantsLayer = true
        listContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        listContainer.layer?.cornerRadius = 8
        listContainer.layer?.cornerCurve = .continuous
        listContainer.layer?.masksToBounds = true
        contentView.addSubview(listContainer)

        var rowY: CGFloat = 0
        for (i, action) in filteredActions.enumerated() {
            let combos = manager.combos(for: action)
            let rowH = rowHeights[i]
            let row = KeybindRowNSView(
                action: action, combos: combos, manager: manager,
                isEditing: editingAction == action, editingIndex: editingAction == action ? editingIndex : nil
            )
            row.frame = NSRect(x: 0, y: rowY, width: maxW, height: rowH)
            row.onStartEditing = { [weak self] index in
                self?.startEditing(action: action, index: index)
            }
            row.onCancelEditing = { [weak self] in
                self?.cancelEditing()
            }
            listContainer.addSubview(row)
            rowY += rowH
            if i < filteredActions.count - 1 {
                rowY += 1 // spacing 1
            }
        }

        y += listH + 24

        // Help text
        let helpText = NSTextField(labelWithString: "Click a shortcut to change it. Hover to add or remove shortcuts.")
        helpText.font = .systemFont(ofSize: 11)
        helpText.textColor = .secondaryLabelColor
        helpText.isBezeled = false
        helpText.isEditable = false
        helpText.drawsBackground = false
        helpText.frame = NSRect(x: padH, y: y, width: maxW, height: 16)
        contentView.addSubview(helpText)
        y += 32

        contentView.frame = NSRect(x: 0, y: 0, width: maxW + padH * 2, height: y)
    }

    private func layoutContent() {
        guard let docView = scrollView.documentView else { return }
        // Fixed content width; CenteringClipView centers it horizontally in the available space.
        let contentW: CGFloat = 600 + 32 * 2
        docView.frame.origin.x = 0
        docView.frame.size.width = contentW
        docView.frame.size.height = max(view.bounds.height, docView.frame.height)
    }

    private func startEditing(action: KeybindAction, index: Int) {
        editingAction = action
        editingIndex = index
        manager.isEditing = true
        buildContent()
    }

    private func cancelEditing() {
        editingAction = nil
        editingIndex = nil
        manager.isEditing = false
        buildContent()
    }

    @objc private func backClicked() { onBack?() }
    @objc private func clearSearch() {
        searchText = ""
        searchField.stringValue = ""
        buildContent()
    }

    @objc private func resetAllClicked() {
        cancelEditing()
        manager.resetAllToDefaults()
    }
}

// MARK: - NSTextFieldDelegate

extension KeybindsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchText = searchField.stringValue
        clearSearchButton.isHidden = searchText.isEmpty
        buildContent()
    }
}

// MARK: - Keybind Row NSView

private class KeybindRowNSView: NSView {
    let action: KeybindAction
    let manager: KeybindingsManager
    private var combos: [KeyCombo]
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let isEditing: Bool
    private let editingIndex: Int?

    var onStartEditing: ((Int) -> Void)?
    var onCancelEditing: (() -> Void)?

    init(action: KeybindAction, combos: [KeyCombo], manager: KeybindingsManager,
         isEditing: Bool, editingIndex: Int?) {
        self.action = action
        self.combos = combos
        self.manager = manager
        self.isEditing = isEditing
        self.editingIndex = editingIndex

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor

        buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildContent() {
        subviews.forEach { $0.removeFromSuperview() }

        // Action name: font 13, .primary, minWidth 180
        let nameLabel = NSTextField(labelWithString: action.displayName)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.drawsBackground = false
        addSubview(nameLabel)

        // We'll position everything in layout()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let padH: CGFloat = 12

        // Layout name — vertically centered
        if let nameLabel = subviews.first as? NSTextField {
            nameLabel.frame = NSRect(x: padH, y: (h - 18) / 2, width: 180, height: 18)
        }

        // Remove and rebuild combo views on each layout (they depend on hover state)
        for v in subviews.dropFirst() { v.removeFromSuperview() }

        let rightEdge = bounds.width - padH
        let comboSpacing: CGFloat = 6

        // Build all combo items to stack vertically (VStack trailing-aligned, spacing: 6)
        struct ComboItem {
            let view: NSView
            let width: CGFloat
            let height: CGFloat = 24
        }
        var comboItems: [ComboItem] = []

        // Existing combos
        for (index, combo) in combos.enumerated() {
            // Build horizontal row for this combo: [remove/reset] [combo] [add btn on last]
            let rowContainer = NSView()
            rowContainer.wantsLayer = true
            var rowW: CGFloat = 0

            // Remove/reset button on hover (left of combo)
            if isHovered {
                let icon = combos.count == 1 ? "arrow.counterclockwise" : "minus"
                let removeBtn = makeCircleButton(icon: icon)
                removeBtn.frame = NSRect(x: 0, y: 2, width: 20, height: 20)
                removeBtn.target = self
                removeBtn.action = combos.count == 1 ? #selector(resetCombo) : #selector(removeComboAtIndex(_:))
                removeBtn.tag = index
                rowContainer.addSubview(removeBtn)
                rowW += 28
            }

            // Key combo or recording prompt
            if isEditing && editingIndex == index {
                let prompt = makeRecordingPrompt()
                let promptW = prompt.frame.width
                prompt.frame = NSRect(x: rowW, y: 0, width: promptW, height: 24)
                rowContainer.addSubview(prompt)

                let recorder = KeyRecorderView()
                recorder.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
                recorder.alphaValue = 0
                recorder.onComboRecorded = { [weak self] newCombo in
                    self?.handleComboRecorded(newCombo, at: index)
                }
                recorder.onModifiersChanged = { [weak prompt] mods in
                    prompt?.update(modifiers: mods)
                }
                rowContainer.addSubview(recorder)
                window?.makeFirstResponder(recorder)

                rowW += promptW
            } else {
                let comboView = makeKeyComboView(combo: combo)
                let comboW = comboView.frame.width
                comboView.frame = NSRect(x: rowW, y: 0, width: comboW, height: 24)
                rowContainer.addSubview(comboView)

                // Make clickable to edit
                let clickArea = ClickableView(frame: comboView.frame)
                clickArea.onClick = { [weak self] in
                    self?.onStartEditing?(index)
                }
                rowContainer.addSubview(clickArea)

                rowW += comboW
            }

            // Add button on last combo when hovered
            if isHovered && index == combos.count - 1 {
                rowW += 8
                let addBtn = makeCircleButton(icon: "plus")
                addBtn.frame = NSRect(x: rowW, y: 2, width: 20, height: 20)
                addBtn.target = self
                addBtn.action = #selector(addComboClicked)
                rowContainer.addSubview(addBtn)
                rowW += 20
            }

            rowContainer.frame = NSRect(x: 0, y: 0, width: rowW, height: 24)
            comboItems.append(ComboItem(view: rowContainer, width: rowW))
        }

        // New combo recording row (when editing index == -1)
        if isEditing && editingIndex == -1 {
            let rowContainer = NSView()
            rowContainer.wantsLayer = true
            var rowW: CGFloat = 0

            let cancelBtn = makeCircleButton(icon: "xmark")
            cancelBtn.frame = NSRect(x: 0, y: 2, width: 20, height: 20)
            cancelBtn.target = self
            cancelBtn.action = #selector(cancelEditClicked)
            rowContainer.addSubview(cancelBtn)
            rowW += 28

            let prompt = makeRecordingPrompt()
            let promptW = prompt.frame.width
            prompt.frame = NSRect(x: rowW, y: 0, width: promptW, height: 24)
            rowContainer.addSubview(prompt)

            let recorder = KeyRecorderView()
            recorder.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            recorder.alphaValue = 0
            recorder.onComboRecorded = { [weak self] newCombo in
                self?.handleComboRecorded(newCombo, at: -1)
            }
            recorder.onModifiersChanged = { [weak prompt] mods in
                prompt?.update(modifiers: mods)
            }
            rowContainer.addSubview(recorder)
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(recorder)
            }

            rowW += promptW
            rowContainer.frame = NSRect(x: 0, y: 0, width: rowW, height: 24)
            comboItems.append(ComboItem(view: rowContainer, width: rowW))
        }

        // Stack combos vertically, aligned to trailing edge
        let totalComboH = CGFloat(comboItems.count) * 24 + CGFloat(max(0, comboItems.count - 1)) * comboSpacing
        var comboY = (h - totalComboH) / 2

        for item in comboItems {
            let x = rightEdge - item.width
            item.view.frame = NSRect(x: x, y: comboY, width: item.width, height: 24)
            addSubview(item.view)
            comboY += 24 + comboSpacing
        }
    }

    // MARK: - Key Combo Rendering

    private func makeKeyComboView(combo: KeyCombo) -> NSView {
        // HStack(spacing: 3) of individual key cap tiles
        let container = NSView()
        container.wantsLayer = true
        var x: CGFloat = 0
        let spacing: CGFloat = 3

        let modifiers: [(Bool, String)] = [
            (combo.hasControl, "⌃"),
            (combo.hasOption, "⌥"),
            (combo.hasShift, "⇧"),
            (combo.hasCommand, "⌘")
        ]

        for (hasmod, symbol) in modifiers where hasmod {
            let cap = makeKeyCap(text: symbol, isSymbol: true)
            cap.frame.origin.x = x
            container.addSubview(cap)
            x += cap.frame.width + spacing
        }

        // Base key
        let keyCap = makeKeyCap(text: combo.keyString, isSymbol: false)
        keyCap.frame.origin.x = x
        container.addSubview(keyCap)
        x += keyCap.frame.width

        container.frame = NSRect(x: 0, y: 0, width: x, height: 24)
        return container
    }

    private func makeKeyCap(text: String, isSymbol: Bool) -> NSView {
        return keyCapTile(text: text, isSymbol: isSymbol)
    }

    // Original: Text("Press keys...") with .padding(.horizontal, 12), RoundedRectangle bg & stroke.
    // Updates live to show the modifiers currently being held while recording.
    private func makeRecordingPrompt() -> RecordingPromptView {
        return RecordingPromptView()
    }

    private func makeCircleButton(icon: String) -> NSButton {
        let btn = NSButton()
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        btn.contentTintColor = .secondaryLabelColor
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        btn.layer?.cornerRadius = 10
        return btn
    }

    // MARK: - Actions

    @objc private func addComboClicked() {
        onStartEditing?(-1)
    }

    @objc private func cancelEditClicked() {
        onCancelEditing?()
    }

    @objc private func resetCombo() {
        manager.resetToDefault(for: action)
        onCancelEditing?()
    }

    @objc private func removeComboAtIndex(_ sender: NSButton) {
        let index = sender.tag
        if index >= 0 && index < combos.count {
            manager.removeCombo(combos[index], from: action)
            onCancelEditing?()
        }
    }

    private func handleComboRecorded(_ combo: KeyCombo, at index: Int) {
        guard combo.isValidKeybind else {
            onCancelEditing?()
            return
        }

        if manager.findConflict(for: combo, excluding: action, excludingIndex: index == -1 ? nil : index) != nil {
            onCancelEditing?()
            return
        }

        if index == -1 {
            manager.addCombo(combo, to: action)
        } else {
            var current = combos
            if index < current.count {
                current[index] = combo
                manager.setCombos(current, for: action)
            }
        }
        onCancelEditing?()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        // .inVisibleRect keeps the tracking area synced with the view as it scrolls.
        trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // During scrolling, AppKit may not deliver matching enter/exit pairs, leaving rows
        // stuck in a hovered state. Re-validate hover whenever the scroll content moves.
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollDidChange),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }
    }

    @objc private func scrollDidChange() {
        validateHover(animated: false)
    }

    override func mouseEntered(with event: NSEvent) {
        validateHover(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        validateHover(animated: true)
    }

    /// Sets hover state from the actual cursor position rather than trusting enter/exit
    /// events, which can be dropped during scroll.
    private func validateHover(animated: Bool) {
        guard let window = window else { return }
        let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let nowHovered = bounds.contains(pointInView) && window.isKeyWindow
        guard nowHovered != isHovered else { return }
        isHovered = nowHovered

        let target = NSColor.white.withAlphaComponent(nowHovered ? 0.04 : 0.02).cgColor
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                layer?.backgroundColor = target
            }
        } else {
            layer?.backgroundColor = target
        }
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        // Click on row background cancels editing
        if isEditing {
            onCancelEditing?()
        }
    }
}

// MARK: - Key Cap Tile

/// A single rounded key-cap tile (a modifier symbol or a base key), matching the combo display.
func keyCapTile(text: String, isSymbol: Bool) -> NSView {
    let label = NSTextField(labelWithString: text)
    let fontSize: CGFloat = isSymbol ? 14 : 12
    let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    if let descriptor = baseFont.fontDescriptor.withDesign(.rounded) {
        label.font = NSFont(descriptor: descriptor, size: fontSize)
    } else {
        label.font = baseFont
    }
    label.textColor = .labelColor
    label.alignment = .center
    label.isBezeled = false
    label.isEditable = false
    label.drawsBackground = false

    label.sizeToFit()
    let padH: CGFloat = isSymbol ? 0 : 6
    let w = max(24, label.frame.width + padH * 2)
    let h: CGFloat = 24

    let cap = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    cap.wantsLayer = true
    cap.layer?.cornerRadius = 6
    cap.layer?.cornerCurve = .continuous
    cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    cap.layer?.borderWidth = 1
    cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

    label.frame = NSRect(x: 0, y: (h - label.frame.height) / 2, width: w, height: label.frame.height)
    cap.addSubview(label)

    return cap
}

// MARK: - Recording Prompt

/// Shown while recording a shortcut. With no modifiers it's a "Press keys..." pill; as modifiers
/// are held it spawns a key-cap tile per modifier (matching the combo display) plus a pending "…".
private class RecordingPromptView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
        wantsLayer = true
        update(modifiers: [])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(modifiers: NSEvent.ModifierFlags) {
        subviews.forEach { $0.removeFromSuperview() }

        let mods: [(Bool, String)] = [
            (modifiers.contains(.control), "⌃"),
            (modifiers.contains(.option), "⌥"),
            (modifiers.contains(.shift), "⇧"),
            (modifiers.contains(.command), "⌘")
        ]

        if !mods.contains(where: { $0.0 }) {
            // Nothing held yet: the "Press keys..." pill.
            layer?.cornerRadius = 6
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

            let label = NSTextField(labelWithString: "Press keys...")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.isBezeled = false
            label.isEditable = false
            label.drawsBackground = false
            label.sizeToFit()
            let padH: CGFloat = 12
            label.frame = NSRect(x: padH, y: (24 - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
            addSubview(label)
            frame.size.width = label.frame.width + padH * 2
            return
        }

        // Modifiers held: render a tile per modifier, then a pending placeholder.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0

        var x: CGFloat = 0
        let spacing: CGFloat = 3
        for (held, symbol) in mods where held {
            let cap = keyCapTile(text: symbol, isSymbol: true)
            cap.frame.origin.x = x
            addSubview(cap)
            x += cap.frame.width + spacing
        }
        let pending = keyCapTile(text: "…", isSymbol: false)
        pending.frame.origin.x = x
        pending.alphaValue = 0.5
        addSubview(pending)
        x += pending.frame.width

        frame.size.width = x
    }
}
