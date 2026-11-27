import AppKit
import SwiftData
import Combine
import WebKit

class MainWindowController: NSWindowController {
    let tabManager: TabManager
    let historyManager: HistoryManager
    let modelContext: ModelContext
    let windowModel: WindowModel
    weak var windowManager: WindowManager?

    // This window's current tab, persisted on the window model.
    var currentTabId: UUID? { windowModel.currentTabId }

    // The current tab's live URL (web view if any, else the stored url) - for the URL bar / copy.
    var currentTabURL: String {
        if let live = currentBrowserState?.currentURL?.absoluteString { return live }
        return currentTab?.url ?? ""
    }

    var favorites: FavoritesController? { windowManager?.favorites }
    var webContent: WebContentViewController { webContentVC }

    // a tab of this window or a favorite
    func tab(for id: UUID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first(where: { $0.id == id }) ?? favoriteTabs.first(where: { $0.id == id })
    }

    // the live page of a tab of this window, or of a favorite
    func state(for id: UUID?) -> BrowserState? {
        guard let id else { return nil }
        return browserStates[id] ?? favorites?.state(for: id)
    }

    var currentBrowserState: BrowserState? { state(for: currentTabId) }
    var currentTab: Tab? { tab(for: currentTabId) }

    // the tab shown before the current one: switching back to it is instant, so it's never unloaded
    private(set) var previousTabId: UUID?
    private var shownTabId: UUID?

    // Set by the WindowManager: called when this window closes (user close or app quit).
    var onWindowClose: (() -> Void)?

    // Save this window's on-screen frame to its model for session restore.
    func persistFrame() {
        if let f = window?.frame { windowModel.frame = f }
    }

    // If the screen point is over this window's tab list, the slot tabs would insert at (else nil).
    func tabListInsertionIndex(atScreen screenPoint: CGPoint) -> Int? {
        sidebarVC?.tabListInsertionIndex(atScreen: screenPoint)
    }

    // A pile from another window is hovering this one: open a make-space gap (the sidebar reveal is
    // handled by the shared hover monitor, since the drag emits mouse-dragged events).
    func beginForeignTabDrag(pileSize: Int, excluding: Set<UUID>) {
        sidebarVC?.beginForeignDrag(pileSize: pileSize, excluding: excluding)
    }

    func updateForeignTabGap(atScreen screenPoint: CGPoint) {
        sidebarVC?.updateForeignGap(atScreen: screenPoint)
    }

    func endForeignTabDrag() {
        sidebarVC?.endForeignDrag()
    }

    func clearForeignTabDrag() {
        sidebarVC?.clearForeignDrag()
    }

    var sidebar: SidebarViewController? { sidebarVC }

    // Reads every live page of this window into its tab, so a later restore (reopen of a kept last
    // window, or relaunch) brings each page back as it was. The pages have to have stopped showing first
    // (the window closed or ordered out) for their form fields to be included.
    func captureLiveTabs(_ completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for (id, state) in browserStates {
            group.enter()
            state.captureState { [tabManager] page in
                tabManager.savePage(id, page)
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    let keybindHandler = KeybindHandler.shared
    let commandPaletteState = CommandPaletteState()

    // the live pages of this window's tabs; an unloaded tab (or one not shown since launch) has none
    var browserStates: [UUID: BrowserState] = [:]
    var tabs: [Tab] = []
    private(set) var favoriteTabs: [Tab] = []

    // Layout views
    private var rootView: NSView!
    private var backgroundEffectView: NSVisualEffectView!
    private var darkOverlay: NSView!
    private var sidebarContainer: SidebarContainerView!
    private var contentContainer: NSView!
    private var resizeHandle: ResizeHandleNSView!

    // Child controllers
    private var sidebarVC: SidebarViewController!
    private var webContentVC: WebContentViewController!
    private var commandPalettePanel: CommandPalettePanel?
    private let downloadsPanel = DownloadsPanel()

    // State
    private var isFullscreen = false
    private var fullscreenCornerRadiusOverride: CGFloat?
    private var isResizing = false
    private var dragStartWidth: Double?
    private var isSidebarFullyOpen = false
    private var sidebarOpenWorkItem: DispatchWorkItem?

    // Combine
    private var cancellables = Set<AnyCancellable>()
    private var browserStateCancellables = Set<AnyCancellable>()

    // MARK: - Settings

    // Per-window dock state (persisted on the window model).
    var isDocked: Bool {
        get { windowModel.isDocked }
        set {
            windowModel.isDocked = newValue
            tabManager.scheduleSave()
            sidebarVC?.updateDockState(newValue)
        }
    }

    var sidebarWidth: Double {
        get { UserDefaults.standard.double(forKey: "sidebarWidth") }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarWidth") }
    }

    var fullscreenSidebarRadius: Int {
        get { UserDefaults.standard.integer(forKey: "fullscreenSidebarRadius") }
        set { UserDefaults.standard.set(newValue, forKey: "fullscreenSidebarRadius") }
    }

    // MARK: - Computed

    // Driven by the shared hover monitor (one listener across all windows): true while the cursor is
    // near this undocked window's sidebar edge and this window is the one under the cursor.
    var hoverSidebarOpen = false {
        didSet {
            guard oldValue != hoverSidebarOpen else { return }
            handleFloatingVisibilityChange()
        }
    }

    var isFloatingVisible: Bool {
        if isDocked { return false }
        if isResizing { return true }
        return hoverSidebarOpen
    }

    // Called by the shared hover monitor with the cursor's last and current positions. Open this
    // (undocked) window's sidebar when that segment crosses a trigger line just inside the left edge -
    // line-crossing rather than zone-testing, so a fast flick can't skip it and parking next to a
    // neighbour (whose line the cursor never crosses) can't bleed it open. Once open it holds until the
    // cursor leaves a wide band: too far left (overshoot done) or right into the content.
    func updateHover(from prev: NSPoint, to cur: NSPoint) {
        guard !isDocked, let frame = window?.frame else {
            hoverSidebarOpen = false
            return
        }
        let triggerLine = frame.minX + 8
        let withinHeight = cur.y >= frame.minY && cur.y <= frame.maxY
        let crossed = withinHeight && ((prev.x > triggerLine) != (cur.x > triggerLine))
        if crossed { hoverSidebarOpen = true }

        // the downloads panel is wider than the sidebar and anchored to it, so it holds the sidebar
        // open while it's showing
        let x = cur.x - frame.minX
        if hoverSidebarOpen, !downloadsPanel.isShown, !withinHeight || x < -150 || x >= CGFloat(sidebarWidth) + 30 {
            hoverSidebarOpen = false
        }
    }

    var sidebarOffset: CGFloat {
        isDocked ? 0 : (isFloatingVisible ? 0 : -(CGFloat(sidebarWidth) + 50))
    }

    // MARK: - Init

    init(tabManager: TabManager, historyManager: HistoryManager, modelContext: ModelContext, windowModel: WindowModel) {
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.modelContext = modelContext
        self.windowModel = windowModel

        let window = Self.createWindow()
        super.init(window: window)

        setupViews()
        setupObservers()

        commandPaletteState.historyManager = historyManager

        loadTabs()

        if currentTabId == nil, let first = tabs.first {
            windowModel.currentTabId = first.id   // switch itself is deferred to showWindow()
        }

        sidebarVC.reloadTabs(tabs)
        sidebarVC.reloadFavorites(favoriteTabs, animated: false)
        sidebarVC.updateSelection()
        updateWindowTitle()
        // Web view creation (syncStates/handleTabSwitch) is deferred to showWindow(), so it
        // happens once the window is on-screen — matching the original's onAppear timing.
    }

    required init?(coder: NSCoder) { fatalError() }

    private var didInitialWebSetup = false

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didInitialWebSetup else { return }
        didInitialWebSetup = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.syncStates()
            self.handleTabSwitch()
        }
    }

    // MARK: - Window Creation

    private static func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        // Needed for the sidebar hover-reveal: without it macOS delivers no mouse-moved events to the
        // window, so a window that becomes key (e.g. via cmd-`) would stop responding to hover.
        window.acceptsMouseMovedEvents = true
        window.center()
        // No frame autosave: multiple windows would all share one saved frame (and overlap). Frames
        // are persisted per window via WindowModel instead.
        window.minSize = NSSize(width: 600, height: 400)
        return window
    }

    // MARK: - View Setup

    private func setupViews() {
        guard let window = self.window else { return }

        rootView = NSView()
        rootView.wantsLayer = true
        window.contentView = rootView
        // Don't auto-focus the URL bar on launch: a focused field shows its text via the
        // field editor (top-aligned), which looks offset until the field is unfocused and
        // drawInterior vertically centers it.
        window.initialFirstResponder = rootView

        // Background effect
        backgroundEffectView = NSVisualEffectView()
        // Original: .thickMaterial background
        backgroundEffectView.material = .headerView
        backgroundEffectView.blendingMode = .behindWindow
        backgroundEffectView.state = .active
        rootView.addSubview(backgroundEffectView)

        // Dark overlay
        darkOverlay = NSView()
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8).cgColor
        rootView.addSubview(darkOverlay)

        // Content container
        contentContainer = NSView()
        contentContainer.wantsLayer = true
        rootView.addSubview(contentContainer)

        // Web content VC
        webContentVC = WebContentViewController(tabManager: tabManager, historyManager: historyManager)
        webContentVC.onOpenURLInNewTab = { [weak self] url in self?.createTab(url: url, switchTo: true) }
        webContentVC.onUpdateSettingsPath = { [weak self] path in
            guard let self = self else { return }
            self.tabManager.updateSettingsPath(path, in: self.windowModel)
        }
        webContentVC.view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(webContentVC.view)

        // Sidebar container
        sidebarContainer = SidebarContainerView()
        sidebarContainer.wantsLayer = true
        rootView.addSubview(sidebarContainer)

        // Sidebar background (for floating mode)
        let sidebarBg = SidebarFloatingBackground()
        sidebarBg.autoresizingMask = [.width, .height]
        sidebarContainer.addSubview(sidebarBg)
        sidebarBg.isDocked = isDocked

        // Sidebar VC
        sidebarVC = SidebarViewController(tabManager: tabManager)
        sidebarVC.delegate = self
        sidebarVC.view.autoresizingMask = [.width, .height]
        sidebarContainer.addSubview(sidebarVC.view)

        // Resize handle
        resizeHandle = ResizeHandleNSView()
        resizeHandle.onDragStart = { [weak self] in
            self?.dragStartWidth = self?.sidebarWidth
            self?.isResizing = true
        }
        resizeHandle.onDragUpdate = { [weak self] delta in
            guard let self = self, let start = self.dragStartWidth else { return }
            self.sidebarWidth = max(220, min(600, start + Double(delta)))
            self.layoutSubviews()
        }
        resizeHandle.onDragEnd = { [weak self] in
            self?.dragStartWidth = nil
            self?.isResizing = false
        }
        rootView.addSubview(resizeHandle)

        // Initial layout
        rootView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification, object: rootView
        )

        layoutSubviews()
    }

    // MARK: - Layout

    @objc private func frameDidChange() {
        layoutSubviews()
    }

    func layoutSubviews() {
        guard let rootView = rootView else { return }
        let bounds = rootView.bounds

        backgroundEffectView.frame = bounds
        darkOverlay.frame = bounds

        // Round to whole pixels: a fractional sidebar width leaves the content container on a
        // subpixel boundary, which renders as a faint 1px line on the web view's right edge.
        let sidebarW = CGFloat(sidebarWidth).rounded()

        // Sidebar
        sidebarContainer.frame = NSRect(
            x: sidebarOffset,
            y: 0,
            width: sidebarW,
            height: bounds.height
        )

        // Content frame, matching original WebView.swift exactly:
        //   shouldHaveBorder = !(isFullscreen && !isDocked)
        //   padding        = shouldHaveBorder ? 8 : 0
        //   leadingPadding = isDocked ? sidebarWidth : padding
        //   frame = (leadingPadding, padding, w - leadingPadding - padding, h - padding*2)
        // The border padding (top/bottom/right) applies in BOTH docked and floating modes,
        // so docking only rescales horizontally — it never grows vertically over the edge.
        let shouldHaveBorder = !(isFullscreen && !isDocked)
        let padding: CGFloat = shouldHaveBorder ? 8 : 0
        let leadingPadding: CGFloat = isDocked ? sidebarW : padding

        let contentX = leadingPadding
        let contentY = padding
        let contentW = max(0, bounds.width - leadingPadding - padding)
        let contentH = max(0, bounds.height - padding * 2)

        contentContainer.frame = NSRect(x: contentX, y: contentY, width: contentW, height: contentH).integral

        // The corner radius is normally tied to the border, but during the fullscreen enter
        // transition it is held rounded (overridden) so the hand-off from the system's rounded
        // window snapshot to the live content is seamless, then animated to 0 once fullscreen.
        contentContainer.layer?.cornerRadius = fullscreenCornerRadiusOverride ?? (padding > 0 ? 9 : 0)
        contentContainer.layer?.cornerCurve = .continuous
        contentContainer.layer?.masksToBounds = true

        webContentVC.view.frame = contentContainer.bounds

        // Resize handle
        let handleVisible = isDocked || isFloatingVisible
        resizeHandle.isHidden = !handleVisible
        if handleVisible {
            let handleX = (isDocked ? sidebarW : sidebarW + 4) - 6
            resizeHandle.frame = NSRect(x: handleX + sidebarOffset, y: 0, width: 12, height: bounds.height)
        }

        // Original: .allowsHitTesting(sidebarOffset == 0). Keep the view visible so it slides
        // smoothly off-screen instead of vanishing; just disable hit testing while it's not
        // fully open so clicks pass through to the content during the slide.
        sidebarContainer.hitTestEnabled = (sidebarOffset == 0)
    }

    // MARK: - Observers

    private func setupObservers() {
        // synchronous on purpose: the flight registers with the indicator before the manager publishes
        // the new download, so the button reacts to the badge landing rather than ahead of it
        DownloadManager.shared.events
            .sink { [weak self] event in
                guard case .started(_, let source) = event, let self, let source,
                      self.browserStates.values.contains(where: { $0.webView === source })
                        || self.currentBrowserState?.webView === source else { return }
                self.launchDownloadFlight()
            }
            .store(in: &cancellables)

        // favorites are shared: any window pinning, unpinning, reordering, closing or opening one
        // changes every window's tiles
        NotificationCenter.default.addObserver(
            self, selector: #selector(favoritesDidChange),
            name: .favoritesDidChange, object: nil
        )

        // a favorite's page is shown in the window using it, so a window coming to the front takes
        // back the favorite it shows
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: window
        )

        // Per-tab data updates (title/url/bg) can come from any window's web view; only react to tabs
        // this window owns. Structural changes (create/close/reorder) are driven directly, no notif.
        NotificationCenter.default.addObserver(
            self, selector: #selector(tabDataDidChange(_:)),
            name: .tabDataDidChange, object: nil
        )

        // Sidebar hover is driven by the shared hover monitor (WindowManager) via updateHover().

        // Fullscreen border: flip the layout at the start of the transition in both directions, so
        // the target state is baked in while the window zooms behind the system snapshot and is
        // simply correct when revealed. No separate animation, no settling delay.
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterFullScreen),
            name: NSWindow.willEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(willExitFullScreen),
            name: NSWindow.willExitFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillCloseNotif),
            name: NSWindow.willCloseNotification, object: window
        )
    }

    @objc private func windowWillCloseNotif() { onWindowClose?() }

    // Re-read this window's tabs from the model and rebuild views. Called by the window's own tab
    // operations (the structural counterpart to the old global .tabsDidChange).
    func refreshTabs() {
        loadTabs()
        syncStates()
        sidebarVC.reloadTabs(tabs)
        sidebarVC.reloadFavorites(favoriteTabs, animated: true)
        updateWindowTitle()
    }

    @objc private func tabDataDidChange(_ notification: Notification) {
        guard let tabId = notification.object as? UUID, tab(for: tabId) != nil else { return }
        sidebarVC.updateTab(tabId)
        updateWindowTitle()
    }

    @objc private func favoritesDidChange() {
        let wasCurrent = currentTab
        refreshTabs()
        // the current favorite went to another window (unpinned there): this window moves on
        if wasCurrent != nil, currentTab == nil {
            windowModel.currentTabId = fallbackTabId(excluding: wasCurrent?.id)
            handleTabSwitch()
        } else {
            sidebarVC.updateSelection()
        }
    }

    @objc private func windowDidBecomeKey() {
        guard let id = currentTabId, currentTab?.isFavorite == true, favorites?.host(of: id) !== self else { return }
        handleTabSwitch()
    }

    // what to show when the current tab goes: the one shown before it, else the first tab, else the
    // favorite used last. with none open, a closed one opens again (the last), but only when `reopening`:
    // closing favorites one by one has to end in the window closing, rather than cycling through them.
    func fallbackTabId(excluding id: UUID?, reopening: Bool = false) -> UUID? {
        if let previous = previousTabId, previous != id, let candidate = tab(for: previous), !candidate.favoriteClosed { return previous }
        if let first = tabs.first(where: { $0.id != id }) { return first.id }
        let others = favoriteTabs.filter { $0.id != id }
        let open = others.filter { !$0.favoriteClosed }
        return (open.max(by: { $0.lastAccessedAt < $1.lastAccessedAt }) ?? (reopening ? others.last : nil))?.id
    }

    func handleTabSwitch() {
        let id = currentTabId
        if id != shownTabId {
            if let shown = shownTabId, tab(for: shown) != nil { previousTabId = shown }
            shownTabId = id
        }
        let tab = currentTab
        if let tab { ensureLive(tab) }
        let settingsPath = tab?.isSettings == true ? extractSettingsPath(from: tab?.url ?? "") : nil
        let show = { [weak self] in
            guard let self, self.currentTabId == id else { return }
            self.webContentVC.show(id, state: self.state(for: id), settingsPath: settingsPath)
        }
        if let tab, tab.isFavorite, let favorites {
            favorites.claim(tab.id, for: self, then: show)
        } else {
            show()
        }
        sidebarVC.updateSelection()
        sidebarVC.updateNavState(for: currentBrowserState)
        observeCurrentBrowserState()
        updateWindowTitle()
    }

    // the tab's page, made live if it isn't
    @discardableResult
    private func ensureLive(_ tab: Tab) -> BrowserState? {
        guard !tab.isSettings else { return nil }
        if tab.isFavorite { return favorites?.ensureLive(tab) }
        if let state = browserStates[tab.id] { return state }
        let state = BrowserState(
            tabId: tab.id,
            tabManager: tabManager,
            historyManager: historyManager,
            initialURL: URL(string: tab.url),
            saved: tab.savedPage,
            iconKey: tab.iconKey
        )
        adopt(state)
        return state
    }

    // a live page joining this window (made here, unpinned into it, or moved from another window)
    func adopt(_ state: BrowserState) {
        state.onNewTabRequested = { [weak self] url, switchToTab in
            self?.createTab(url: url.absoluteString, switchTo: switchToTab)
        }
        state.onNewWindowRequested = { [weak self] url in
            self?.windowManager?.newWindow(url: url.absoluteString)
        }
        state.onOpenPage = { [weak self] configuration, url, switchTo in
            self?.openPage(configuration, url: url, switchTo: switchTo)
        }
        let id = state.tabId
        state.onClose = { [weak self] in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.closeTab(tab)
        }
        browserStates[state.tabId] = state
    }

    // a page another page opened (a sign-in window, a link to a new window): a new tab, whose web view
    // webkit loads the page into, which keeps it tied to its opener. closing it comes back to the opener,
    // the tab shown before it.
    func openPage(_ configuration: WKWebViewConfiguration, url: URL?, switchTo: Bool) -> WKWebView {
        let tab = tabManager.createTab(in: windowModel, url: url?.absoluteString ?? "about:blank", switchTo: switchTo)
        let state = BrowserState(tabId: tab.id, tabManager: tabManager, historyManager: historyManager, initialURL: nil, opening: configuration)
        adopt(state)
        refreshTabs()
        if switchTo { handleTabSwitch() }
        return state.webView
    }

    // the tab's page goes, kept with the tab to come back as it was when the tab is shown again.
    // reports whether it went (the tab may have been shown meanwhile), and the process that showed it,
    // which exits once nothing else uses it.
    func unload(_ id: UUID, completion: @escaping (Bool, pid_t?) -> Void) {
        guard id != currentTabId, id != previousTabId, let state = browserStates[id] else { return completion(false, nil) }
        let pid = state.webProcessIdentifier
        state.captureState { [weak self] page in
            guard let self, id != self.currentTabId, id != self.previousTabId, self.browserStates[id] === state else {
                return completion(false, nil)
            }
            self.tabManager.savePage(id, page)
            self.browserStates.removeValue(forKey: id)
            self.syncStates()
            self.sidebar?.updateTab(id)
            completion(true, pid)
        }
    }

    private func observeCurrentBrowserState() {
        browserStateCancellables.removeAll()

        // Drive the URL bar from the current tab: live web-view URL, or the stored url for a settings
        // tab / before the web view exists.
        sidebarVC.updateURLBar(currentTabURL)
        sidebarVC.setWindowHasTab(currentTab != nil)

        guard let state = currentBrowserState else { return }

        state.$currentURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.sidebarVC.updateURLBar(url?.absoluteString ?? self?.currentTab?.url ?? "")
            }
            .store(in: &browserStateCancellables)

        // @Published emits before the property is stored and updateNavState reads the properties, so
        // hop a turn; otherwise a lone isLoading flip (a download ends its navigation) is rendered stale
        Publishers.CombineLatest3(state.$canGoBack, state.$canGoForward, state.$isLoading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state] _, _, _ in
                guard let state = state else { return }
                self?.sidebarVC.updateNavState(for: state)
            }
            .store(in: &browserStateCancellables)
    }

    // MARK: - Window-scoped tab operations

    func selectTab(_ tab: Tab) {
        tabManager.selectTab(tab, in: windowModel)
        handleTabSwitch()
    }

    @discardableResult
    func createTab(url: String = "https://www.google.com", switchTo: Bool = true, at index: Int? = nil) -> Tab {
        let t = tabManager.createTab(in: windowModel, url: url, switchTo: switchTo, at: index)
        refreshTabs()
        if switchTo { handleTabSwitch() }
        return t
    }

    func closeTab(_ tab: Tab) {
        if tab.isFavorite {
            windowManager?.closeFavorite(tab)
            return
        }
        let id = tab.id
        let state = browserStates[id]
        tabManager.closeTab(tab, in: windowModel)
        // the page is read for reopening once it has stopped showing, which it does below
        state?.captureState { [tabManager] page in tabManager.closedTabStateCaptured(id, page) }
        if windowModel.currentTabId == nil || windowModel.currentTabId == id {
            windowModel.currentTabId = fallbackTabId(excluding: id, reopening: true)
        }
        guard windowModel.currentTabId != nil else { return closeEmptyWindow() }
        refreshTabs()
        handleTabSwitch()
    }

    // a favorite was closed: this window moves on if it was showing it
    func favoriteClosed(_ id: UUID) {
        guard currentTabId == id else { return }
        windowModel.currentTabId = fallbackTabId(excluding: id)
        guard windowModel.currentTabId != nil else { return closeEmptyWindow() }
        handleTabSwitch()
    }

    // nothing is left to show: the window goes (deferred, so the caller can unwind before the window,
    // and this controller, do). the app stays alive with no windows.
    private func closeEmptyWindow() {
        DispatchQueue.main.async { [weak self] in self?.window?.close() }
    }

    func reopenLastClosedTab() {
        guard let t = tabManager.reopenLastClosedTab(in: windowModel) else { return }
        refreshTabs()
        selectTab(t)
    }

    func openSettings() {
        _ = tabManager.openSettings(in: windowModel)
        refreshTabs()
        handleTabSwitch()
    }

    private func handleFloatingVisibilityChange() {
        if isFloatingVisible {
            sidebarOpenWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.isSidebarFullyOpen = true
                self?.sidebarVC?.trafficLights?.canHover = true
            }
            sidebarOpenWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
        } else {
            sidebarOpenWorkItem?.cancel()
            sidebarOpenWorkItem = nil
            isSidebarFullyOpen = false
            // Only disable traffic-light hover for the floating (hidden) sidebar. When docked,
            // hover is always allowed (managed by updateDockState); disabling it here would let
            // this override win the race and break the window buttons while docked.
            if !isDocked {
                sidebarVC?.trafficLights?.canHover = false
            }
        }
        animateSidebar()
    }

    @objc private func willEnterFullScreen() {
        // Hold the corners rounded for now so the hand-off from the rounded window snapshot is
        // seamless; didEnterFullScreen rounds them off.
        fullscreenCornerRadiusOverride = 9
        // Set the state but do NOT lay out yet. The window is about to resize to full size and fire
        // frameDidChange (~5ms later); letting that single resize carry the web view straight from
        // its clean windowed size to fullscreen means WebKit's resize-snapshot hold freezes
        // fully-reflowed content. Laying out here first resizes the host twice (border flip, then
        // window resize) 4ms apart, and the second hold snapshots the still-reflowing intermediate.
        setFullscreenState(true)
    }

    @objc private func didEnterFullScreen() {
        guard let layer = contentContainer.layer else { return }
        let target: CGFloat = isDocked ? 9 : 0
        fullscreenCornerRadiusOverride = nil
        let from = layer.cornerRadius
        guard from != target else { return }
        layer.cornerRadius = target
        let anim = CABasicAnimation(keyPath: "cornerRadius")
        anim.fromValue = from
        anim.toValue = target
        anim.duration = 0.4
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
        layer.add(anim, forKey: "cornerRadius")
    }

    @objc private func willExitFullScreen() {
        // Snap the corners back to rounded so the un-zoom reveals the windowed shape directly.
        fullscreenCornerRadiusOverride = nil
        contentContainer.layer?.removeAnimation(forKey: "cornerRadius")
        // Same as enter: set state without laying out, so the single un-zoom resize carries the
        // host straight from fullscreen to the clean windowed size in one reflow.
        setFullscreenState(false)
    }

    private func setFullscreenState(_ fullscreen: Bool) {
        isFullscreen = fullscreen
        if let bg = sidebarContainer.subviews.first as? SidebarFloatingBackground {
            bg.isFullscreen = fullscreen
        }
    }

    // MARK: - Sidebar Animation

    private func animateSidebar(completion: (() -> Void)? = nil) {
        // Approximate SwiftUI .spring(response: 0.35, dampingFraction: 0.8): a snappy curve
        // that accelerates quickly and settles with a slight overshoot.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 1.14, 0.5, 1.0)
            context.allowsImplicitAnimation = true
            self.layoutSubviews()

            // Animate floating background properties within the same context
            if let bg = self.sidebarContainer.subviews.first as? SidebarFloatingBackground {
                bg.updateFloatingLayout(animated: true)
            }
        }, completionHandler: completion)
    }

    // MARK: - Tab Management

    func loadTabs() {
        tabs = tabManager.orderedTabs(in: windowModel)
        favoriteTabs = tabManager.favorites()
    }

    // drops the pages of tabs that left this window, and lets go of web views this window no longer
    // shows (pages gone, or favorites another window has taken). pages are made live only when shown.
    func syncStates() {
        let ids = Set(tabs.map(\.id))
        for id in browserStates.keys where !ids.contains(id) {
            browserStates.removeValue(forKey: id)
        }
        let hostedFavorites = favoriteTabs.map(\.id).filter { favorites?.host(of: $0) === self && favorites?.state(for: $0) != nil }
        webContentVC.forgetWebViews(except: Set(browserStates.keys).union(hostedFavorites))
    }

    func updateWindowTitle() {
        guard let window = self.window else { return }
        guard let tab = currentTab else {
            window.title = "Dawn"
            return
        }
        window.title = tab.isSettings ? "Settings" : (tab.title.isEmpty ? "Untitled" : tab.title)
    }

    // MARK: - Keybinds

    func handleKeybindAction(_ action: KeybindAction) {
        if commandPaletteState.isVisible {
            switch action {
            case .closeTab:
                commandPaletteState.hide(saveText: false)
                commandPalettePanel?.hide()
            case .newTab, .focusURLBar:
                commandPaletteState.hide(saveText: action == .newTab)
                commandPalettePanel?.hide()
            default:
                break
            }
        }

        switch action {
        case .newTab:
            let recentTabs = tabs
                .filter { $0.id != currentTabId }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(5)
            commandPaletteState.show(mode: .newTab, recentTabs: Array(recentTabs))
            showCommandPalette()

        case .closeTab:
            if let tab = currentTab { closeTab(tab) }

        case .reopenClosedTab:
            reopenLastClosedTab()

        case .showDownloads:
            toggleDownloadsPanel()

        case .showWebInspector:
            currentBrowserState?.toggleWebInspector()

        case .refresh:
            currentBrowserState?.reload()

        case .goBack:
            currentBrowserState?.goBack()

        case .goForward:
            currentBrowserState?.goForward()

        case .previousTab, .nextTab:
            // through the open favorites, then the tabs, in the order the sidebar shows them
            let order = favoriteTabs.filter { !$0.favoriteClosed || $0.id == currentTabId } + tabs
            guard !order.isEmpty else { return }
            let currentIndex = order.firstIndex(where: { $0.id == currentTabId })
            let step = action == .nextTab ? 1 : -1
            let newIndex = currentIndex.map { ($0 + step + order.count) % order.count } ?? (step > 0 ? 0 : order.count - 1)
            selectTab(order[newIndex])

        case .focusURLBar:
            let recentTabs = tabs
                .filter { $0.id != currentTabId }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(5)
            commandPaletteState.show(mode: .navigate, currentURL: currentTabURL, recentTabs: Array(recentTabs))
            showCommandPalette()

        case .toggleSidebar:
            toggleDock()

        case .copyURL:
            // One binding for both shapes: a multi-selection copies all as markdown links, else the
            // current tab's url.
            if sidebarVC?.copyMultiSelectionAsMarkdown() != true {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(currentTabURL, forType: .string)
            }

        case .openSettings:
            openSettings()

        case .zoomIn:
            currentBrowserState?.zoomIn()

        case .zoomOut:
            currentBrowserState?.zoomOut()

        case .resetZoom:
            currentBrowserState?.resetZoom()
        }
    }

    func toggleDock() {
        // WebKit reflows out-of-process too slowly to track the dock animation in either direction
        // (growing flashes the page background at the trailing edge; shrinking pushes content out
        // of frame). So cover the content with a snapshot of its current state, reflow the live web
        // view to its final size behind the cover (snapped, never reflowing on screen), and fade
        // the snapshot out over the animation to reveal the settled content.
        let oldFrame = contentContainer.frame
        let oldRadius = contentContainer.layer?.cornerRadius ?? 0
        webContentVC.snapshotVisibleWebView { [weak self] image in
            self?.performDockToggle(snapshot: image, oldFrame: oldFrame, oldRadius: oldRadius)
        }
    }

    private func performDockToggle(snapshot: NSImage?, oldFrame: NSRect, oldRadius: CGFloat) {
        let oldSize = oldFrame.size

        // Cover the content with the old snapshot. It is fixed-size and clipped by the rounded
        // content container; its frame is animated explicitly (below) to stay centered as the
        // container resizes, rather than via autoresizing (which can't center a view that starts
        // out filling its parent).
        let overlay = snapshot.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            .map { cg -> NSView in
                let v = NSView(frame: contentContainer.bounds)
                v.wantsLayer = true
                v.layer?.contents = cg
                v.layer?.contentsGravity = .resize
                v.autoresizingMask = []
                contentContainer.addSubview(v)
                return v
            }

        let currentlyDocked = isDocked
        isDocked = !currentlyDocked
        let docked = isDocked
        let finalSize = finalContentSize()

        // Reflow the live web view to its final size, centered, behind the snapshot (it overflows or
        // insets the current area invisibly).
        webContentVC.pinVisibleWebViewCentered(finalSize)

        let reveal: () -> Void = { [weak self] in
            guard let self = self else { return }

            // Apply the chrome state and run the area animation now (deferred so a grow doesn't
            // open up the area before the reflow has finished).
            if currentlyDocked {
                // just undocked: keep the sidebar open only when the cursor already sits in
                // its hover hold band; otherwise it animates out with the dock transition
                // instead of hanging around until the next mouse move closes it
                var keepOpen = false
                if let frame = self.window?.frame {
                    let mouse = NSEvent.mouseLocation
                    let x = mouse.x - frame.minX
                    let withinHeight = mouse.y >= frame.minY && mouse.y <= frame.maxY
                    keepOpen = withinHeight && x >= -150 && x < CGFloat(self.sidebarWidth) + 30
                }
                if self.hoverSidebarOpen != keepOpen {
                    self.hoverSidebarOpen = keepOpen
                } else if !keepOpen {
                    self.handleFloatingVisibilityChange()
                }
            }
            if let bg = self.sidebarContainer.subviews.first as? SidebarFloatingBackground {
                bg.fullscreenSidebarRadius = self.fullscreenSidebarRadius
                bg.isFullscreen = self.isFullscreen
                bg.isDocked = self.isDocked
            }
            self.animateSidebar { [weak self] in
                self?.webContentVC.drivingWebViewSizeExternally = false
                self?.layoutSubviews()
            }

            guard let overlay = overlay else { return }
            // Keep the snapshot centered in the resizing container by animating it to the centered
            // position for the final size.
            let centeredFinal = CGRect(
                x: ((finalSize.width - oldSize.width) / 2).rounded(),
                y: ((finalSize.height - oldSize.height) / 2).rounded(),
                width: oldSize.width, height: oldSize.height
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 1.14, 0.5, 1.0)
                overlay.animator().frame = centeredFinal
            }
            // Shrink (dock) holds the snapshot until the end (fade very late, since the big snapshot
            // covers the whole shrink); grow (undock) crossfades from the start.
            let (delay, duration): (TimeInterval, TimeInterval) = docked ? (0.10, 0.18) : (0.0, 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = duration
                    overlay.animator().alphaValue = 0
                }, completionHandler: {
                    overlay.removeFromSuperview()
                })
            }
        }

        if docked {
            // Shrink: the big snapshot covers the area the whole way, so reveal immediately.
            reveal()
        } else {
            // Grow: the snapshot can't cover the new area, so wait for the reflow to actually
            // paint before opening it up.
            webContentVC.afterVisibleWebViewPaint(reveal)
        }
    }

    private func finalContentSize() -> CGSize {
        guard let rootView = rootView else { return .zero }
        let bounds = rootView.bounds
        let sidebarW = CGFloat(sidebarWidth).rounded()
        let shouldHaveBorder = !(isFullscreen && !isDocked)
        let padding: CGFloat = shouldHaveBorder ? 8 : 0
        let leadingPadding: CGFloat = isDocked ? sidebarW : padding
        return CGSize(
            width: max(0, bounds.width - leadingPadding - padding),
            height: max(0, bounds.height - padding * 2)
        )
    }

    // MARK: - Downloads

    private var isSidebarShown: Bool { isDocked || isFloatingVisible }

    // the badge launches from the click that triggered the download, or from the middle of the page
    // for keyboard-triggered ones, and lands on the sidebar's button (or a catcher tile when the
    // floating sidebar is tucked away)
    private func launchDownloadFlight() {
        guard let rootView, let window else { return }
        let start = DownloadClickTracker.shared.recentClick(in: window).map { rootView.convert($0, from: nil) }
            ?? NSPoint(x: contentContainer.frame.midX, y: contentContainer.frame.midY)
        guard isSidebarShown, let indicator = sidebarVC.downloadIndicator else {
            DownloadFlight.launchToCatcher(in: rootView, from: start)
            return
        }
        indicator.expectFlight()
        let end = rootView.convert(indicator.landingPointInWindow, from: nil)
        DownloadFlight.launch(in: rootView, from: start, to: end) { [weak indicator] in
            indicator?.flightLanded()
        }
    }

    func toggleDownloadsPanel() {
        guard let rootView, let indicator = sidebarVC.downloadIndicator else { return }
        let anchor: NSRect
        let leadingX: CGFloat
        if isSidebarShown {
            anchor = indicator.convert(indicator.bounds, to: rootView)
            leadingX = sidebarContainer.frame.minX + 8
        } else {
            anchor = NSRect(x: 14, y: 14, width: 26, height: 26)
            leadingX = 8
        }
        downloadsPanel.toggleRectInWindow = { [weak indicator] in
            guard let indicator, !indicator.isHidden else { return nil }
            return indicator.convert(indicator.bounds, to: nil)
        }
        downloadsPanel.toggle(in: rootView, anchor: anchor, leadingX: leadingX)
    }

    // MARK: - Command Palette

    func showCommandPalette() {
        if commandPalettePanel == nil {
            let panel = CommandPalettePanel(state: commandPaletteState)
            panel.onSubmit = { [weak self] type in
                self?.handleCommandPaletteSubmit(type)
            }
            panel.onSwitchToTab = { [weak self] tab in
                self?.selectTab(tab)
                self?.commandPaletteState.hide()
                self?.commandPalettePanel?.hide()
            }
            panel.onDismiss = { [weak self] in
                self?.commandPaletteState.hide()
                self?.commandPalettePanel?.hide()
            }
            commandPalettePanel = panel
        }
        commandPalettePanel?.show(in: rootView)
    }

    func handleCommandPaletteSubmit(_ suggestionType: SuggestionType) {
        let mode = commandPaletteState.mode
        commandPaletteState.hide(saveText: false)
        commandPalettePanel?.hide()

        var urlToLoad: String

        switch suggestionType {
        case .searchSuggestion(let query):
            if let url = SearchEngineStore.shared.searchURL(for: query) {
                urlToLoad = url.absoluteString
            } else {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                urlToLoad = "https://www.google.com/search?q=\(encoded)"
            }
        case .directURL(let url):
            urlToLoad = withDefaultScheme(url)
        case .dnsResolved(let hostname):
            urlToLoad = "http://\(hostname)"
        case .historyEntry(_, let url):
            urlToLoad = url
        case .recentTab(let tab):
            selectTab(tab)
            return
        }

        if urlToLoad.lowercased().hasPrefix("dawn://") {
            openSettings()
            let path = String(urlToLoad.dropFirst("dawn://".count))
            if !path.isEmpty && path != "settings" {
                tabManager.updateSettingsPath(path, in: windowModel)
            }
            return
        }

        if mode == .newTab {
            createTab(url: urlToLoad, switchTo: true)
        } else {
            currentBrowserState?.loadURL(urlToLoad)
        }
    }
}

// MARK: - SidebarDelegate

extension MainWindowController: SidebarDelegate {
    func sidebarDidSelectTab(_ tab: Tab) {
        selectTab(tab)
    }

    func sidebarDidRequestCloseTab(_ tab: Tab) {
        closeTab(tab)
    }

    func sidebarDidRequestNewTab() {
        handleKeybindAction(.newTab)
    }

    func sidebarDidToggleDock() {
        toggleDock()
    }

    func sidebarDidRequestBack() {
        currentBrowserState?.goBack()
    }

    func sidebarDidRequestForward() {
        currentBrowserState?.goForward()
    }

    func sidebarDidRequestReload() {
        if let state = currentBrowserState {
            if state.isLoading { state.stopLoading() } else { state.reload() }
        }
    }

    func sidebarDidSubmitURL(_ url: String) {
        if url.lowercased().hasPrefix("dawn://") {
            openSettings()
        } else if let state = currentBrowserState {
            state.loadURL(url)
        } else {
            // a window without tabs gets one for what was typed
            let tab = createTab(url: "about:blank", switchTo: true)
            state(for: tab.id)?.loadURL(url)
        }
    }

    // A pile dropped outside this window's tab list: commit the move (into the window under the cursor,
    // or a new torn-off one) and return that window's sidebar to adopt the live pile. nil -> spring home.
    func sidebarHandOffPile(_ ids: [UUID], at screenPoint: CGPoint) -> SidebarViewController? {
        windowManager?.handOffPile(ids, from: self, at: screenPoint)
    }

    func sidebarTabDragMoved(toScreen screenPoint: CGPoint, ids: [UUID]) {
        let favorites = Set(ids.filter { tab(for: $0)?.isFavorite == true })
        windowManager?.tabDragMoved(to: screenPoint, source: self, pileSize: ids.count, favorites: favorites)
    }

    func sidebarTabDragEnded() {
        windowManager?.tabDragEnded()
    }

    func sidebarDidRequestDownloads() {
        toggleDownloadsPanel()
    }

    func sidebarCardTarget(atScreen screenPoint: CGPoint) -> (shape: CardShape, size: CGSize)? {
        windowManager?.topmostController(under: screenPoint)?.sidebar?.cardTarget(atScreen: screenPoint)
    }

    func sidebarIsLive(_ id: UUID) -> Bool {
        state(for: id) != nil
    }

    func sidebarDidPin(_ ids: [UUID], at index: Int) {
        windowManager?.pin(ids, from: self, at: index)
    }

    func sidebarDidReorderFavorites(_ orderedIds: [UUID]) {
        windowManager?.reorderFavorites(orderedIds)
    }

    func sidebarDidUnpin(_ id: UUID, at index: Int) {
        windowManager?.unpin(id, into: self, at: index)
    }

    func sidebarHandOffFavorite(_ id: UUID, at screenPoint: CGPoint) -> SidebarViewController? {
        windowManager?.handOffFavorite(id, from: self, at: screenPoint)
    }

    func sidebarMenu(for ids: [UUID]) -> NSMenu? {
        let targets = ids.compactMap { tab(for: $0) }
        guard let first = targets.first else { return nil }
        let menu = NSMenu()
        let many = targets.count > 1
        func add(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.runAction), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let live = { (tab: Tab) in self.state(for: tab.id) != nil }
        let url = { (tab: Tab) in self.state(for: tab.id)?.currentURL?.absoluteString ?? tab.url }
        menu.autoenablesItems = false

        if first.isFavorite {
            add("Unpin Tab") { [weak self] in self?.unpinFromMenu(first.id) }
        } else {
            let pinnable = targets.filter { !$0.isSettings }
            add(many ? "Pin \(pinnable.count) Tabs" : "Pin Tab", enabled: !pinnable.isEmpty) { [weak self] in
                self?.pinFromMenu(pinnable.map(\.id))
            }
        }
        menu.addItem(.separator())
        add(many ? "Reload \(targets.count) Tabs" : "Reload Tab", enabled: targets.contains(where: live)) { [weak self] in
            for tab in targets { self?.state(for: tab.id)?.reload() }
        }
        // copies go right after what they copy (a favorite's at the top of the tabs), the way they read
        add(many ? "Duplicate \(targets.count) Tabs" : "Duplicate Tab", enabled: !targets.contains(where: \.isSettings)) { [weak self] in
            guard let self else { return }
            let after = targets.compactMap { tab in self.tabs.firstIndex(where: { $0.id == tab.id }) }.max().map { $0 + 1 } ?? 0
            for (offset, tab) in targets.enumerated() { self.createTab(url: url(tab), switchTo: !many, at: after + offset) }
        }
        add(many ? "Copy Links" : "Copy Link") {
            let text = many ? targets.map { "[\($0.title.isEmpty ? "Untitled" : $0.title)](\(url($0)))" }.joined(separator: "\n") : url(first)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if !first.isFavorite {
            menu.addItem(.separator())
            add("Move to New Window") { [weak self] in
                guard let self else { return }
                self.windowManager?.moveToNewWindow(targets.map(\.id), from: self)
            }
        }
        menu.addItem(.separator())
        add(many ? "Close \(targets.count) Tabs" : "Close Tab", enabled: !first.isFavorite || live(first)) { [weak self] in
            for tab in targets { self?.closeTab(tab) }
        }
        if !first.isFavorite, !many {
            add("Close Other Tabs", enabled: tabs.count > 1) { [weak self] in
                guard let self else { return }
                for tab in self.tabs.filter({ $0.id != first.id }) { self.closeTab(tab) }
            }
        }
        return menu
    }

    // pins tabs from the menu: each row flies up into its new tile
    private func pinFromMenu(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let rects = sidebarVC.screenRects(for: ids)
        sidebarVC.prepareMove(ids)
        windowManager?.pin(ids, from: self, at: favoriteTabs.count)
        sidebarVC.animateMove(ids, from: rects, shape: .row)
    }

    // unpins a favorite from the menu: its tile flies down into the top of this window's tabs
    private func unpinFromMenu(_ id: UUID) {
        let rects = sidebarVC.screenRects(for: [id])
        sidebarVC.prepareMove([id])
        windowManager?.unpin(id, into: self, at: 0)
        sidebarVC.animateMove([id], from: rects, shape: .tile)
    }

    func sidebarDidReorderTabs(_ orderedTabIds: [UUID]) {
        for (index, id) in orderedTabIds.enumerated() {
            if let tab = tabs.first(where: { $0.id == id }) {
                tab.sortIndex = index
            }
        }
        // Persist lazily (debounced) rather than a synchronous save here - a blocking disk flush froze
        // the drop animation. The in-memory order is already applied; quit/idle saves cover durability.
        tabManager.scheduleSave()
    }
}

// a menu item's action, kept alive by the item
final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func runAction() {
        run()
    }
}

// MARK: - Sidebar Container

/// Holds the floating-sidebar background and the sidebar view. Hit testing is disabled while
/// the sidebar is sliding/off-screen so clicks pass through to the web content underneath.
class SidebarContainerView: NSView {
    var hitTestEnabled = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestEnabled else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Sidebar Floating Background

class SidebarFloatingBackground: NSView {
    var isDocked: Bool = true {
        didSet {
            guard oldValue != isDocked else { return }
            animateDockedChange()
        }
    }
    var isFullscreen: Bool = false {
        didSet { updateFloatingLayout(animated: false) }
    }
    var fullscreenSidebarRadius: Int = 13 {
        didSet { updateFloatingLayout(animated: false) }
    }

    private let effectView: NSVisualEffectView
    private let darkOverlay: NSView
    private let borderLayer = CAShapeLayer()

    override init(frame: NSRect) {
        effectView = NSVisualEffectView()
        // Original: .thinMaterial
        effectView.material = .popover
        effectView.blendingMode = .withinWindow
        effectView.state = .active

        darkOverlay = NSView()
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8).cgColor

        super.init(frame: frame)
        wantsLayer = true
        // No masksToBounds here: the effect/overlay subviews are individually rounded, and
        // clipping the parent would also clip the panel's soft drop shadow.

        addSubview(effectView)
        addSubview(darkOverlay)

        layer?.addSublayer(borderLayer)
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        borderLayer.lineWidth = 1

        // Start hidden (docked)
        effectView.alphaValue = 0
        darkOverlay.alphaValue = 0
        borderLayer.opacity = 0
        layer?.shadowOpacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    private var dockGeneration = 0

    private func animateDockedChange() {
        dockGeneration += 1
        let generation = dockGeneration
        let targetAlpha: CGFloat = isDocked ? 0 : 1

        // Panel material/overlay: when docking it lingers (0.2s delay) so it fades into the
        // docked background; when undocking it appears immediately.
        let runPanel = {
            guard generation == self.dockGeneration else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
                ctx.allowsImplicitAnimation = true
                self.effectView.alphaValue = targetAlpha
                self.darkOverlay.alphaValue = targetAlpha
            }
        }
        if isDocked {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: runPanel)
        } else {
            runPanel()
        }

        // Border: the light edge reads as a vertical line between sidebar and content while the
        // corner morphs. So fade it out fast and immediately when docking, and fade it back in
        // late (after the panel settles) when undocking.
        let borderDelay: TimeInterval = isDocked ? 0 : 0.22
        let borderDuration: TimeInterval = isDocked ? 0.1 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + borderDelay) {
            guard generation == self.dockGeneration else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = borderDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.borderLayer.opacity = Float(targetAlpha)
            }
        }
    }


    /// Update frame positions for floating/docked state.
    /// Call within an animation context for smooth transitions.
    func updateFloatingLayout(animated: Bool) {
        let inset: CGFloat = isDocked ? 0 : 4
        let radius: CGFloat = isDocked ? 0 : CGFloat(isFullscreen ? fullscreenSidebarRadius : 13)
        let rect = bounds.insetBy(dx: inset, dy: inset)

        effectView.frame = rect
        effectView.layer?.cornerRadius = radius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        darkOverlay.frame = rect
        darkOverlay.layer?.cornerRadius = radius
        darkOverlay.layer?.cornerCurve = .continuous
        darkOverlay.layer?.masksToBounds = true

        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        borderLayer.path = path.cgPath
        borderLayer.frame = bounds
    }

    override func layout() {
        super.layout()
        updateFloatingLayout(animated: false)
    }
}

// MARK: - NSBezierPath CGPath Extension

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)

        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            @unknown default: break
            }
        }

        return path
    }
}
