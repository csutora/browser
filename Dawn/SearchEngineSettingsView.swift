import AppKit

// A button with a closure action (no target/selector plumbing).
class ActionButton: NSButton {
    var onAction: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { onAction?() }
    convenience init(title: String) {
        self.init(frame: .zero)
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
    }
}

// A view whose height rolls between 0 and its content height by ANIMATING a height constraint's
// constant. The model layout shrinks/grows frame-by-frame, which matters: snapping the model closed
// and letting only the layer presentation animate makes AppKit discard the backing stores of text
// views that are suddenly model-outside the bounds, so all the text vanishes on the first tick.
// While open the constraint is inactive, so the view tracks content changes naturally.
final class CollapsibleView: NSView {
    private var heightC: NSLayoutConstraint!
    private(set) var isOpen = false

    init(content: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let bottom = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        bottom.priority = NSLayoutConstraint.Priority(999)   // yields while the height clamp holds
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            bottom,
        ])
        heightC = heightAnchor.constraint(equalToConstant: 0)
        heightC.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOpen(_ open: Bool, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard open != isOpen else { completion?(); return }
        isOpen = open
        let start = frame.height   // mid-animation toggles continue from wherever they are
        if open {
            heightC.isActive = false
            let target = fittingSize.height
            heightC.constant = start
            heightC.isActive = true
            guard animated else { heightC.isActive = false; completion?(); return }
            runHeight(to: target) { [weak self] in
                if let self, self.isOpen { self.heightC.isActive = false }
                completion?()
            }
        } else {
            heightC.constant = start
            heightC.isActive = true
            guard animated else { heightC.constant = 0; completion?(); return }
            runHeight(to: 0, completion: completion)
        }
    }

    private func runHeight(to target: CGFloat, completion: (() -> Void)?) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            heightC.animator().constant = target
        }, completionHandler: completion)
    }
}

// A clickable row with a hover background that also updates while scrolling under a still cursor.
final class RowView: NSView {
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var hoverEnabled = true { didSet { if !hoverEnabled { setHovered(false) } } }
    private var tracking: NSTrackingArea?
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(recomputeHover),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    @objc func recomputeHover() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(p) && visibleRect.contains(p))
    }
    private func setHovered(_ v: Bool) {
        let want = v && hoverEnabled
        guard want != hovered else { return }
        hovered = want
        layer?.backgroundColor = hovered ? NSColor.white.withAlphaComponent(0.05).cgColor : NSColor.clear.cgColor
        onHoverChange?(hovered)
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
}

// A faded text affordance ("edit" / "delete"): brighter on hover, no background, wide hit area.
final class FadedTextButton: ActionButton {
    private let labelText: String
    private var tracking: NSTrackingArea?
    init(text: String) {
        labelText = text
        super.init(frame: .zero)
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        style(.secondaryLabelColor)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func style(_ color: NSColor) {
        attributedTitle = NSAttributedString(string: labelText, attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 12),
        ])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { style(.labelColor) }
    override func mouseExited(with event: NSEvent) { style(.secondaryLabelColor) }
}

// The "Search engine" disclosure. The list panel sits *behind* the header (z-order) and rolls out from
// under it; Add / Edit expand a buttonless form in place under the row.
final class SearchEngineSettingsView: NSView, NSTextFieldDelegate {
    var onLayoutChange: (() -> Void)?

    // Saving is live (controlTextDidChange); Enter just closes, like every other dismiss.
    func controlTextDidChange(_ obj: Notification) { openLiveSave?() }
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSReturnTextMovement { closeForm() }
    }

    private let header = ClickableView()
    private let headerValue = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let listPanel: CollapsibleView
    private let bodyStack = NSStackView()

    private var expanded = false
    private var openSlot: NSStackView?      // slot whose form is open
    private var openLiveSave: (() -> Void)?
    private var openCleanup: (() -> Void)?
    private var openFormView: NSView?
    private var formMonitor: Any?
    private var slots: [UUID: NSStackView] = [:]
    private var addSlot: NSStackView!

    private let listColor = NSColor.black.withAlphaComponent(0.1)

    override init(frame frameRect: NSRect) {
        bodyStack.orientation = .vertical
        bodyStack.spacing = 1
        bodyStack.alignment = .leading
        // No side insets: rows run edge to edge, so their hover highlight spans the full panel width.
        listPanel = CollapsibleView(content: bodyStack, insets: NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0))
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // Lives as a row inside a settings section box: a flat 40pt header row, with the list panel
        // rolling out below it (the section box supplies the outer rounding and clipping).
        listPanel.translatesAutoresizingMaskIntoConstraints = false
        listPanel.wantsLayer = true
        listPanel.layer?.backgroundColor = listColor.cgColor
        addSubview(listPanel)

        setupHeader()
        addSubview(header)

        let toBottom = listPanel.bottomAnchor.constraint(equalTo: bottomAnchor)
        toBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),

            listPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            listPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            listPanel.topAnchor.constraint(equalTo: header.bottomAnchor),
            toBottom,
            bottomAnchor.constraint(greaterThanOrEqualTo: header.bottomAnchor),
        ])

        rebuildBody()
        refreshHeaderValue()
    }

    // MARK: - Header

    private func setupHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.restColor = NSColor.white.withAlphaComponent(0.02)    // matches sibling section rows
        header.hoverColor = NSColor.white.withAlphaComponent(0.05)
        header.layer?.backgroundColor = header.restColor.cgColor
        header.onClick = { [weak self] in self?.toggleExpanded() }

        let title = NSTextField(labelWithString: "Search engine")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        headerValue.font = .systemFont(ofSize: 13)
        headerValue.textColor = .secondaryLabelColor
        headerValue.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerValue)

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        chip.layer?.cornerRadius = 11
        chip.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(chip)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.wantsLayer = true
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chevron)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chip.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            chip.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 22),
            chip.heightAnchor.constraint(equalToConstant: 22),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),
            chevron.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            headerValue.trailingAnchor.constraint(equalTo: chip.leadingAnchor, constant: -10),
            headerValue.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
    }

    private func refreshHeaderValue() { headerValue.stringValue = SearchEngineStore.shared.defaultEngine.name }

    func toggleExpanded() {
        expanded.toggle()
        if !expanded { closeForm() }   // rows are left in place while collapsing (no mid-animation rebuild)
        listPanel.setOpen(expanded)    // drives its own frame-by-frame height animation
        animate { self.rotateChevron(self.expanded) }
    }

    private func rotateChevron(_ up: Bool) {
        guard let layer = chevron.layer else { return }
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            let f = chevron.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: f.midX, y: f.midY)
        }
        layer.transform = CATransform3DMakeRotation(up ? .pi : 0, 0, 0, 1)
    }

    // MARK: - Rows

    private func rebuildBody() {
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slots.removeAll()
        for engine in SearchEngineStore.shared.engines {
            let slot = verticalSlot()
            let row = makeRow(for: engine)
            slot.addArrangedSubview(row)
            fill(row, slot)
            bodyStack.addArrangedSubview(slot)
            fill(slot, bodyStack)
            slots[engine.id] = slot
        }
        addSlot = verticalSlot()
        let addRow = makeAddRow()
        addSlot.addArrangedSubview(addRow)
        fill(addRow, addSlot)
        bodyStack.addArrangedSubview(addSlot)
        fill(addSlot, bodyStack)
    }

    private func verticalSlot() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.spacing = 4
        s.alignment = .leading
        return s
    }

    private func makeRow(for engine: SearchEngine) -> RowView {
        let store = SearchEngineStore.shared
        let isDefault = engine.id == store.defaultEngineID

        let leading: NSView
        if isDefault {
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Default")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            check.contentTintColor = .controlAccentColor
            leading = check
        } else {
            leading = NSView()
        }

        let name = NSTextField(labelWithString: engine.name)
        name.font = .systemFont(ofSize: 13)
        name.textColor = isDefault ? .labelColor : .secondaryLabelColor   // default normal, others faint
        name.translatesAutoresizingMaskIntoConstraints = false

        let bang = NSTextField(labelWithString: engine.bangEnabled ? (engine.bang.map { "(\($0))" } ?? "") : "")
        bang.font = .systemFont(ofSize: 13)
        bang.textColor = .tertiaryLabelColor
        bang.translatesAutoresizingMaskIntoConstraints = false

        let edit = FadedTextButton(text: "edit")
        edit.onAction = { [weak self] in self?.toggleEdit(engine) }
        let delete = FadedTextButton(text: "delete")
        delete.onAction = { [weak self] in
            SearchEngineStore.shared.remove(engine); self?.refreshHeaderValue(); self?.reconcileRows()
        }
        let actions = NSStackView(views: [edit, delete])
        actions.spacing = 2
        actions.isHidden = true
        actions.translatesAutoresizingMaskIntoConstraints = false

        let row = RowView()
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        row.addSubview(leading)
        row.addSubview(name)
        row.addSubview(bang)
        row.addSubview(actions)
        leading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            bang.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            bang.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            actions.heightAnchor.constraint(equalToConstant: 24),
            edit.widthAnchor.constraint(equalToConstant: 40),
            delete.widthAnchor.constraint(equalToConstant: 50),
        ])
        row.onClick = { [weak self] in
            guard let self else { return }
            if self.openSlot != nil { self.closeForm(); return }   // a row click while editing just closes
            store.setDefault(engine); self.refreshHeaderValue(); self.reconcileRows()
        }
        row.onHoverChange = { hovering in actions.isHidden = !hovering }
        return row
    }

    private func makeAddRow() -> RowView {
        let plus = NSImageView()
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        plus.contentTintColor = .secondaryLabelColor
        plus.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: "Add search engine")
        name.font = .systemFont(ofSize: 13)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false

        let row = RowView()
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        row.addSubview(plus)
        row.addSubview(name)
        NSLayoutConstraint.activate([
            plus.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            plus.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        row.onClick = { [weak self] in self?.toggleAdd() }
        return row
    }

    // MARK: - In-place buttonless form

    private func toggleEdit(_ engine: SearchEngine) {
        if openSlot != nil { closeForm(); return }   // any edit/add click while a form is open closes it
        guard let slot = slots[engine.id] else { return }
        openForm(in: slot, engine: engine)
    }
    private func toggleAdd() {
        if openSlot != nil { closeForm(); return }
        openForm(in: addSlot, engine: nil)
    }

    private func openForm(in slot: NSStackView, engine: SearchEngine?) {
        let (form, liveSave, cleanup) = makeForm(for: engine)
        let collapsible = CollapsibleView(content: form, insets: NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10))
        collapsible.translatesAutoresizingMaskIntoConstraints = false
        slot.addArrangedSubview(collapsible)
        fill(collapsible, slot)
        // Settle the form's internal layout at height 0 BEFORE animating, so the reveal only grows
        // vertically (otherwise the fields animate from zero frames and sweep in from the corner).
        window?.layoutIfNeeded()
        openSlot = slot
        openLiveSave = liveSave
        openCleanup = cleanup
        openFormView = collapsible
        installFormMonitor()
        collapsible.setOpen(true)
        animate { self.dimOthers(except: slot) }   // fade the rest down
    }

    private func closeForm() {
        guard openSlot != nil, let collapsible = openFormView as? CollapsibleView else { return }
        openCleanup?()
        openSlot = nil; openLiveSave = nil; openCleanup = nil; openFormView = nil
        removeFormMonitor()
        // Reflect the (live-saved) data in the rows first, and settle the swapped rows WITHOUT
        // animation so they don't fly in from zero frames. Then roll the form up and fade the
        // dimmed rows back. No wholesale rebuild: slots stay alive, so rapid re-toggles are safe.
        refreshHeaderValue()
        reconcileRows()
        window?.layoutIfNeeded()
        collapsible.setOpen(false) { collapsible.removeFromSuperview() }
        animate {
            for s in self.slots.values + [self.addSlot] {
                s.alphaValue = 1
                (s.arrangedSubviews.first as? RowView)?.hoverEnabled = true
            }
        }
    }

    // Sync the row list with the store without destroying slots: refresh every row in place, drop rows
    // for removed engines, insert rows for new ones (in store order, before the add row).
    private func reconcileRows() {
        let store = SearchEngineStore.shared
        let engineIDs = Set(store.engines.map { $0.id })
        for (id, slot) in slots where !engineIDs.contains(id) {
            slot.removeFromSuperview()
            slots[id] = nil
        }
        for (i, engine) in store.engines.enumerated() {
            if let slot = slots[engine.id] {
                slot.arrangedSubviews.first?.removeFromSuperview()
                let row = makeRow(for: engine)
                slot.insertArrangedSubview(row, at: 0)
                fill(row, slot)
            } else {
                let slot = verticalSlot()
                let row = makeRow(for: engine)
                slot.addArrangedSubview(row)
                fill(row, slot)
                bodyStack.insertArrangedSubview(slot, at: min(i, bodyStack.arrangedSubviews.count - 1))
                fill(slot, bodyStack)
                slots[engine.id] = slot
            }
        }
    }

    private func dimOthers(except keep: NSStackView) {
        for slot in slots.values + [addSlot] {
            let isKeep = slot === keep
            slot.alphaValue = isKeep ? 1 : 0.4
            (slot.arrangedSubviews.first as? RowView)?.hoverEnabled = isKeep
        }
    }

    private func installFormMonitor() {
        formMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.closeForm(); return nil }   // escape closes (already saved live)
                return e
            }
            // Only a click outside the WHOLE component closes from here; clicks inside are handled by
            // the rows / add / edit themselves (closing here too made their mouse-up reopen the form).
            if e.window === self.window {
                let p = self.convert(e.locationInWindow, from: nil)
                if !self.bounds.contains(p) { self.closeForm() }
            }
            return e
        }
    }
    private func removeFormMonitor() {
        if let m = formMonitor { NSEvent.removeMonitor(m) }
        formMonitor = nil
    }

    // Returns the form view, a live-save closure (runs on every keystroke/toggle), and a cleanup closure
    // (drops a just-added engine left blank). nil engine == add.
    private func makeForm(for engine: SearchEngine?) -> (NSView, () -> Void, () -> Void) {
        let nameField = darkField("Name", engine?.name ?? "")
        let bangField = darkField("Bang", engine?.bang ?? "")
        bangField.field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let bangToggle = NSSwitch()
        bangToggle.state = (engine?.bangEnabled ?? true) ? .on : .off
        let searchField = darkField("Search URL (use %s for the query)", engine?.searchURL ?? "")
        let suggestField = darkField("Suggestions URL (optional)", engine?.suggestURL ?? "")

        let topRow = NSStackView(views: [nameField.container, bangField.container, bangToggle])
        topRow.spacing = 8
        topRow.distribution = .fill
        nameField.container.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [topRow, searchField.container, suggestField.container])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        fill(topRow, stack); fill(searchField.container, stack); fill(suggestField.container, stack)

        var savedID: UUID? = engine?.id   // existing engine, or nil until the add is first created
        let liveSave: () -> Void = {
            let store = SearchEngineStore.shared
            var e = savedID.flatMap { id in store.engines.first(where: { $0.id == id }) }
                ?? SearchEngine(name: "", searchURL: "")
            e.name = nameField.field.stringValue.trimmingCharacters(in: .whitespaces)
            e.searchURL = searchField.field.stringValue.trimmingCharacters(in: .whitespaces)
            e.suggestURL = suggestField.field.stringValue.isEmpty ? nil : suggestField.field.stringValue.trimmingCharacters(in: .whitespaces)
            e.bang = bangField.field.stringValue.isEmpty ? nil : bangField.field.stringValue.trimmingCharacters(in: .whitespaces)
            e.bangEnabled = bangToggle.state == .on
            if savedID == nil { store.add(e); savedID = e.id } else { store.update(e) }
        }
        let cleanup: () -> Void = {
            if engine == nil, let id = savedID,
               let created = SearchEngineStore.shared.engines.first(where: { $0.id == id }), created.name.isEmpty {
                SearchEngineStore.shared.remove(created)
            }
        }

        bangToggle.target = self
        bangToggle.action = #selector(formControlChanged)
        for f in [nameField.field, bangField.field, searchField.field, suggestField.field] { f.delegate = self }
        return (stack, liveSave, cleanup)
    }

    @objc private func formControlChanged() { openLiveSave?() }

    // MARK: - Builders

    private func darkField(_ placeholder: String, _ value: String) -> (container: NSView, field: NSTextField) {
        let c = NSView()
        c.wantsLayer = true
        c.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor   // slightly darker than the list
        c.layer?.cornerRadius = 5
        c.layer?.cornerCurve = .continuous
        c.translatesAutoresizingMaskIntoConstraints = false
        c.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let f = NSTextField(string: value)
        f.placeholderString = placeholder
        f.isBordered = false
        f.drawsBackground = false
        f.font = .systemFont(ofSize: 12)
        f.focusRingType = .none
        f.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
            f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
            f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        return (c, f)
    }

    private func fill(_ view: NSView, _ stack: NSStackView) {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func animate(_ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            changes()
            self.onLayoutChange?()
            self.window?.layoutIfNeeded()
        }, completionHandler: completion)
    }
}
