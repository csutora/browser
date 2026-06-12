import AppKit
import Combine

// MARK: - Sidebar Delegate Protocol

protocol SidebarDelegate: AnyObject {
    func sidebarDidSelectTab(_ tab: Tab)
    func sidebarDidRequestCloseTab(_ tab: Tab)
    func sidebarDidRequestNewTab()
    func sidebarDidToggleDock()
    func sidebarDidRequestBack()
    func sidebarDidRequestForward()
    func sidebarDidRequestReload()
    func sidebarDidSubmitURL(_ url: String)
    func sidebarDidReorderTabs(_ orderedTabIds: [UUID])
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
    private var draggedTab: Tab?

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
        tabListView.registerForDraggedTypes([.string])
        tabListView.onDropEntered = { [weak self] tabIdString, targetTab in
            self?.handleDropEntered(draggedTabId: tabIdString, targetTab: targetTab)
        }
        tabListView.onDropPerformed = { [weak self] in
            self?.draggedTab = nil
        }
        tabListView.findTabAtPoint = { [weak self] point in
            self?.tabAtPoint(point)
        }
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
        }

        self.view = container
    }

    deinit {
        if let obs = focusObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = unfocusObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = focusURLBarObserver { NotificationCenter.default.removeObserver(obs) }
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

    private func layoutTabCells() {
        // Use the sidebar's own bounds width, which is valid as soon as the view is sized
        // via autoresizing. scrollView.frame is only set later in layoutSidebar(), so relying
        // on it makes the very first reloadTabs() (at launch) lay cells out at zero width.
        let w = view.bounds.width
        // Align tab cells to the URL bar's horizontal inset (12) so they're the same width.
        let padH: CGFloat = 12
        let padV: CGFloat = 10
        let cellW = w - padH * 2
        let cellH: CGFloat = 32 // HStack padding 8 top/bottom + 16pt content
        let spacing: CGFloat = 2
        var y: CGFloat = padV + 1 // Color.clear.frame(height: 1) spacer

        for tab in tabs {
            if let cell = tabCellViews[tab.id] {
                cell.frame = NSRect(x: padH, y: y, width: cellW, height: cellH)
                y += cellH + spacing
            }
        }

        let totalH = y + padV
        tabListView.frame = NSRect(x: 0, y: 0, width: w, height: max(totalH, scrollView.frame.height))
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
        cell.update(tab: tab, isSelected: tabManager.currentTabId == tab.id)
    }

    func updateSelection() {
        for tab in tabs {
            tabCellViews[tab.id]?.update(tab: tab, isSelected: tabManager.currentTabId == tab.id)
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

    // MARK: - Drag & Drop

    private func tabAtPoint(_ point: NSPoint) -> Tab? {
        for tab in tabs {
            if let cell = tabCellViews[tab.id], cell.frame.contains(point) {
                return tab
            }
        }
        return nil
    }

    private func handleDropEntered(draggedTabId: String, targetTab: Tab) {
        guard let draggedId = UUID(uuidString: draggedTabId),
              let fromIndex = tabs.firstIndex(where: { $0.id == draggedId }),
              let toIndex = tabs.firstIndex(where: { $0.id == targetTab.id }),
              fromIndex != toIndex else { return }

        // Reorder: remove from old position, insert at correct new position
        let tab = tabs.remove(at: fromIndex)
        // After removal, if target was after source, the target index shifts down by 1
        let adjustedTo = toIndex > fromIndex ? toIndex - 1 : toIndex
        tabs.insert(tab, at: adjustedTo)

        // Update sort indices
        for (index, t) in tabs.enumerated() {
            t.sortIndex = index
        }

        rebuildTabList()
        delegate?.sidebarDidReorderTabs(tabs.map { $0.id })
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
                cell = TabCellView(tab: tab, isSelected: tabManager.currentTabId == tab.id)
                cell.onSelect = { [weak self, weak tab] in
                    guard let tab = tab else { return }
                    self?.unfocusURLBar()
                    self?.delegate?.sidebarDidSelectTab(tab)
                }
                cell.onClose = { [weak self, weak tab] in
                    guard let tab = tab else { return }
                    self?.delegate?.sidebarDidRequestCloseTab(tab)
                }
                cell.onDragStarted = { [weak self] tab in
                    self?.draggedTab = tab
                }
                cell.onDragEnded = { [weak self] in
                    self?.draggedTab = nil
                }
                tabCellViews[tab.id] = cell
            }
            cell.update(tab: tab, isSelected: tabManager.currentTabId == tab.id)
            tabListView.addSubview(cell)
        }

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
    var onDropEntered: ((String, Tab) -> Void)?
    var onDropPerformed: (() -> Void)?
    var findTabAtPoint: ((NSPoint) -> Tab?)?
    var onTapped: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Original: .onTapGesture { isUrlFieldFocused = false }
        onTapped?()
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pasteboard = sender.draggingPasteboard.string(forType: .string),
              let point = superview?.convert(sender.draggingLocation, to: self),
              let targetTab = findTabAtPoint?(point) else {
            return .move
        }
        onDropEntered?(pasteboard, targetTab)
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropPerformed?()
        return true
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
