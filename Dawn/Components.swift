import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Resize Handle
struct ResizeHandleView: NSViewRepresentable {
    @Binding var width: Double
    @Binding var dragStartWidth: Double?
    @Binding var isResizing: Bool

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let v = ResizeHandleNSView()
        v.onDragStart = { dragStartWidth = width; isResizing = true }
        v.onDragUpdate = { delta in if let start = dragStartWidth { width = Double(max(220, min(600, start + delta))) } }
        v.onDragEnd = { dragStartWidth = nil; isResizing = false }
        return v
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {}

    class ResizeHandleNSView: NSView {
        var onDragStart: (() -> Void)?
        var onDragUpdate: ((CGFloat) -> Void)?
        var onDragEnd: (() -> Void)?

        private var startX: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) {
            self.window?.isMovableByWindowBackground = false
            startX = event.locationInWindow.x
            onDragStart?()
        }
        override func mouseDragged(with event: NSEvent) {
            let delta = event.locationInWindow.x - startX
            onDragUpdate?(delta)
        }
        override func mouseUp(with event: NSEvent) {
            onDragEnd?()
            self.window?.isMovableByWindowBackground = true
        }
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) { NSColor(white: 1, alpha: 0.0001).set(); dirtyRect.fill() }
    }
}

// MARK: - Navigation Button
struct NavButton: View {
    let icon: String
    let action: () -> Void
    let disabled: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear.frame(width: 24, height: 24)
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(disabled ? .secondary.opacity(0.4) : .secondary)
                    .frame(width: 12, height: 12, alignment: .center)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled)
    }
}

// MARK: - Tab Drop Delegate
struct TabDropDelegate: DropDelegate {
    let tab: Tab
    var tabs: [Tab]
    @Binding var draggedTab: Tab?

    func performDrop(info: DropInfo) -> Bool { draggedTab = nil; return true }

    func dropEntered(info: DropInfo) {
        guard let d = draggedTab, d != tab else { return }
        guard let from = tabs.firstIndex(of: d), let to = tabs.firstIndex(of: tab) else { return }
        var mutableTabs = tabs
        mutableTabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        for (index, item) in mutableTabs.enumerated() { item.sortIndex = index }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

// MARK: - Draggable Tab
struct DraggableTab<Content: View>: NSViewRepresentable {
    let tab: Tab
    @Binding var draggedTab: Tab?
    let content: Content

    init(tab: Tab, draggedTab: Binding<Tab?>, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self._draggedTab = draggedTab
        self.content = content()
    }

    func makeNSView(context: Context) -> DraggableContainerView<Content> {
        let view = DraggableContainerView(rootView: content)
        view.tab = tab
        view.draggedTabBinding = _draggedTab
        return view
    }

    func updateNSView(_ view: DraggableContainerView<Content>, context: Context) {
        view.update(rootView: content)
        view.tab = tab
        view.draggedTabBinding = _draggedTab
    }
}

class DraggableContainerView<Content: View>: NSView, NSDraggingSource {
    private var hostingView: NSHostingView<Content>?
    var tab: Tab?
    var draggedTabBinding: Binding<Tab?>?

    init(rootView: Content) {
        super.init(frame: .zero)
        let hv = NSHostingView(rootView: rootView)
        hv.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(hv)
        self.hostingView = hv
        NSLayoutConstraint.activate([
            hv.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            hv.topAnchor.constraint(equalTo: self.topAnchor),
            hv.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(rootView: Content) { hostingView?.rootView = rootView }

    override func mouseDragged(with event: NSEvent) {
        guard let tab = tab else { super.mouseDragged(with: event); return }
        let pbItem = NSPasteboardItem()
        pbItem.setString(tab.id.uuidString, forType: NSPasteboard.PasteboardType(UTType.text.identifier))
        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        let rect = self.bounds
        let image = NSImage(data: self.dataWithPDF(inside: rect)) ?? NSImage(size: rect.size)
        draggingItem.setDraggingFrame(rect, contents: image)
        let session = self.beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        DispatchQueue.main.async { self.draggedTabBinding?.wrappedValue = tab }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { self.draggedTabBinding?.wrappedValue = nil }
    }
}

// MARK: - Extensions
extension Animation {
    static let sidebarSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

extension Color {
    static func from(dict: [String: Double]) -> Color {
        let r = dict["r"] ?? 255
        let g = dict["g"] ?? 255
        let b = dict["b"] ?? 255
        let a = dict["a"] ?? 1.0
        return Color(red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
    }
}
