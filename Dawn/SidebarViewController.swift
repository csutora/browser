import AppKit
import Combine

// MARK: - Sidebar Delegate Protocol

protocol SidebarDelegate: AnyObject {
    var currentTabId: UUID? { get }
    func sidebarDidSelectTab(_ tab: Tab)
    func sidebarDidRequestCloseTab(_ tab: Tab)
    func sidebarDidRequestNewTab()
    func sidebarDidToggleDock()
    func sidebarDidRequestBack()
    func sidebarDidRequestForward()
    func sidebarDidRequestReload()
    func sidebarDidSubmitURL(_ url: String)
    func sidebarDidReorderTabs(_ orderedTabIds: [UUID])
    // Drop landed outside this window's list: commit the move and return the destination window's
    // sidebar to adopt the live pile (cross-window / tear-off), or nil to spring the pile home.
    func sidebarHandOffPile(_ ids: [UUID], at screenPoint: CGPoint) -> SidebarViewController?
    // The pile moved (screen coords): reveal / make space in whatever window the cursor is over.
    func sidebarTabDragMoved(toScreen screenPoint: CGPoint, ids: [UUID])
    // The drag ended: clear any cross-window reveal / gap.
    func sidebarTabDragEnded()
}

// MARK: - Sidebar View Controller

class SidebarViewController: NSViewController {
    let tabManager: TabManager
    weak var delegate: SidebarDelegate?

    // Public for MainWindowController to set canHover
    var trafficLights: TrafficLightsContainerView!

    // Views
    private var headerView: NSView!
    private var dockButton: NSButton!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var urlContainer: NSView!
    private var searchIcon: NSImageView!
    private var urlBar: NSTextField!
    private var dividerView: NSView!
    private var scrollView: NSScrollView!
    private var tabListView: TabListDropView!
    private var footerView: NSView!
    private var newTabButton: NSButton!

    // State
    private var tabs: [Tab] = []
    private var tabCellViews: [UUID: TabCellView] = [:]
    private var isUrlFieldFocused = false
    private var focusObserver: Any?
    private var unfocusObserver: Any?
    private var focusURLBarObserver: Any?

    // Ephemeral multi-selection (separate from the active tab). cmd/shift-click build it; a plain
    // click / drag-unselected / close / esc / empty-area click clear it back to a single tab.
    private var selectedTabIds: Set<UUID> = []
    private var selectionAnchorId: UUID?
    private var escMonitor: Any?

    // Drag state. Every reorder - one tab or a whole multi-selection - is a "pile" of N>=1 real tab
    // cards lifted into a full-screen click-through overlay. A pile container view is translated to
    // follow the cursor, while each card springs from its list slot into the pile on pickup and back
    // out to its new slot on drop. A single tab is just a pile of one. nil when no drag is running.
    private var drag: DragSession?

    // A pile dragged from ANOTHER window hovering this list (cross-window drop): the slot the incoming
    // tabs would land at, opening a make-space gap. nil when no foreign pile is over this list.
    private var foreignDragActive = false
    private var foreignGapSlot: Int?
    private var foreignGap: Int? { foreignDragActive ? foreignGapSlot : nil }

    private final class DragSession {
        let ids: [UUID]               // tabs being dragged, in list order
        var insertion: Int            // target slot among the non-dragged tabs
        var overBar: Bool             // cursor currently over the list
        var dropping = false          // committed: stop excluding the ids from the list layout
        let grabOffsetListY: CGFloat  // grab point's offset within the grabbed cell (list coords)
        let pickupCursor: CGPoint     // screen point of the original mouse-down (the grab anchor)
        let panelOrigin: CGPoint      // overlay panel origin in screen coords
        let panel: NSPanel            // full-screen click-through overlay holding the cards
        let container: NSView         // pile container, translated to follow the cursor
        var cards: [PileCard]

        init(ids: [UUID], insertion: Int, overBar: Bool, grabOffsetListY: CGFloat, pickupCursor: CGPoint,
             panelOrigin: CGPoint, panel: NSPanel, container: NSView, cards: [PileCard]) {
            self.ids = ids; self.insertion = insertion; self.overBar = overBar
            self.grabOffsetListY = grabOffsetListY; self.pickupCursor = pickupCursor
            self.panelOrigin = panelOrigin; self.panel = panel; self.container = container; self.cards = cards
        }
    }

    private struct PileCard {
        let id: UUID
        // Two views on purpose: position lives on `outer` (frame stays clean and settable), tilt lives
        // on `inner` via frameCenterRotation. AppKit owns layer.transform on layer-backed views, so a
        // single-view collapse can't hold a raw rotation - the split is the clean way to isolate them.
        let outer: NSView
        let inner: NSView
        let homeOrigin: CGPoint
        let startOrigin: CGPoint
        let rotationDeg: CGFloat
        let hidden: Bool       // beyond the 5-card cap: gathers, then fades out
    }

    // Tabs lifted out of the list during a drag, laid out around a single gap at the insertion slot.
    private var reorderExcludedIds: Set<UUID> {
        guard let drag = drag, !drag.dropping else { return [] }
        return Set(drag.ids)
    }

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = SidebarBackgroundView()
        container.wantsLayer = true

        // Header
        headerView = NSView()
        headerView.wantsLayer = true
        container.addSubview(headerView)

        // Traffic lights
        trafficLights = TrafficLightsContainerView(frame: NSRect(x: 0, y: 0, width: 58, height: 16))
        headerView.addSubview(trafficLights)

        // Dock button (12pt medium, not semibold like nav buttons)
        dockButton = makeButton(symbolName: "sidebar.left", size: 12, weight: .medium)
        dockButton.target = self
        dockButton.action = #selector(toggleDock)
        headerView.addSubview(dockButton)

        // Nav buttons
        backButton = makeButton(symbolName: "chevron.left", size: 11)
        backButton.target = self
        backButton.action = #selector(goBack)
        headerView.addSubview(backButton)

        forwardButton = makeButton(symbolName: "chevron.right", size: 11)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        headerView.addSubview(forwardButton)

        reloadButton = makeButton(symbolName: "arrow.clockwise", size: 11)
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage)
        headerView.addSubview(reloadButton)

        // URL bar container
        urlContainer = NSView()
        urlContainer.wantsLayer = true
        urlContainer.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.2).cgColor
        urlContainer.layer?.cornerRadius = 8
        urlContainer.layer?.cornerCurve = .continuous
        urlContainer.layer?.borderWidth = 1
        urlContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
        container.addSubview(urlContainer)

        searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        urlContainer.addSubview(searchIcon)

        urlBar = NSTextField()
        let urlCell = VerticallyCenteredTextFieldCell()
        urlCell.isEditable = true
        urlCell.isSelectable = true
        urlCell.wraps = false
        urlCell.isScrollable = true
        urlBar.cell = urlCell
        urlBar.isBordered = false
        urlBar.drawsBackground = false
        urlBar.focusRingType = .none
        urlBar.font = .systemFont(ofSize: 13)
        urlBar.textColor = .white
        urlBar.placeholderString = "Search"
        urlBar.delegate = self
        urlContainer.addSubview(urlBar)

        // Divider
        dividerView = NSView()
        dividerView.wantsLayer = true
        // Original: Divider().opacity(0.3) — SwiftUI Divider already has built-in low opacity
        dividerView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        container.addSubview(dividerView)

        // Scroll view for tab list
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        container.addSubview(scrollView)

        tabListView = TabListDropView()
        tabListView.wantsLayer = true
        scrollView.documentView = tabListView

        // Footer
        footerView = SidebarBackgroundView()
        footerView.wantsLayer = true
        container.addSubview(footerView)

        newTabButton = NSButton()
        newTabButton.isBordered = false
        newTabButton.title = "New Tab"
        newTabButton.font = .systemFont(ofSize: 12)
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        newTabButton.imagePosition = .imageLeading
        newTabButton.imageHugsTitle = true
        newTabButton.alignment = .left
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        footerView.addSubview(newTabButton)

        // Observe URL field focus changes for border color
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSTextField.textDidBeginEditingNotification,
            object: urlBar, queue: .main
        ) { [weak self] _ in
            self?.isUrlFieldFocused = true
            self?.updateUrlBarBorder()
        }
        unfocusObserver = NotificationCenter.default.addObserver(
            forName: NSTextField.textDidEndEditingNotification,
            object: urlBar, queue: .main
        ) { [weak self] _ in
            self?.isUrlFieldFocused = false
            self?.updateUrlBarBorder()
        }

        // Original: .onReceive(NotificationCenter.default.publisher(for: .focusURLBar))
        focusURLBarObserver = NotificationCenter.default.addObserver(
            forName: .focusURLBar, object: nil, queue: .main
        ) { [weak self] _ in
            self?.focusURLBar()
        }

        // Tap on tab list or sidebar background unfocuses URL bar
        // Original: .onTapGesture { isUrlFieldFocused = false }
        tabListView.onTapped = { [weak self] in
            self?.unfocusURLBar()
            self?.clearMultiSelection()
        }

        // Local keys for the tab selection: esc clears a multi-selection; cmd-C copies the selected
        // tabs as markdown links (one per line, list order), unless a text field is being edited.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53, self.selectedTabIds.count > 1 {
                self.clearMultiSelection()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c",
               !self.selectedTabIds.isEmpty, !self.isEditingText {
                self.copySelectedTabsAsMarkdown()
                return nil
            }
            return event
        }

        self.view = container
    }

    deinit {
        if let obs = focusObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = unfocusObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = focusURLBarObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = escMonitor { NSEvent.removeMonitor(obs) }
    }

    func focusURLBar() {
        view.window?.makeFirstResponder(urlBar)
    }

    func unfocusURLBar() {
        view.window?.makeFirstResponder(nil)
    }

    private func updateUrlBarBorder() {
        urlContainer.layer?.borderColor = NSColor.white.withAlphaComponent(isUrlFieldFocused ? 0.5 : 0.05).cgColor
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSidebar()
    }

    // MARK: - Layout

    private func layoutSidebar() {
        let bounds = view.bounds
        let w = bounds.width

        // Header (top)
        let headerH: CGFloat = 44
        headerView.frame = NSRect(x: 0, y: bounds.height - headerH, width: w, height: headerH)

        // Original padding: .leading 14, .trailing 8, .top 8, .bottom 12
        // Content area: from y=12 to y=36 (height 24)
        let contentBottom: CGFloat = 12
        let contentAreaH: CGFloat = 24

        // Traffic lights centered in content area
        trafficLights.frame = NSRect(
            x: 13, // 14 - 1 (original has .offset(x: -1))
            y: contentBottom + (contentAreaH - 16) / 2,
            width: 58, height: 16
        )

        // Dock button - after traffic lights with spacing 8
        dockButton.frame = NSRect(
            x: 14 + 58 + 8,
            y: contentBottom + (contentAreaH - 24) / 2,
            width: 24, height: 24
        )

        // Nav buttons (right side, trailing padding 8, spacing 4)
        let navY = contentBottom + (contentAreaH - 24) / 2
        reloadButton.frame = NSRect(x: w - 8 - 24, y: navY, width: 24, height: 24)
        forwardButton.frame = NSRect(x: w - 8 - 24 - 4 - 24, y: navY, width: 24, height: 24)
        backButton.frame = NSRect(x: w - 8 - 24 - 4 - 24 - 4 - 24, y: navY, width: 24, height: 24)

        // URL bar: .padding(10) inner, .padding(.horizontal, 12).padding(.bottom, 10) outer
        // Inner padding 10 → total height = textField(~16) + 20 = ~36
        let urlBarInnerPad: CGFloat = 10
        let urlBarH: CGFloat = 36 // ~16pt text + 20 padding
        let urlBarY = bounds.height - headerH - urlBarH
        urlContainer.frame = NSRect(x: 12, y: urlBarY, width: w - 24, height: urlBarH)

        // Search icon: 16x16 with equal padding
        searchIcon.frame = NSRect(x: urlBarInnerPad, y: (urlBarH - 16) / 2, width: 16, height: 16)

        // Text field: icon (16) + spacing (8) from icon. Full container height with a
        // vertically-centering cell so the text sits on the same line as the icon.
        let textFieldX = urlBarInnerPad + 16 + 8
        let urlFieldH: CGFloat = 24
        urlBar.frame = NSRect(
            x: textFieldX,
            y: (urlBarH - urlFieldH) / 2,
            width: urlContainer.frame.width - textFieldX - urlBarInnerPad,
            height: urlFieldH
        )

        // Divider: centered between URL bar bottom and tab list top
        let dividerY = urlBarY - 14
        dividerView.frame = NSRect(x: 0, y: dividerY, width: w, height: 1)

        // Footer (bottom): new-tab button in the bottom-left corner with equal insets that
        // match the tab list / URL bar horizontal inset (12). Size the button tightly to its
        // content so the visible bottom inset equals the left inset (no centering gap).
        let footerInset: CGFloat = 12
        newTabButton.sizeToFit()
        let newTabH = newTabButton.frame.height
        let footerH: CGFloat = footerInset + newTabH + footerInset
        footerView.frame = NSRect(x: 0, y: 0, width: w, height: footerH)
        newTabButton.frame = NSRect(x: footerInset, y: footerInset, width: newTabButton.frame.width, height: newTabH)

        // Scroll view (between divider and footer)
        let scrollY = footerH
        let scrollH = max(0, dividerY - 1 - scrollY)
        scrollView.frame = NSRect(x: 0, y: scrollY, width: w, height: scrollH)

        // Layout tab cells in document view
        layoutTabCells()
    }

    // Tab list geometry. padH matches the URL bar's inset (12) so cells line up with it.
    private struct TabMetrics {
        let padH: CGFloat = 12
        let padV: CGFloat = 10
        let cellH: CGFloat = 32 // HStack padding 8 top/bottom + 16pt content
        let spacing: CGFloat = 2
        var rowH: CGFloat { cellH + spacing }
        var baseY: CGFloat { padV + 1 } // Color.clear.frame(height: 1) spacer
        let width: CGFloat
        var cellW: CGFloat { width - padH * 2 }
        func slotY(_ slot: Int) -> CGFloat { baseY + CGFloat(slot) * rowH }
    }

    private func tabMetrics() -> TabMetrics {
        // Use the sidebar's own bounds width, valid as soon as the view is sized via autoresizing.
        TabMetrics(width: view.bounds.width)
    }

    private func layoutTabCells(animated: Bool = false) {
        let m = tabMetrics()

        let foreignGapIndex = self.foreignGap
        let excluded = self.reorderExcludedIds
        let apply = {
            if !excluded.isEmpty {
                let others = self.tabs.filter { !excluded.contains($0.id) }
                if self.drag?.overBar ?? false {
                    // Make-space: lay the other cells into every slot except the single gap the
                    // dragged pile hovers over. The pile cards follow the cursor.
                    var slot = 0
                    for tab in others {
                        if slot == (self.drag?.insertion ?? 0) { slot += 1 }
                        self.tabCellViews[tab.id]?.frame = NSRect(
                            x: m.padH, y: m.slotY(slot), width: m.cellW, height: m.cellH
                        )
                        slot += 1
                    }
                } else {
                    // Dragged off the list: close the gap and lay the rest out contiguously.
                    for (index, tab) in others.enumerated() {
                        self.tabCellViews[tab.id]?.frame = NSRect(
                            x: m.padH, y: m.slotY(index), width: m.cellW, height: m.cellH
                        )
                    }
                }
            } else if let gap = foreignGapIndex {
                // A pile from another window is hovering this list: open a single gap at `gap` so the
                // incoming tabs land there, exactly like an in-window make-space.
                for (index, tab) in self.tabs.enumerated() {
                    let slot = index >= gap ? index + 1 : index
                    self.tabCellViews[tab.id]?.frame = NSRect(
                        x: m.padH, y: m.slotY(slot), width: m.cellW, height: m.cellH
                    )
                }
            } else {
                for (index, tab) in self.tabs.enumerated() {
                    self.tabCellViews[tab.id]?.frame = NSRect(
                        x: m.padH, y: m.slotY(index), width: m.cellW, height: m.cellH
                    )
                }
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }

        let totalH = m.slotY(tabs.count + (foreignGapIndex != nil ? 1 : 0)) + m.padV
        tabListView.frame = NSRect(x: 0, y: 0, width: m.width, height: max(totalH, scrollView.frame.height))
    }

    // MARK: - Helpers

    private func makeButton(symbolName: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        button.contentTintColor = .secondaryLabelColor
        button.setFrameSize(NSSize(width: 24, height: 24))
        return button
    }

    // MARK: - Actions

    @objc func toggleDock() { delegate?.sidebarDidToggleDock() }
    @objc func goBack() { delegate?.sidebarDidRequestBack() }
    @objc func goForward() { delegate?.sidebarDidRequestForward() }
    @objc func reloadPage() { delegate?.sidebarDidRequestReload() }
    @objc func newTabClicked() { delegate?.sidebarDidRequestNewTab() }

    // MARK: - Public API

    func reloadTabs(_ newTabs: [Tab]) {
        self.tabs = newTabs
        rebuildTabList()
        view.needsLayout = true
    }

    func updateTab(_ tabId: UUID) {
        guard let cell = tabCellViews[tabId],
              let tab = tabs.first(where: { $0.id == tabId }) else { return }
        cell.update(tab: tab, isSelected: delegate?.currentTabId == tab.id)
    }

    func updateSelection() {
        for tab in tabs {
            tabCellViews[tab.id]?.update(tab: tab, isSelected: delegate?.currentTabId == tab.id)
        }
    }

    func updateURLBar(_ url: String) {
        urlBar.stringValue = url
    }

    func updateNavState(for browserState: BrowserState?) {
        let canBack = browserState?.canGoBack ?? false
        let canForward = browserState?.canGoForward ?? false
        let loading = browserState?.isLoading ?? false

        backButton.isEnabled = canBack
        backButton.contentTintColor = canBack ? .secondaryLabelColor : .secondaryLabelColor.withAlphaComponent(0.4)

        forwardButton.isEnabled = canForward
        forwardButton.contentTintColor = canForward ? .secondaryLabelColor : .secondaryLabelColor.withAlphaComponent(0.4)

        reloadButton.image = NSImage(
            systemSymbolName: loading ? "xmark" : "arrow.clockwise",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    func updateDockState(_ isDocked: Bool) {
        trafficLights.canHover = isDocked
    }

    // MARK: - Reorder Drag
    //
    // One pick-up-and-make-space gesture for everything. A single tab and a multi-selection are the
    // same "pile" of N>=1 real tab cards, lifted into a full-screen click-through overlay. A pile
    // container is translated to follow the cursor while the other cells animate open a gap; on drop
    // the cards spring into their new slots and dissolve into the real cells. Centralised here so the
    // future tear-out-to-new-window / drop-on-edge-to-split behaviours can hook the same gesture.

    private func tabDragBegan(_ cell: TabCellView, _ event: NSEvent) {
        // A multi-selection that includes the grabbed tab drags the whole selection; otherwise it's a
        // lone tab (which clears any selection). Either way it's the same pile drag, just N == 1.
        let ids: [UUID]
        if selectedTabIds.count > 1 && selectedTabIds.contains(cell.tab.id) {
            ids = tabs.filter { selectedTabIds.contains($0.id) }.map { $0.id }
        } else {
            clearMultiSelection()
            ids = [cell.tab.id]
        }
        beginPileDrag(grabbed: cell, ids: ids)
    }

    private func tabDragChanged(_ cell: TabCellView, _ event: NSEvent) {
        guard let window = view.window else { return }
        pileDragMoved(toScreen: window.convertPoint(toScreen: event.locationInWindow))
    }

    private func tabDragEnded(_ cell: TabCellView, _ event: NSEvent) {
        guard let drag = drag, let window = view.window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        delegate?.sidebarTabDragEnded()   // clear cross-window reveal / gaps, whatever the outcome

        // Dropped on my own list -> the standard reorder drop, right here.
        if drag.overBar {
            pileDragEnded(commit: true)
            return
        }
        // Dropped over another window's list / outside all windows: the manager commits the model move
        // and hands back the destination sidebar, which adopts THIS live pile and runs the exact same
        // drop. So every window catches a dropped pile identically. nil -> nothing valid: spring home.
        if let dest = delegate?.sidebarHandOffPile(drag.ids, at: screenPoint), dest !== self {
            self.drag = nil               // ownership of the overlay + cards transfers to dest
            dest.adoptPile(drag)
            return
        }
        pileDragEnded(commit: false)      // spring back to where the tabs started
    }

    // Catch a live pile handed off from another window (or a freshly torn-off one). The dragged tabs
    // already belong to this window's model now, so run the identical drop: scatter the cards into our
    // slots and dissolve them into the real cells. This is why a cross-window drop looks exactly like an
    // in-window one - it IS the same code, just on the window the pile landed on.
    private func adoptPile(_ session: DragSession) {
        clearForeignDrag()
        drag = session
        for id in session.ids { tabCellViews[id]?.alphaValue = 0 }   // the scatter dissolves into them
        pileDragEnded(commit: false)   // the move is already committed; just animate into place
    }

    // The slot the dragged tabs would insert at if dropped over this list, else nil (point not over it).
    func tabListInsertionIndex(atScreen screenPoint: CGPoint) -> Int? {
        guard let window = view.window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard scrollView.frame.contains(view.convert(windowPoint, from: nil)) else { return nil }
        let m = tabMetrics()
        let listY = tabListView.convert(windowPoint, from: nil).y
        return max(0, min(Int(((listY - m.slotY(0)) / m.rowH).rounded()), tabs.count))
    }

    // MARK: - Foreign drag (a pile from another window hovering this one)

    func beginForeignDrag() {
        foreignDragActive = true
        foreignGapSlot = nil
        layoutTabCells(animated: true)
    }

    func updateForeignGap(_ slot: Int?) {
        guard foreignDragActive, slot != foreignGapSlot else { return }
        foreignGapSlot = slot
        layoutTabCells(animated: true)
    }

    func endForeignDrag() {
        guard foreignDragActive else { return }
        foreignDragActive = false
        foreignGapSlot = nil
        layoutTabCells(animated: true)
    }

    // Drop the phantom-gap flag without re-laying-out (the real moved cells take over immediately).
    func clearForeignDrag() {
        foreignDragActive = false
        foreignGapSlot = nil
    }

    private func beginPileDrag(grabbed cell: TabCellView, ids: [UUID]) {
        guard let window = view.window else { return }
        // Span every display so the pile stays visible across monitors: the whole gesture works in
        // global screen coordinates already, so one canvas over the union of all screens is all it
        // takes. Computed once here, so it just scales to however many monitors are attached.
        let screenFrame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        guard !screenFrame.isEmpty else { return }
        let m = tabMetrics()
        let cardSize = CGSize(width: m.cellW, height: m.cellH)
        let idSet = Set(ids)

        let grabbedIndex = tabs.firstIndex(where: { $0.id == cell.tab.id }) ?? 0
        let insertion = tabs.prefix(grabbedIndex).filter { !idSet.contains($0.id) }.count
        let grabOffsetListY = tabListView.convert(cell.mouseDownInWindow, from: nil).y - cell.frame.minY

        // Full-screen, click-through overlay. The pile container starts at the origin and is shifted
        // by the cursor delta to carry the whole pile; cards are positioned in its (screen-aligned)
        // local space, so card springs and cursor-follow compose without fighting.
        let overlay = makeFloatingDragPanel(contentRect: screenFrame)
        let content = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        content.wantsLayer = true
        overlay.contentView = content
        let container = NSView(frame: content.bounds)
        container.wantsLayer = true
        content.addSubview(container)

        let pickupCursor = window.convertPoint(toScreen: cell.mouseDownInWindow)
        let toLocal = { (p: CGPoint) -> CGPoint in CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY) }
        // The grabbed tab is the flat top card, kept where it was dragged from so the cursor holds the
        // same spot on it; the pile tracks the cursor from there.
        let topOrigin = toLocal(window.convertToScreen(tabListView.convert(cell.frame, to: nil)).origin)

        // Order the rest by distance from the grabbed tab (closest on top; ties favor the upper one).
        let others = ids.filter { $0 != cell.tab.id }.sorted { a, b in
            let ia = tabs.firstIndex(where: { $0.id == a }) ?? 0
            let ib = tabs.firstIndex(where: { $0.id == b }) ?? 0
            let da = abs(ia - grabbedIndex), db = abs(ib - grabbedIndex)
            return da != db ? da < db : ia < ib
        }
        let ordered = [cell.tab.id] + others   // z order, top first

        // Capture each tab's current list slot (screen -> local) before the list collapses.
        var startOrigins: [UUID: CGPoint] = [:]
        for id in ids {
            if let c = tabCellViews[id] {
                startOrigins[id] = toLocal(window.convertToScreen(tabListView.convert(c.frame, to: nil)).origin)
            }
        }

        var built: [PileCard] = []
        for (z, id) in ordered.enumerated() {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            let hidden = z >= 5
            // Each non-top card is nudged a small random direction off the top card's center and
            // tilted a random way, for a loose hand-tossed pile rather than a neat ladder.
            let rotationDeg: CGFloat = z == 0 ? 0 : CGFloat(Int.random(in: 3...5)) * (Bool.random() ? 1 : -1)
            let homeOrigin: CGPoint
            if z == 0 {
                homeOrigin = topOrigin
            } else {
                let angle = CGFloat.random(in: 0 ..< (2 * .pi))
                let mag = CGFloat.random(in: 5...12)
                homeOrigin = CGPoint(x: topOrigin.x + cos(angle) * mag, y: topOrigin.y + sin(angle) * mag)
            }
            let darken: CGFloat = z == 0 ? 0 : min(CGFloat(z) * 0.04, 0.2)

            let inner = makeDragCard(tab: tab, appearance: cell.effectiveAppearance, size: cardSize, darken: darken)
            inner.autoresizingMask = []
            inner.frame = NSRect(origin: .zero, size: cardSize)
            let outer = NSView(frame: NSRect(origin: homeOrigin, size: cardSize))
            outer.wantsLayer = true
            outer.addSubview(inner)

            built.append(PileCard(id: id, outer: outer, inner: inner, homeOrigin: homeOrigin,
                                  startOrigin: startOrigins[id] ?? homeOrigin,
                                  rotationDeg: rotationDeg, hidden: hidden))
        }
        // Add farthest-first so the grabbed top card ends up frontmost.
        for card in built.reversed() { container.addSubview(card.outer) }
        overlay.orderFront(nil)

        drag = DragSession(ids: ids, insertion: insertion, overBar: true, grabOffsetListY: grabOffsetListY,
                           pickupCursor: pickupCursor, panelOrigin: screenFrame.origin,
                           panel: overlay, container: container, cards: built)

        for id in ids { tabCellViews[id]?.alphaValue = 0 }
        layoutTabCells(animated: true)
        gatherPile(cardSize: cardSize)
    }

    // Spring every card from its list slot into the pile, all at once. Cards past the 5-card cap
    // gather too, then fade out once the pile has formed.
    private func gatherPile(cardSize: CGSize) {
        guard let drag = drag else { return }
        // Each card's model rests at its pile slot (frame set at creation); the spring carries the
        // visual start (its list slot). Endpoints are derived from the card's real layer position so
        // they're correct whatever the layer's anchor point is.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in drag.cards {
            card.inner.frameCenterRotation = card.rotationDeg
            guard let layer = card.outer.layer else { continue }
            let toPos = layer.position
            let fromPos = CGPoint(x: toPos.x + (card.startOrigin.x - card.homeOrigin.x),
                                  y: toPos.y + (card.startOrigin.y - card.homeOrigin.y))
            guard fromPos != toPos else { continue }
            layer.add(pileSpring("position", from: NSValue(point: fromPos), to: NSValue(point: toPos)), forKey: "gather-pos")
        }
        CATransaction.commit()

        // Fade the capped extras out a beat after the gather starts (tweak pileExtraFadeDelay).
        if drag.cards.contains(where: { $0.hidden }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + pileExtraFadeDelay) { [weak self] in
                guard self?.drag != nil else { return }
                self?.fadePileExtras(visible: false, duration: 0.2)
            }
        }
    }

    private func fadePileExtras(visible: Bool, duration: TimeInterval) {
        for card in drag?.cards ?? [] where card.hidden {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                card.outer.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    // Driven by the dragging session, which hands us a screen point directly.
    private func pileDragMoved(toScreen cursor: NSPoint) {
        guard let drag = drag, let window = view.window else { return }
        // Translate via the layer (not the frame) so the container's frame stays put and AppKit never
        // re-lays-out the cards mid-spring, which is what made the pile jump out from under the cursor.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        drag.container.layer?.transform = CATransform3DMakeTranslation(cursor.x - drag.pickupCursor.x, cursor.y - drag.pickupCursor.y, 0)
        CATransaction.commit()
        updateMakeSpaceGap(windowPoint: window.convertPoint(fromScreen: cursor))
        // Let the window manager reveal / make space in whatever window the cursor is over.
        delegate?.sidebarTabDragMoved(toScreen: cursor, ids: drag.ids)
    }

    // The other cells open a single-tab gap at the slot the cursor hovers over (or close it when the
    // cursor leaves the list).
    private func updateMakeSpaceGap(windowPoint: CGPoint) {
        guard let drag = drag else { return }
        let m = tabMetrics()
        let overBar = scrollView.frame.contains(view.convert(windowPoint, from: nil))
        if overBar {
            let maxInsertion = tabs.count - reorderExcludedIds.count
            let notionalTop = tabListView.convert(windowPoint, from: nil).y - drag.grabOffsetListY
            let center = notionalTop + m.cellH / 2
            let slot = max(0, min(Int(((center - m.slotY(0) - m.cellH / 2) / m.rowH).rounded()), maxInsertion))
            if !drag.overBar || slot != drag.insertion {
                drag.overBar = true
                drag.insertion = slot
                layoutTabCells(animated: true)
            }
        } else if drag.overBar {
            drag.overBar = false
            layoutTabCells(animated: true)
        }
    }

    private func pileDragEnded(commit: Bool) {
        guard let drag = drag, let window = view.window else { cleanupPile(); return }
        let ids = drag.ids

        if commit {
            // Drop the dragged group contiguous at the insertion slot. When not committing (dropped
            // outside the list, e.g. exported as markdown to another app), the order is left untouched
            // so the cards simply spring back to where they started.
            let idSet = Set(ids)
            let group = ids.compactMap { id in tabs.first(where: { $0.id == id }) }
            var remaining = tabs.filter { !idSet.contains($0.id) }
            remaining.insert(contentsOf: group, at: min(drag.insertion, remaining.count))
            tabs = remaining
            for (index, tab) in tabs.enumerated() { tab.sortIndex = index }
            delegate?.sidebarDidReorderTabs(tabs.map { $0.id })
        }

        // Lay the (still-hidden) real cells into their final slots so we can read fly-back targets.
        drag.dropping = true
        layoutTabCells()

        let m = tabMetrics()
        let cardSize = CGSize(width: m.cellW, height: m.cellH)

        // Bake the cursor-follow translation into each card's position and drop the container shift,
        // so the scatter springs run in a static frame.
        let t = drag.container.layer?.transform ?? CATransform3DIdentity
        let shift = CGPoint(x: t.m41, y: t.m42)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        drag.container.layer?.transform = CATransform3DIdentity
        for card in drag.cards {
            card.outer.layer?.removeAnimation(forKey: "gather-pos")
            card.outer.frame = NSRect(origin: CGPoint(x: card.homeOrigin.x + shift.x, y: card.homeOrigin.y + shift.y), size: cardSize)
        }
        CATransaction.commit()

        // The hidden extras fade back in right as the scatter starts, so the fan-out is seamless.
        fadePileExtras(visible: true, duration: 0.08)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in drag.cards {
            guard let cell = tabCellViews[card.id] else { continue }
            let slotScreen = window.convertToScreen(tabListView.convert(cell.frame, to: nil))
            let targetOrigin = CGPoint(x: slotScreen.minX - drag.panelOrigin.x, y: slotScreen.minY - drag.panelOrigin.y)
            let pileOrigin = CGPoint(x: card.homeOrigin.x + shift.x, y: card.homeOrigin.y + shift.y)
            card.inner.frameCenterRotation = 0
            card.outer.frame = NSRect(origin: targetOrigin, size: cardSize)
            guard let layer = card.outer.layer else { continue }
            let toPos = layer.position
            let fromPos = CGPoint(x: toPos.x + (pileOrigin.x - targetOrigin.x), y: toPos.y + (pileOrigin.y - targetOrigin.y))
            layer.add(pileSpring("position", from: NSValue(point: fromPos), to: NSValue(point: toPos)), forKey: "scatter-pos")
        }
        CATransaction.commit()

        // Reveal the real cells underneath and dissolve the pile cards out over them (hides the handoff
        // jitter). Started partway into the scatter rather than at settle, so the drop feels snappy.
        DispatchQueue.main.asyncAfter(deadline: .now() + pileDropFadeDelay) { [weak self] in
            guard let self = self, self.drag != nil else { return }
            for id in ids { self.tabCellViews[id]?.alphaValue = 1 }
            self.clearMultiSelection()
            let cards = self.drag?.cards ?? []
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for card in cards { card.outer.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                self?.cleanupPile()
            })
        }
    }

    private func cleanupPile() {
        if let ids = drag?.ids { for id in ids { tabCellViews[id]?.alphaValue = 1 } }
        drag?.panel.close()
        drag = nil
        layoutTabCells()
    }

    // Delay from grabbing the stack to the capped extras fading out. Tune to taste.
    private let pileExtraFadeDelay: TimeInterval = 0.1
    // Delay from dropping to the cards dissolving into the real cells (partway into the scatter).
    private let pileDropFadeDelay: TimeInterval = 0.4

    // Snappy with a touch of overshoot, like the iOS Photos pile gather/scatter.
    private func pileSpring(_ keyPath: String, from: Any?, to: Any?) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = 400
        a.damping = 27
        a.initialVelocity = 0
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    private func makeFloatingDragPanel(contentRect: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // a shadow halo read as a border; the dark card is enough
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // canJoinAllSpaces so the union-of-screens panel renders on every display even with "Displays
        // have separate Spaces" on (the default).
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        return panel
    }

    // A lifted tab card: the sidebar's vibrant material + dark overlay (so it tints with the page
    // content like the sidebar) + the hovered-tab highlight, with a live ghost cell rendering the
    // title (and its fade). Deeper pile cards pass a larger darken.
    private func makeDragCard(tab: Tab, appearance: NSAppearance?, size: CGSize, darken: CGFloat = 0) -> NSView {
        let card = NSView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        card.layer?.allowsEdgeAntialiasing = true
        card.layer?.contentsScale = scale
        // Clip to the rounded rect with a shape-layer mask rather than masksToBounds, so the corners
        // stay antialiased when the card is rotated in the pile (a layer cornerRadius/border aliases
        // hard off-axis). The border is a stroked shape layer for the same reason.
        let clip = CAShapeLayer()
        clip.path = CGPath(roundedRect: NSRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil)
        card.layer?.mask = clip
        card.autoresizingMask = [.width, .height]
        card.appearance = appearance

        let effect = NSVisualEffectView(frame: card.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        card.addSubview(effect)

        let overlay = NSView(frame: card.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.4).cgColor
        overlay.autoresizingMask = [.width, .height]
        card.addSubview(overlay)

        let highlight = NSView(frame: card.bounds)
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        highlight.autoresizingMask = [.width, .height]
        card.addSubview(highlight)

        if darken > 0 {
            let shade = NSView(frame: card.bounds)
            shade.wantsLayer = true
            shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(darken).cgColor
            shade.autoresizingMask = [.width, .height]
            card.addSubview(shade)
        }

        let ghost = TabCellView(tab: tab, isSelected: delegate?.currentTabId == tab.id)
        ghost.isDragGhost = true
        ghost.appearance = appearance
        ghost.frame = card.bounds
        ghost.autoresizingMask = [.width, .height]
        card.addSubview(ghost)

        // Stroked border on top of everything, concentric with the clip; antialiases under rotation.
        let border = CAShapeLayer()
        border.path = CGPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                             cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        border.lineWidth = 1
        border.contentsScale = scale
        border.zPosition = 1000
        card.layer?.addSublayer(border)
        return card
    }

    // MARK: - Multi-selection

    private func handleTabClick(_ tab: Tab, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedTabIds.contains(tab.id) { selectedTabIds.remove(tab.id) }
            else { selectedTabIds.insert(tab.id) }
            selectionAnchorId = tab.id
            updateSelectionHighlights()
        } else if modifiers.contains(.shift) {
            let anchor = selectionAnchorId ?? delegate?.currentTabId
            if let a = tabs.firstIndex(where: { $0.id == anchor }),
               let b = tabs.firstIndex(where: { $0.id == tab.id }) {
                let range = a <= b ? a...b : b...a
                selectedTabIds = Set(range.map { tabs[$0].id })
            } else {
                selectedTabIds = [tab.id]
            }
            updateSelectionHighlights()
        } else {
            selectedTabIds = [tab.id]
            selectionAnchorId = tab.id
            updateSelectionHighlights()
            unfocusURLBar()
            delegate?.sidebarDidSelectTab(tab)
        }
    }

    private func updateSelectionHighlights() {
        // Non-active selected tabs always show the selection highlight. The active tab only joins it
        // when there's a real multi-selection (other tabs too), so a lone active tab keeps its 0.1.
        let isMulti = selectedTabIds.count > 1
        for (id, cell) in tabCellViews {
            if id == delegate?.currentTabId {
                cell.isInSelection = isMulti && selectedTabIds.contains(id)
            } else {
                cell.isInSelection = selectedTabIds.contains(id)
            }
        }
    }

    func clearMultiSelection() {
        guard !selectedTabIds.isEmpty else { return }
        selectedTabIds.removeAll()
        selectionAnchorId = nil
        updateSelectionHighlights()
    }

    // True while the URL bar (its field editor) has focus, so cmd-C there copies text, not tabs.
    private var isEditingText: Bool { view.window?.firstResponder is NSText }

    // Copy the selected tabs as markdown links, one per line in list order - the export path now that
    // dragging is reserved for in-app moves (reorder, and later tear-off / split).
    private func copySelectedTabsAsMarkdown() {
        let md = tabs.filter { selectedTabIds.contains($0.id) }
            .map { "[\($0.title.isEmpty ? "Untitled" : $0.title)](\($0.url))" }
            .joined(separator: "\n")
        guard !md.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    // MARK: - Tab List

    private func rebuildTabList() {
        // Remove cells for tabs that no longer exist
        let currentTabIds = Set(tabs.map { $0.id })
        for (id, cell) in tabCellViews where !currentTabIds.contains(id) {
            cell.removeFromSuperview()
            tabCellViews.removeValue(forKey: id)
        }

        // Rebuild ordered list
        tabListView.subviews.forEach { $0.removeFromSuperview() }

        for tab in tabs {
            let cell: TabCellView
            if let existing = tabCellViews[tab.id] {
                cell = existing
            } else {
                cell = TabCellView(tab: tab, isSelected: delegate?.currentTabId == tab.id)
                cell.onSelect = { [weak self, weak tab] modifiers in
                    guard let tab = tab else { return }
                    self?.handleTabClick(tab, modifiers: modifiers)
                }
                cell.onClose = { [weak self, weak tab] in
                    guard let tab = tab else { return }
                    self?.clearMultiSelection()
                    self?.delegate?.sidebarDidRequestCloseTab(tab)
                }
                cell.onDragStart = { [weak self] cell, event in
                    self?.tabDragBegan(cell, event)
                }
                cell.onDragChanged = { [weak self] cell, event in
                    self?.tabDragChanged(cell, event)
                }
                cell.onDragEnded = { [weak self] cell, event in
                    self?.tabDragEnded(cell, event)
                }
                tabCellViews[tab.id] = cell
            }
            cell.update(tab: tab, isSelected: delegate?.currentTabId == tab.id)
            tabListView.addSubview(cell)
        }

        // Drop any selected ids for tabs that no longer exist, then refresh highlights.
        selectedTabIds.formIntersection(currentTabIds)
        updateSelectionHighlights()

        layoutTabCells()
    }
}

// MARK: - NSTextFieldDelegate

extension SidebarViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            delegate?.sidebarDidSubmitURL(urlBar.stringValue)
            view.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - Sidebar Background View

// MARK: - Tab List Drop View

class TabListDropView: FlippedView {
    var onTapped: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Original: .onTapGesture { isUrlFieldFocused = false }
        onTapped?()
        super.mouseDown(with: event)
    }
}

// MARK: - Sidebar Background View

class SidebarBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Original: .onTapGesture { isUrlFieldFocused = false } on entire sidebar
        window?.makeFirstResponder(nil)
        if event.clickCount == 2 {
            self.window?.zoom(nil)
        } else {
            self.window?.performDrag(with: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit == self ? self : hit
    }
}

// MARK: - Vertically Centered Text Field Cell

class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < rect.height else { return rect }
        let y = rect.origin.y + (rect.height - textHeight) / 2
        return NSRect(x: rect.origin.x, y: y, width: rect.width, height: textHeight)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: centered(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
