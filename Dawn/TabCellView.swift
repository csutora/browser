import AppKit
import UniformTypeIdentifiers

class TabCellView: NSView, NSDraggingSource {
    private(set) var tab: Tab
    private var isSelected: Bool
    private var isHovered: Bool = false
    private var isDragging: Bool = false

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragStarted: ((Tab) -> Void)?
    var onDragEnded: (() -> Void)?

    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let closeButton: NSButton
    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?

    init(tab: Tab, isSelected: Bool) {
        self.tab = tab
        self.isSelected = isSelected

        iconView = NSImageView()
        titleLabel = NSTextField(labelWithString: "")
        closeButton = NSButton()

        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        setupViews()
        update(tab: tab, isSelected: isSelected)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        // Title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        // Close button
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        closeButton.contentTintColor = .labelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    func update(tab: Tab, isSelected: Bool) {
        self.tab = tab
        self.isSelected = isSelected

        titleLabel.stringValue = tab.title.isEmpty ? "Untitled" : tab.title

        if tab.isSettings {
            iconView.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            iconView.contentTintColor = .secondaryLabelColor
            iconView.wantsLayer = true
            iconView.layer?.backgroundColor = nil
            iconView.layer?.cornerRadius = 0
        } else {
            // Circle().fill(Color.secondary.opacity(0.2))
            iconView.image = nil
            iconView.wantsLayer = true
            iconView.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
            iconView.layer?.cornerRadius = 8 // 8 on 16x16 = circle
        }

        updateAppearance()
    }

    private func updateAppearance() {
        // Original: isSelected ? .primary : .secondary → .labelColor / .secondaryLabelColor
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor

        // Original: Color.primary.opacity(0.1) for selected, Color.primary.opacity(0.05) for hover
        if isSelected {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        closeButton.isHidden = !(isHovered || isSelected)

        // .opacity(isDragging ? 0.5 : 1)
        alphaValue = isDragging ? 0.5 : 1.0
    }

    override func layout() {
        super.layout()
        let h = bounds.height

        // HStack(spacing: 8), padding(8)
        // Settings gear has .offset(y: -0.5) in original
        let iconY = tab.isSettings ? (h - 16) / 2 - 0.5 : (h - 16) / 2
        iconView.frame = NSRect(x: 8, y: iconY, width: 16, height: 16)

        let closeW: CGFloat = 20
        let closeX = bounds.width - closeW - 4
        closeButton.frame = NSRect(x: closeX, y: (h - 16) / 2, width: closeW, height: 16)

        let titleX: CGFloat = 32 // 8 + 16 + 8
        let titleW = closeX - titleX - 4
        titleLabel.frame = NSRect(x: titleX, y: (h - 18) / 2, width: max(0, titleW), height: 18)
    }

    // MARK: - Mouse Handling

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint = mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)

        // Check drag threshold (5px)
        let dx = currentPoint.x - downPoint.x
        let dy = currentPoint.y - downPoint.y
        guard sqrt(dx * dx + dy * dy) > 5 else { return }

        // Start drag session
        mouseDownPoint = nil
        isDragging = true
        updateAppearance()
        onDragStarted?(tab)

        let pbItem = NSPasteboardItem()
        pbItem.setString(tab.id.uuidString, forType: .string)

        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        let image = NSImage(data: dataWithPDF(inside: bounds)) ?? NSImage(size: bounds.size)
        draggingItem.setDraggingFrame(bounds, contents: image)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil

        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.contains(localPoint) && !closeButton.frame.contains(localPoint) {
            onSelect?()
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        updateAppearance()
        onDragEnded?()
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
