import AppKit

class ResizeHandleNSView: NSView {
    var onDragStart: (() -> Void)?
    var onDragUpdate: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private var startX: CGFloat = 0

    private var lastUpdateTime: CFTimeInterval = 0
    private let updateInterval: CFTimeInterval = 1.0 / 60.0

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        self.window?.isMovableByWindowBackground = false
        startX = event.locationInWindow.x
        lastUpdateTime = 0
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = CACurrentMediaTime()
        guard now - lastUpdateTime >= updateInterval else { return }
        lastUpdateTime = now

        let delta = event.locationInWindow.x - startX
        onDragUpdate?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        let delta = event.locationInWindow.x - startX
        onDragUpdate?(delta)
        onDragEnd?()
        self.window?.isMovableByWindowBackground = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.0001).set()
        dirtyRect.fill()
    }
}
