import AppKit

class TabCellView: NSView {
    private(set) var tab: Tab
    private var isSelected: Bool
    private var isHovered: Bool = false
    private var isDragging: Bool = false
    // A live copy of the cell shown in the drag panel: no close button, transparent (the panel
    // provides the lifted background), but otherwise the real thing so the title fade renders.
    var isDragGhost: Bool = false { didSet { updateAppearance() } }

    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onClose: (() -> Void)?

    // Part of a multi-selection (distinct from being the active tab). Shows the hover highlight.
    var isInSelection: Bool = false { didSet { updateAppearance() } }
    // Drag: a custom mouse-driven gesture (instant, no modal-loop quirks). The controller builds the
    // pile on start, follows on change, and resolves on end; it only escalates to a system dragging
    // session if the cursor leaves the window (for dropping into other apps).
    var onDragStart: ((TabCellView, NSEvent) -> Void)?
    var onDragChanged: ((TabCellView, NSEvent) -> Void)?
    var onDragEnded: ((TabCellView, NSEvent) -> Void)?

    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let closeButton: NSButton
    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    // The original mouse-down location in window coords, so a drag anchors to where the user actually
    // clicked rather than to wherever the cursor was once the drag threshold tripped.
    private(set) var mouseDownInWindow: NSPoint = .zero

    // Instead of truncating the title with an ellipsis, the title runs full width and its right
    // edge fades to transparent via an alpha mask (no painted overlay, so it works over the
    // transparent sidebar). When the close button shows, the fade shifts left so the text is
    // already invisible underneath it.
    private let titleFadeMask: CAGradientLayer = {
        let m = CAGradientLayer()
        m.startPoint = CGPoint(x: 0, y: 0.5)
        m.endPoint = CGPoint(x: 1, y: 0.5)
        m.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        return m
    }()

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
        titleLabel.lineBreakMode = .byClipping // fade handles the overflow instead of an ellipsis
        titleLabel.maximumNumberOfLines = 1
        titleLabel.wantsLayer = true
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

        if isDragGhost {
            // The panel behind it provides the lifted background; keep the cell itself transparent.
            layer?.backgroundColor = NSColor.clear.cgColor
            closeButton.isHidden = true
        } else {
            // Selection (0.05) reads over the active's stronger 0.1, since the active stays clear via
            // its always-on close button and brighter title. 0.1 for a lone active tab, 0.05 for hover.
            let alpha: CGFloat
            if isInSelection { alpha = 0.05 }
            else if isSelected { alpha = 0.1 }
            else if isHovered { alpha = 0.05 }
            else { alpha = 0 }
            layer?.backgroundColor = alpha > 0
                ? NSColor.labelColor.withAlphaComponent(alpha).cgColor
                : NSColor.clear.cgColor
            closeButton.isHidden = !(isSelected || isHovered)
        }

        needsLayout = true // the title reclaims the close button's space when it's hidden
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
        // The title always runs full width; the fade (below), not the frame, accounts for the X.
        let titleW = max(0, bounds.width - titleX - 8)
        titleLabel.frame = NSRect(x: titleX, y: (h - 18) / 2, width: titleW, height: 18)
        updateTitleFade(titleW: titleW)
    }

    private func updateTitleFade(titleW: CGFloat) {
        guard titleW > 0 else { return }
        if titleLabel.layer?.mask !== titleFadeMask { titleLabel.layer?.mask = titleFadeMask }

        let fadeWidth: CGFloat = 24
        // End the fade at the right edge normally, or at the close button's left edge when it shows.
        let closeLeftInTitle = titleW - 16
        let fadeEnd = closeButton.isHidden ? titleW : max(0, closeLeftInTitle)
        let fadeStart = max(0, fadeEnd - fadeWidth)

        // Only fade once the text actually reaches the fade zone, so short titles stay fully opaque.
        let textWidth = titleLabel.attributedStringValue.size().width
        let needsFade = textWidth > fadeStart

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleFadeMask.frame = titleLabel.bounds
        titleFadeMask.locations = needsFade
            ? [0, NSNumber(value: Double(fadeStart / titleW)), NSNumber(value: Double(fadeEnd / titleW))]
            : [0, 1, 1]
        CATransaction.commit()
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

    // tracking areas only fire on mouse movement, so content scrolling under a
    // stationary cursor leaves stale hover states. re-check from the real pointer.
    func refreshHover() {
        var inside = false
        if let window, window.isKeyWindow {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            inside = visibleRect.contains(p)
        }
        if inside != isHovered {
            isHovered = inside
            updateAppearance()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownInWindow = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging { onDragChanged?(self, event); return }
        guard let downPoint = mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = currentPoint.x - downPoint.x
        let dy = currentPoint.y - downPoint.y
        guard sqrt(dx * dx + dy * dy) > 5 else { return }

        isDragging = true
        mouseDownPoint = nil
        onDragStart?(self, event)
        onDragChanged?(self, event)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            onDragEnded?(self, event)
            return
        }
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil

        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.contains(localPoint) && !closeButton.frame.contains(localPoint) {
            onSelect?(event.modifierFlags)
        }
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
