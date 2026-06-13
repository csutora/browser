import AppKit
import SwiftData
import Combine
import WebKit

class MainWindowController: NSWindowController {
    let tabManager: TabManager
    let historyManager: HistoryManager
    let modelContext: ModelContext

    let mouseTracker = MouseTracker()
    let keybindHandler = KeybindHandler.shared
    let commandPaletteState = CommandPaletteState()

    var browserStates: [UUID: BrowserState] = [:]
    var tabs: [Tab] = []

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

    var isDocked: Bool {
        get { UserDefaults.standard.bool(forKey: "isDocked") }
        set {
            UserDefaults.standard.set(newValue, forKey: "isDocked")
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

    var isFloatingVisible: Bool {
        if isDocked { return false }
        if isResizing { return true }
        return mouseTracker.shouldShowSidebar
    }

    var sidebarOffset: CGFloat {
        isDocked ? 0 : (isFloatingVisible ? 0 : -(CGFloat(sidebarWidth) + 50))
    }

    // MARK: - Init

    init(tabManager: TabManager, historyManager: HistoryManager, modelContext: ModelContext) {
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.modelContext = modelContext

        let window = Self.createWindow()
        super.init(window: window)

        setupViews()
        setupObservers()
        setupKeybindHandler()

        commandPaletteState.historyManager = historyManager

        loadTabs()

        if tabManager.currentTabId == nil {
            if let first = tabs.first {
                tabManager.selectTab(first)
            }
        }

        sidebarVC.reloadTabs(tabs)
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
        window.center()
        window.setFrameAutosaveName("MainWindow")
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
            self.mouseTracker.updateSettings(sidebarWidth: self.sidebarWidth, isDocked: self.isDocked)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(tabsDidChange),
            name: .tabsDidChange, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(tabDataDidChange(_:)),
            name: .tabDataDidChange, object: nil
        )

        tabManager.$currentTabIdString.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTabSwitch()
            }
        }.store(in: &cancellables)

        tabManager.$currentTabURL.sink { [weak self] url in
            self?.sidebarVC?.updateURLBar(url)
        }.store(in: &cancellables)

        // @Published emits in willSet (before the stored value updates), so a synchronous
        // sink that re-reads shouldShowSidebar would see the previous value. Hop to the main
        // queue so the assignment has committed before we read it back through sidebarOffset.
        mouseTracker.$shouldShowSidebar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleFloatingVisibilityChange()
            }.store(in: &cancellables)

        mouseTracker.window = window
        mouseTracker.updateSettings(sidebarWidth: sidebarWidth, isDocked: isDocked)

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
    }

    @objc private func tabsDidChange() {
        loadTabs()
        syncStates()
        sidebarVC.reloadTabs(tabs)
        updateWindowTitle()
    }

    @objc private func tabDataDidChange(_ notification: Notification) {
        if let tabId = notification.object as? UUID {
            sidebarVC.updateTab(tabId)
        }
        updateWindowTitle()
    }

    private func handleTabSwitch() {
        webContentVC.switchToTab(
            tabManager.currentTabId,
            browserStates: browserStates,
            tabs: tabs
        )
        sidebarVC.updateSelection()
        sidebarVC.updateNavState(for: browserStates[tabManager.currentTabId ?? UUID()])
        observeCurrentBrowserState()
        updateWindowTitle()
    }

    private func observeCurrentBrowserState() {
        browserStateCancellables.removeAll()

        guard let currentId = tabManager.currentTabId,
              let state = browserStates[currentId] else { return }

        Publishers.CombineLatest3(state.$canGoBack, state.$canGoForward, state.$isLoading)
            .sink { [weak self, weak state] _, _, _ in
                guard let state = state else { return }
                self?.sidebarVC.updateNavState(for: state)
            }
            .store(in: &browserStateCancellables)
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
        tabs = tabManager.fetchTabs()
        if tabs.isEmpty {
            tabManager.createTab(existingCount: 0, switchToTab: true)
            tabs = tabManager.fetchTabs()
        }
    }

    func syncStates() {
        for tab in tabs where !tab.isSettings {
            if browserStates[tab.id] == nil {
                let initialURL = URL(string: tab.url)
                let s = BrowserState(
                    tabId: tab.id,
                    tabManager: tabManager,
                    historyManager: historyManager,
                    initialURL: initialURL,
                    interactionState: tab.interactionState
                )
                s.onNewTabRequested = { [weak self] url, switchToTab in
                    guard let self = self else { return }
                    self.tabManager.createTab(
                        url: url.absoluteString,
                        existingCount: self.tabs.count,
                        switchToTab: switchToTab
                    )
                }
                browserStates[tab.id] = s
            }
        }
        let activeWebTabIds = Set(tabs.filter { !$0.isSettings }.map { $0.id })
        for id in browserStates.keys where !activeWebTabIds.contains(id) {
            browserStates.removeValue(forKey: id)
        }

        webContentVC.syncWebViews(
            browserStates: browserStates,
            tabs: tabs,
            currentTabId: tabManager.currentTabId
        )
    }

    func updateWindowTitle() {
        guard let window = self.window else { return }
        guard let currentId = tabManager.currentTabId,
              let currentTab = tabs.first(where: { $0.id == currentId }) else {
            window.title = "Dawn"
            return
        }
        window.title = currentTab.isSettings ? "Settings" : (currentTab.title.isEmpty ? "Untitled" : currentTab.title)
    }

    // MARK: - Keybinds

    private func setupKeybindHandler() {
        keybindHandler.onAction = { [weak self] action in
            self?.handleKeybindAction(action)
        }
        keybindHandler.start()
    }

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
                .filter { $0.id != tabManager.currentTabId }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(5)
            commandPaletteState.show(mode: .newTab, recentTabs: Array(recentTabs))
            showCommandPalette()

        case .closeTab:
            guard let currentId = tabManager.currentTabId,
                  let tab = tabs.first(where: { $0.id == currentId }) else { return }
            let interactionState = browserStates[currentId]?.captureInteractionState()
            tabManager.closeTab(tab, allTabs: tabs, interactionState: interactionState)

        case .reopenClosedTab:
            tabManager.reopenLastClosedTab(existingCount: tabs.count)

        case .refresh:
            browserStates[tabManager.currentTabId ?? UUID()]?.reload()

        case .goBack:
            browserStates[tabManager.currentTabId ?? UUID()]?.goBack()

        case .goForward:
            browserStates[tabManager.currentTabId ?? UUID()]?.goForward()

        case .previousTab:
            guard let currentId = tabManager.currentTabId,
                  let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
            let newIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
            if newIndex >= 0 && newIndex < tabs.count {
                tabManager.selectTab(tabs[newIndex])
            }

        case .nextTab:
            guard let currentId = tabManager.currentTabId,
                  let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
            let newIndex = currentIndex < tabs.count - 1 ? currentIndex + 1 : 0
            if newIndex >= 0 && newIndex < tabs.count {
                tabManager.selectTab(tabs[newIndex])
            }

        case .focusURLBar:
            let recentTabs = tabs
                .filter { $0.id != tabManager.currentTabId }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(5)
            commandPaletteState.show(mode: .navigate, currentURL: tabManager.currentTabURL, recentTabs: Array(recentTabs))
            showCommandPalette()

        case .toggleSidebar:
            toggleDock()

        case .copyURL:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tabManager.currentTabURL, forType: .string)

        case .openSettings:
            tabManager.openSettings()

        case .zoomIn:
            browserStates[tabManager.currentTabId ?? UUID()]?.zoomIn()

        case .zoomOut:
            browserStates[tabManager.currentTabId ?? UUID()]?.zoomOut()

        case .resetZoom:
            browserStates[tabManager.currentTabId ?? UUID()]?.resetZoom()
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
                self.mouseTracker.shouldShowSidebar = true
            }
            self.mouseTracker.updateSettings(sidebarWidth: self.sidebarWidth, isDocked: self.isDocked)
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

    // MARK: - Command Palette

    func showCommandPalette() {
        if commandPalettePanel == nil {
            let panel = CommandPalettePanel(state: commandPaletteState)
            panel.onSubmit = { [weak self] type in
                self?.handleCommandPaletteSubmit(type)
            }
            panel.onSwitchToTab = { [weak self] tab in
                self?.tabManager.selectTab(tab)
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
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            urlToLoad = "https://www.google.com/search?q=\(encoded)"
        case .directURL(let url):
            urlToLoad = url.contains("://") ? url : "https://\(url)"
        case .dnsResolved(let hostname):
            urlToLoad = "http://\(hostname)"
        case .historyEntry(_, let url):
            urlToLoad = url
        case .recentTab(let tab):
            tabManager.selectTab(tab)
            return
        }

        if urlToLoad.lowercased().hasPrefix("dawn://") {
            tabManager.openSettings()
            let path = String(urlToLoad.dropFirst("dawn://".count))
            if !path.isEmpty && path != "settings" {
                tabManager.updateSettingsPath(path)
            }
            return
        }

        if mode == .newTab {
            tabManager.createTab(url: urlToLoad, existingCount: tabs.count, switchToTab: true)
        } else {
            browserStates[tabManager.currentTabId ?? UUID()]?.loadURL(urlToLoad)
        }
    }
}

// MARK: - SidebarDelegate

extension MainWindowController: SidebarDelegate {
    func sidebarDidSelectTab(_ tab: Tab) {
        tabManager.selectTab(tab)
    }

    func sidebarDidRequestCloseTab(_ tab: Tab) {
        let interactionState = browserStates[tab.id]?.captureInteractionState()
        tabManager.closeTab(tab, allTabs: tabs, interactionState: interactionState)
    }

    func sidebarDidRequestNewTab() {
        handleKeybindAction(.newTab)
    }

    func sidebarDidToggleDock() {
        toggleDock()
    }

    func sidebarDidRequestBack() {
        browserStates[tabManager.currentTabId ?? UUID()]?.goBack()
    }

    func sidebarDidRequestForward() {
        browserStates[tabManager.currentTabId ?? UUID()]?.goForward()
    }

    func sidebarDidRequestReload() {
        if let state = browserStates[tabManager.currentTabId ?? UUID()] {
            if state.isLoading { state.stopLoading() } else { state.reload() }
        }
    }

    func sidebarDidSubmitURL(_ url: String) {
        if url.lowercased().hasPrefix("dawn://") {
            tabManager.openSettings()
        } else {
            browserStates[tabManager.currentTabId ?? UUID()]?.loadURL(url)
        }
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
