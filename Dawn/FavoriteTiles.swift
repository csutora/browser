import AppKit

// MARK: - Geometry

// the two shapes a tab takes in the sidebar: a row in the tab list, or a favorite's tile
enum CardShape {
    case row
    case tile

    var cornerRadius: CGFloat { self == .tile ? 10 : 8 }
    var iconSize: CGFloat { self == .tile ? FavoriteMetrics.iconSize : 16 }
}

// the favorites grid: tiles fill the width of the sidebar like the tab list, three to a row (or fewer
// where three don't fit at their narrowest), stretching to share a row when there are fewer
struct FavoriteMetrics {
    static let padH: CGFloat = 12
    static let spacing: CGFloat = 8
    static let tileH: CGFloat = 44
    static let minTileW: CGFloat = 48
    static let maxColumns = 3
    static let iconSize: CGFloat = 20

    let width: CGFloat
    let count: Int

    var columns: Int {
        let inner = width - Self.padH * 2
        let fit = max(1, Int((inner + Self.spacing) / (Self.minTileW + Self.spacing)))
        return max(1, min(count, fit, Self.maxColumns))
    }

    var tileW: CGFloat {
        (width - Self.padH * 2 - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)
    }

    var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }
    var height: CGFloat { rows == 0 ? 0 : CGFloat(rows) * Self.tileH + CGFloat(rows - 1) * Self.spacing }

    // a slot's frame in the grid's (flipped) coordinates, on whole points
    func frame(_ slot: Int) -> NSRect {
        let col = slot % columns, row = slot / columns
        let x = (Self.padH + CGFloat(col) * (tileW + Self.spacing)).rounded()
        let right = (Self.padH + CGFloat(col) * (tileW + Self.spacing) + tileW).rounded()
        return NSRect(x: x, y: CGFloat(row) * (Self.tileH + Self.spacing), width: right - x, height: Self.tileH)
    }

    // the slot under a point in the grid's coordinates, among `count` slots
    func slot(at point: NSPoint) -> Int {
        guard count > 0 else { return 0 }
        let row = max(0, min(rows - 1, Int((point.y + Self.spacing / 2) / (Self.tileH + Self.spacing))))
        let col = max(0, min(columns - 1, Int((point.x - Self.padH + Self.spacing / 2) / (tileW + Self.spacing))))
        return min(row * columns + col, count - 1)
    }
}

// which of a favorite's icons its tile shows: its icon when that has the pixels for the tile on this
// screen, otherwise its touch icon (the larger one made for home screens, shaped like one), else its icon
func tileIcon(for tab: Tab, scale: CGFloat) -> (favicon: Favicon, touch: Bool)? {
    let favicon = IconStore.shared.favicon(for: tab.iconKey)
    if let favicon, CGFloat(favicon.detail) >= FavoriteMetrics.iconSize * scale { return (favicon, false) }
    if let touch = IconStore.shared.favicon(for: tab.touchIconKey) { return (touch, true) }
    return favicon.map { ($0, false) }
}

// how far home screen icons round their corners, as a share of their size
let touchIconCornerShare: CGFloat = 0.2237

// MARK: - Favorite Tile

final class FavoriteTileView: NSView {
    private(set) var tab: Tab
    private var isSelected = false
    private var isLive = false
    private var isHovered = false
    private var isDragging = false
    private var mouseDownPoint: NSPoint?
    private(set) var mouseDownInWindow: NSPoint = .zero
    private var trackingArea: NSTrackingArea?
    private let iconView = NSImageView()
    private var shownIcon: (key: String, touch: Bool, scale: CGFloat)?

    var onSelect: (() -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?
    var onDragStart: ((FavoriteTileView, NSEvent) -> Void)?
    var onDragChanged: ((FavoriteTileView, NSEvent) -> Void)?
    var onDragEnded: ((FavoriteTileView, NSEvent) -> Void)?

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CardShape.tile.cornerRadius
        layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleNone
        iconView.wantsLayer = true
        iconView.layer?.cornerCurve = .continuous
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tab: Tab, isSelected: Bool, isLive: Bool) {
        self.tab = tab
        self.isSelected = isSelected
        self.isLive = isLive
        toolTip = tab.title.isEmpty ? tab.pinnedURL : tab.title
        refreshIcon()
        updateAppearance()
    }

    private func refreshIcon() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = FavoriteMetrics.iconSize
        if let (favicon, touch) = tileIcon(for: tab, scale: scale) {
            if shownIcon?.key != favicon.key || shownIcon?.touch != touch || shownIcon?.scale != scale {
                iconView.image = favicon.image(size: size)
                shownIcon = (favicon.key, touch, scale)
            }
            iconView.layer?.backgroundColor = nil
            iconView.layer?.cornerRadius = touch ? size * touchIconCornerShare : 0
            iconView.layer?.masksToBounds = touch
        } else {
            iconView.image = nil
            shownIcon = nil
            iconView.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
            iconView.layer?.cornerRadius = size / 2
            iconView.layer?.masksToBounds = true
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshIcon()
    }

    private func updateAppearance() {
        // a closed favorite rests quieter: it isn't running, and it'll take a moment to open
        let alpha: CGFloat = isSelected ? 0.14 : isHovered ? 0.1 : 0.05
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        iconView.alphaValue = isLive || isSelected ? 1 : 0.5
    }

    override func layout() {
        super.layout()
        let size = FavoriteMetrics.iconSize
        iconView.frame = backingAlignedRect(NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size),
                                            options: .alignAllEdgesNearest)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    func refreshHover() {
        let inside = pointerInside(self)
        guard inside != isHovered else { return }
        isHovered = inside
        updateAppearance()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(event)
    }

    // a tile in a window behind others can be picked up or chosen with the click that brings it forward
    // (and a press on it never moves the window instead)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // the tile takes every click on it, its icon included (which would otherwise turn a first click down)
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownInWindow = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging { onDragChanged?(self, event); return }
        guard let down = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.x, point.y - down.y) > 5 else { return }
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }
}

// MARK: - Drag Card

// a tab lifted out of the sidebar while it's dragged or moved: the sidebar's material with a tab's
// row or a favorite's tile drawn over it, and able to turn from one into the other as it travels
final class DragCardView: NSView {
    private(set) var shape: CardShape
    private let tab: Tab
    private let isSelected: Bool
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let titleFade = CAGradientLayer()
    private let clip = CAShapeLayer()
    private let border = CAShapeLayer()
    private let highlight = NSView()
    // the title is always as wide as it is in a row, so turning into one never shows it cut short (a
    // tile hides it by clipping)
    private var titleWidth: CGFloat

    init(tab: Tab, isSelected: Bool, appearance: NSAppearance?, shape: CardShape, size: CGSize, rowWidth: CGFloat, darken: CGFloat) {
        self.tab = tab
        self.isSelected = isSelected
        self.shape = shape
        self.titleWidth = max(1, rowWidth - 40)
        titleLabel = NSTextField(labelWithString: tab.title.isEmpty ? "Untitled" : tab.title)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        self.appearance = appearance
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.allowsEdgeAntialiasing = true
        layer?.contentsScale = scale
        // clipped by a shape layer rather than a corner radius, so corners stay smooth when the card
        // tilts in a pile; the border is stroked the same way
        layer?.mask = clip

        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        for (color, alpha) in [(NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1), 0.4), (NSColor.black, darken)] where alpha > 0 {
            let tint = NSView(frame: bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
            tint.autoresizingMask = [.width, .height]
            addSubview(tint)
        }
        highlight.frame = bounds
        highlight.wantsLayer = true
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerCurve = .continuous
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byClipping
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        titleLabel.wantsLayer = true
        titleFade.startPoint = CGPoint(x: 0, y: 0.5)
        titleFade.endPoint = CGPoint(x: 1, y: 0.5)
        titleFade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        titleLabel.layer?.mask = titleFade
        addSubview(titleLabel)
        let titleH = titleLabel.cell?.cellSize.height ?? 16
        titleLabel.frame = NSRect(x: 0, y: 0, width: titleWidth, height: titleH)
        fitTitle()

        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        border.lineWidth = 1
        border.contentsScale = scale
        border.zPosition = 1000
        layer?.addSublayer(border)

        apply(shape, size: size)
    }

    required init?(coder: NSCoder) { fatalError() }

    // the title's width (all at once, never animated, so it's never seen cut short) and its fade
    private func fitTitle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLabel.setFrameSize(NSSize(width: titleWidth, height: titleLabel.frame.height))
        titleFade.frame = titleLabel.bounds
        let fadeStart = max(0, titleWidth - 24) / titleWidth
        titleFade.locations = titleLabel.attributedStringValue.size().width > titleWidth - 24 ? [0, NSNumber(value: fadeStart), 1] : [0, 1, 1]
        CATransaction.commit()
    }

    // turns into a row or a tile of the given size, in step with whatever animation is running
    func morph(to shape: CardShape, size: CGSize, duration: TimeInterval, timing: CAMediaTimingFunction) {
        let fromClip = clip.path, fromBorder = border.path
        self.shape = shape
        // a row in a sidebar of another width has a title of that width
        if shape == .row, max(1, size.width - 40) != titleWidth {
            titleWidth = max(1, size.width - 40)
            fitTitle()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            context.allowsImplicitAnimation = true
            apply(shape, size: size)
        }
        for (layer, from) in [(clip, fromClip), (border, fromBorder)] {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = from
            animation.toValue = layer.path
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: "path")
        }
    }

    private func apply(_ shape: CardShape, size: CGSize) {
        let rect = NSRect(origin: .zero, size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.path = CGPath(roundedRect: rect, cornerWidth: shape.cornerRadius, cornerHeight: shape.cornerRadius, transform: nil)
        border.path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: shape.cornerRadius - 0.5,
                             cornerHeight: shape.cornerRadius - 0.5, transform: nil)
        CATransaction.commit()
        highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(shape == .tile && isSelected ? 0.14 : 0.05).cgColor

        let iconSize = shape.iconSize
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let icon: (favicon: Favicon, touch: Bool)?
        if shape == .tile {
            icon = tileIcon(for: tab, scale: scale)
        } else {
            icon = IconStore.shared.favicon(for: tab.iconKey).map { ($0, false) }
        }
        iconView.image = icon?.favicon.image(size: iconSize)
        iconView.layer?.backgroundColor = icon == nil ? NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor : nil
        iconView.layer?.cornerRadius = icon == nil ? iconSize / 2 : icon!.touch ? iconSize * touchIconCornerShare : 0
        iconView.layer?.masksToBounds = icon == nil || icon!.touch
        iconView.frame = shape == .tile
            ? NSRect(x: (size.width - iconSize) / 2, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize)
            : NSRect(x: 8, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize)

        // only the title's place and opacity change, never its size
        let titleH = titleLabel.frame.height
        titleLabel.setFrameOrigin(NSPoint(x: shape == .tile ? iconView.frame.maxX + 8 : 32, y: ((size.height - titleH) / 2).rounded()))
        titleLabel.alphaValue = shape == .tile ? 0 : 1
    }
}
