import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Panel Controller

// The downloads list, shown above the sidebar's downloads button. It springs open from the button,
// dismisses on outside clicks and escape, and marks downloads as seen while it's open.
final class DownloadsPanel {
    private var view: DownloadsPanelView?
    private var monitor: Any?
    private var seenWatcher: AnyCancellable?
    private var anchor: NSRect = .zero

    var isShown: Bool { view != nil }

    // clicks inside this rect (the downloads button, in window coordinates) are left to the button,
    // which toggles the panel itself
    var toggleRectInWindow: (() -> NSRect?)?

    func toggle(in root: NSView, anchor: NSRect, leadingX: CGFloat) {
        if isShown { hide() } else { show(in: root, anchor: anchor, leadingX: leadingX) }
    }

    func show(in root: NSView, anchor: NSRect, leadingX: CGFloat) {
        guard view == nil else { return }
        self.anchor = anchor
        let panel = DownloadsPanelView()
        panel.onRequestClose = { [weak self] in self?.hide() }
        panel.onHeightChange = { [weak self, weak root] in
            guard let self, let root else { return }
            self.place(animated: true, in: root, leadingX: leadingX)
        }
        root.addSubview(panel)
        view = panel
        place(animated: false, in: root, leadingX: leadingX)
        panel.animateIn(from: originInPanel(panel))

        DownloadManager.shared.markSeen()
        seenWatcher = Publishers.CombineLatest(
            DownloadManager.shared.$hasUnseenCompletion, DownloadManager.shared.$hasUnseenFailure
        )
        .receive(on: DispatchQueue.main)
        .sink { completion, failure in
            if completion || failure { DownloadManager.shared.markSeen() }
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.view else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.hide()
                    return nil
                }
                return event
            }
            guard event.window === panel.window else {
                self.hide()
                return event
            }
            let p = panel.convert(event.locationInWindow, from: nil)
            if panel.bounds.contains(p) { return event }
            if let toggle = self.toggleRectInWindow?(), toggle.contains(event.locationInWindow) { return event }
            self.hide()
            return event
        }
    }

    func hide() {
        guard let panel = view else { return }
        view = nil
        seenWatcher = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.animateOut(towards: originInPanel(panel)) {
            panel.removeFromSuperview()
            DownloadManager.shared.endSessionIfEmpty()
        }
    }

    private func originInPanel(_ panel: NSView) -> CGPoint {
        CGPoint(x: anchor.midX - panel.frame.minX, y: anchor.midY - panel.frame.minY)
    }

    private func place(animated: Bool, in root: NSView, leadingX: CGFloat) {
        guard let panel = view else { return }
        let size = panel.preferredSize
        let margin: CGFloat = 8
        var x = leadingX
        x = min(x, root.bounds.width - size.width - margin)
        x = max(margin, x)
        let y = min(anchor.maxY + 10, root.bounds.height - size.height - margin)
        let frame = NSRect(x: x, y: max(margin, y), width: size.width, height: size.height).integral
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.0, 0.4, 1.0)
                ctx.allowsImplicitAnimation = true
                panel.animator().frame = frame
                panel.layoutSubtreeIfNeeded()
            }
        } else {
            panel.frame = frame
        }
    }
}

// MARK: - Panel View

private final class DownloadsPanelView: NSView {
    var onRequestClose: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private let width: CGFloat = 320
    private let headerHeight: CGFloat = 40
    private let rowHeight: CGFloat = 52
    private let maxVisibleRows = 6
    private let listPadding: CGFloat = 6

    private let darkBg = NSView()
    private let effectView = NSVisualEffectView()
    private let borderView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Downloads")
    private let folderButton = IconButton(symbol: "folder", size: 12, tooltip: "Open Downloads Folder")
    private let clearButton = FadedTextButton(text: "Clear")
    private let divider = NSView()
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads yet")
    private var rows: [UUID: DownloadRowView] = [:]
    private var order: [UUID] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        for v in [darkBg, effectView, borderView] {
            v.wantsLayer = true
            v.layer?.cornerRadius = 12
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        darkBg.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 0.88).cgColor
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        borderView.layer?.borderWidth = 1
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        folderButton.onClick = { DownloadManager.shared.openDownloadsFolder() }
        addSubview(folderButton)

        clearButton.translatesAutoresizingMaskIntoConstraints = true
        clearButton.onAction = { DownloadManager.shared.clearInactive() }
        addSubview(clearButton)

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        addSubview(divider)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = listView
        addSubview(scrollView)

        // tracking areas only fire on pointer movement, so rows scrolling under a still pointer keep
        // stale hover states; re-check them against the real pointer whenever the list moves
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            .sink { [weak self] _ in
                self?.rows.values.forEach { $0.refreshHover() }
            }
            .store(in: &cancellables)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)

        DownloadManager.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.reconcile(items) }
            .store(in: &cancellables)

        // the aggregate republishes on every state change, which is what Clear's visibility follows
        DownloadManager.shared.$aggregate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateClearVisibility() }
            .store(in: &cancellables)
    }

    private func updateClearVisibility() {
        clearButton.isHidden = !DownloadManager.shared.items.contains { !$0.state.isActive }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    var preferredSize: NSSize {
        let count = order.count
        let listHeight: CGFloat = count == 0
            ? 64
            : CGFloat(min(count, maxVisibleRows)) * rowHeight + listPadding * 2
        return NSSize(width: width, height: headerHeight + 1 + listHeight)
    }

    override func layout() {
        super.layout()
        let b = bounds
        darkBg.frame = b
        effectView.frame = b
        borderView.frame = b

        let headerY = b.height - headerHeight
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 16, y: headerY + (headerHeight - titleLabel.frame.height) / 2)

        folderButton.frame = NSRect(x: b.width - 10 - 26, y: headerY + (headerHeight - 26) / 2, width: 26, height: 26)
        clearButton.sizeToFit()
        let clearW = clearButton.frame.width
        clearButton.frame = NSRect(
            x: folderButton.frame.minX - 4 - clearW,
            y: headerY + (headerHeight - clearButton.frame.height) / 2,
            width: clearW, height: clearButton.frame.height
        )

        divider.frame = NSRect(x: 0, y: headerY - 1, width: b.width, height: 1)
        scrollView.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, headerY - 1))
        emptyLabel.sizeToFit()
        emptyLabel.frame = NSRect(
            x: 0, y: (scrollView.frame.height - emptyLabel.frame.height) / 2,
            width: b.width, height: emptyLabel.frame.height
        )
        layoutRows(animated: false)
    }

    private func layoutRows(animated: Bool) {
        let w = scrollView.contentSize.width
        var y = listPadding
        for id in order {
            guard let row = rows[id] else { continue }
            let frame = NSRect(x: 6, y: y, width: w - 12, height: rowHeight)
            if animated && row.frame.width > 0 {
                row.animator().frame = frame
            } else {
                row.frame = frame
            }
            y += rowHeight
        }
        listView.frame = NSRect(x: 0, y: 0, width: w, height: y + listPadding)
    }

    private func reconcile(_ items: [DownloadItem]) {
        let ids = items.map(\.id)
        let previousCount = order.count
        let removed = Set(order).subtracting(ids)
        for id in removed {
            rows[id]?.removeFromSuperview()
            rows[id] = nil
        }
        var inserted: [DownloadRowView] = []
        for item in items where rows[item.id] == nil {
            let row = DownloadRowView(item: item)
            row.onOpen = { [weak self] in self?.onRequestClose?() }
            rows[item.id] = row
            listView.addSubview(row)
            inserted.append(row)
        }
        order = ids
        emptyLabel.isHidden = !order.isEmpty
        updateClearVisibility()
        layoutRows(animated: previousCount > 0)
        for row in inserted where previousCount > 0 { row.animateIn() }
        if order.count != previousCount { onHeightChange?() }
        needsLayout = true
    }

    // MARK: Animation

    func animateIn(from origin: CGPoint) {
        guard let layer else { return }
        let start = scaled(0.9, about: origin)
        let spring = CASpringAnimation(perceptualDuration: 0.34, bounce: 0.2)
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "open")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        layer.add(fade, forKey: "fade")
    }

    func animateOut(towards origin: CGPoint, completion: @escaping () -> Void) {
        guard let layer else { completion(); return }
        let end = scaled(0.94, about: origin)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: end)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [shrink, fade]
        group.duration = 0.13
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        layer.add(group, forKey: "close")
        CATransaction.commit()
    }

    // a uniform scale about a point in the layer's own coordinates (view layers anchor at their origin)
    private func scaled(_ s: CGFloat, about p: CGPoint) -> CATransform3D {
        var t = CATransform3DMakeTranslation(p.x, p.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -p.x, -p.y, 0)
    }
}

// MARK: - Row

private final class DownloadRowView: NSView, NSDraggingSource {
    let item: DownloadItem
    var onOpen: (() -> Void)?

    private let background = NSView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let actionButton = IconButton(symbol: "xmark", size: 10, tooltip: nil)
    private var cancellable: AnyCancellable?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var mouseDownPoint: NSPoint?
    private var iconKey = ""
    private var shownState: DownloadItem.State?
    private var shownActive: Bool?
    private var isIndeterminate = false

    init(item: DownloadItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true

        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        addSubview(background)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        addSubview(statusLabel)

        progressTrack.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        progressTrack.cornerRadius = 1.5
        progressTrack.masksToBounds = true
        progressFill.backgroundColor = NSColor.white.withAlphaComponent(0.78).cgColor
        progressFill.cornerRadius = 1.5
        progressFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressTrack.addSublayer(progressFill)
        layer?.addSublayer(progressTrack)

        actionButton.onClick = { [weak self] in self?.performAction() }
        addSubview(actionButton)

        cancellable = item.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsRefresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var refreshScheduled = false

    // objectWillChange fires before the new values land; refresh on the next turn
    private func needsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        background.frame = b
        iconView.frame = NSRect(x: 10, y: (b.height - 32) / 2, width: 32, height: 32)
        let textX: CGFloat = 52
        let actionSize: CGFloat = 24
        actionButton.frame = NSRect(x: b.width - 10 - actionSize, y: (b.height - actionSize) / 2, width: actionSize, height: actionSize)
        let textW = max(0, actionButton.frame.minX - 8 - textX)
        nameLabel.frame = NSRect(x: textX, y: b.height / 2 + 2, width: textW, height: 17)
        // the bar sits between the two lines while downloading; the status line takes its place after
        let statusY = item.state.isActive ? b.height / 2 - 20 : b.height / 2 - 18
        statusLabel.frame = NSRect(x: textX, y: statusY, width: textW, height: 15)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // labels inset their glyphs by the text container's 2pt padding; the bar lines up with the text
        progressTrack.frame = NSRect(x: textX + 2, y: b.height / 2 - 2.5, width: max(0, textW - 4), height: 3)
        layoutFill(animated: false)
        CATransaction.commit()
    }

    private func layoutFill(animated: Bool) {
        let w = progressTrack.bounds.width
        if isIndeterminate {
            progressFill.bounds = CGRect(x: 0, y: 0, width: w * 0.3, height: 3)
            progressFill.position = CGPoint(x: 0, y: 1.5)
            return
        }
        let target = CGRect(x: 0, y: 0, width: max(3, w * item.fractionCompleted), height: 3)
        progressFill.position = CGPoint(x: 0, y: 1.5)
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            progressFill.bounds = target
            CATransaction.commit()
        } else {
            progressFill.bounds = target
        }
    }

    private func refresh() {
        nameLabel.stringValue = item.filename
        statusLabel.stringValue = DownloadFormat.status(for: item)
        let active = item.state.isActive
        let dimmed = item.state == .cancelled || (item.state == .finished && !item.fileExists)
        nameLabel.alphaValue = dimmed ? 0.55 : 1
        if case .failed = item.state {
            statusLabel.textColor = NSColor.systemRed.withAlphaComponent(0.9)
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }

        progressTrack.isHidden = !active
        if shownActive != active {
            shownActive = active
            needsLayout = true
        }

        let indeterminate = active && !item.hasKnownSize
        if indeterminate != isIndeterminate {
            isIndeterminate = indeterminate
            progressFill.removeAnimation(forKey: "sweep")
            if indeterminate {
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = -progressTrack.bounds.width * 0.3
                sweep.toValue = progressTrack.bounds.width
                sweep.duration = 1.15
                sweep.repeatCount = .infinity
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                progressFill.add(sweep, forKey: "sweep")
            }
        }
        layoutFill(animated: true)

        updateIcon()
        if shownState != item.state {
            shownState = item.state
            switch item.state {
            case .preparing, .downloading:
                actionButton.setSymbol("xmark", size: 10, tooltip: "Stop")
                actionButton.isHidden = false
            case .finished:
                actionButton.setSymbol("magnifyingglass", size: 11, tooltip: "Show in Finder")
                actionButton.isHidden = !item.fileExists
            case .failed, .cancelled:
                actionButton.setSymbol("arrow.clockwise", size: 11, tooltip: "Retry")
                actionButton.isHidden = !item.canRetry
            }
        }
        setAccessibilityLabel("\(item.filename), \(statusLabel.stringValue)")
    }

    private func updateIcon() {
        let key: String
        let image: NSImage
        if item.state == .finished, let url = item.finalURL, item.fileExists {
            key = "file:" + url.path
            guard key != iconKey else { return }
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            let ext = (item.filename as NSString).pathExtension
            key = "type:" + ext
            guard key != iconKey else { return }
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        iconKey = key
        iconView.image = image
    }

    private func performAction() {
        let manager = DownloadManager.shared
        switch item.state {
        case .preparing, .downloading: manager.cancel(item)
        case .finished: manager.reveal(item)
        case .failed, .cancelled: manager.retry(item)
        }
    }

    func animateIn() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        layer.add(fade, forKey: "fadeIn")
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    func refreshHover() {
        let inside = pointerInside(self)
        if inside != isHovered { setHover(inside) }
        actionButton.refreshHover()
    }

    private func setHover(_ hovered: Bool, pressed: Bool = false) {
        isHovered = hovered
        let alpha: CGFloat = pressed ? 0.1 : (hovered ? 0.06 : 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = hovered ? 0.08 : 0.18
            ctx.allowsImplicitAnimation = true
            background.layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        setHover(true, pressed: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, item.state == .finished, let url = item.finalURL, item.fileExists else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        setHover(isHovered)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(iconView.frame, contents: iconView.image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let wasClick = mouseDownPoint != nil
        mouseDownPoint = nil
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setHover(inside)
        guard wasClick, inside, item.state == .finished, item.fileExists else { return }
        DownloadManager.shared.open(item)
        onOpen?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    // MARK: Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let manager = DownloadManager.shared
        func add(_ title: String, _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, handler: action)
            menu.addItem(entry)
        }
        switch item.state {
        case .finished:
            if item.fileExists {
                add("Open") { [weak self] in
                    guard let self else { return }
                    manager.open(self.item)
                    self.onOpen?()
                }
                add("Show in Finder") { [weak self] in if let self { manager.reveal(self.item) } }
            }
        case .preparing, .downloading:
            add("Stop") { [weak self] in if let self { manager.cancel(self.item) } }
        case .failed, .cancelled:
            if item.canRetry { add("Retry") { [weak self] in if let self { manager.retry(self.item) } } }
        }
        if let source = item.sourceURL, !source.absoluteString.hasPrefix("blob:"), !source.absoluteString.hasPrefix("data:") {
            add("Copy Download Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        if !item.state.isActive {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            add("Remove from List") { [weak self] in if let self { manager.remove(self.item) } }
        }
        return menu.items.isEmpty ? nil : menu
    }
}

// MARK: - Small Controls

// whether the real pointer is over the visible part of a view (hover tracking only sees movement).
// visibleRect isn't clipped to the view's own bounds when views don't clip, so both must hold.
func pointerInside(_ view: NSView) -> Bool {
    guard let window = view.window, window.isKeyWindow, !view.isHiddenOrHasHiddenAncestor else { return false }
    let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return view.bounds.contains(p) && view.visibleRect.contains(p)
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

// a borderless symbol button with a soft circular hover, used in the panel header and rows
final class IconButton: NSView {
    var onClick: (() -> Void)?

    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var pressed = false

    init(symbol: String, size: CGFloat, tooltip: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        setSymbol(symbol, size: size, tooltip: tooltip)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbol: String, size: CGFloat, tooltip: String?) {
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func style(hover: Bool, pressed: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.white.withAlphaComponent(pressed ? 0.16 : (hover ? 0.1 : 0)).cgColor
        }
        imageView.contentTintColor = hover ? .labelColor : .secondaryLabelColor
    }

    private var isHovered = false

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        style(hover: true, pressed: false)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        style(hover: false, pressed: false)
    }

    func refreshHover() {
        let inside = pointerInside(self)
        guard inside != isHovered, !pressed else { return }
        isHovered = inside
        style(hover: inside, pressed: false)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        style(hover: true, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        style(hover: inside, pressed: false)
        if inside { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
