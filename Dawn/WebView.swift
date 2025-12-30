import SwiftUI
import WebKit
import AppKit

// MARK: - Non-Draggable Hosting View
/// NSHostingView subclass that prevents window dragging from its content
class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Let SwiftUI handle the event, don't propagate to parent
        super.mouseDown(with: event)
    }
}

// MARK: - Web View Container
struct WebViewContainer: View {
    var tabs: [Tab]
    var browserStates: [UUID: BrowserState]
    var currentTabId: UUID?
    var isDocked: Bool
    var webLeftPadding: CGFloat

    var body: some View {
        AnimatedWebContainerRepresentable(
            tabs: tabs,
            browserStates: browserStates,
            currentTabId: currentTabId,
            leadingInset: webLeftPadding + 8,
            isDocked: isDocked
        )
        .ignoresSafeArea()
    }
}

// MARK: - Animated Web Container (NSViewRepresentable)
struct AnimatedWebContainerRepresentable: NSViewRepresentable {
    var tabs: [Tab]
    var browserStates: [UUID: BrowserState]
    var currentTabId: UUID?
    var leadingInset: CGFloat
    var isDocked: Bool

    func makeNSView(context: Context) -> AnimatedWebContainerView {
        let container = AnimatedWebContainerView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ nsView: AnimatedWebContainerView, context: Context) {
        // Detect if this is a dock toggle (animate) vs resize drag (immediate)
        // Don't animate on first update (lastDockedState is nil)
        let isToggle = nsView.lastDockedState != nil && nsView.lastDockedState != isDocked
        nsView.lastDockedState = isDocked

        nsView.setLeadingInset(leadingInset, animated: isToggle)
        nsView.updateWebViews(
            tabs: tabs,
            browserStates: browserStates,
            currentTabId: currentTabId
        )
    }
}

// MARK: - Animated Web Container View (AppKit)
class AnimatedWebContainerView: NSView {
    private var currentLeadingInset: CGFloat = 8
    private var webViewWrappers: [UUID: WebViewWrapper] = [:]
    private var currentTabId: UUID?
    private var currentTabIsSettings: Bool = false
    private var isAnimating = false
    private var hasLaidOutOnce = false
    var lastDockedState: Bool? = nil

    private var displayLink: CADisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0.35
    private var animationStartInset: CGFloat = 0
    private var animationEndInset: CGFloat = 0

    private lazy var backgroundView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8).cgColor
        v.layer?.cornerRadius = 9
        v.layer?.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        return v
    }()

    private lazy var settingsHostingView: NonDraggableHostingView<SettingsView> = {
        let hv = NonDraggableHostingView(rootView: SettingsView())
        hv.wantsLayer = true
        hv.layer?.cornerRadius = 9
        hv.layer?.masksToBounds = true
        hv.layer?.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        // Disable safe area insets - settings view handles its own padding
        if #available(macOS 13.3, *) {
            hv.safeAreaRegions = []
        }
        return hv
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(backgroundView)
        addSubview(settingsHostingView)
        settingsHostingView.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Don't allow dragging/zooming when settings view is visible
        if currentTabIsSettings {
            return
        }

        if event.clickCount == 2 {
            self.window?.zoom(nil)
        } else {
            self.window?.performDrag(with: event)
        }
    }

    func setLeadingInset(_ newInset: CGFloat, animated: Bool) {
        let oldInset = currentLeadingInset

        guard animated && hasLaidOutOnce && abs(oldInset - newInset) > 1 && !bounds.isEmpty else {
            currentLeadingInset = newInset
            layoutAllWebViews()
            return
        }

        startSyncedResizeAnimation(from: oldInset, to: newInset)
    }

    private func startSyncedResizeAnimation(from startInset: CGFloat, to endInset: CGFloat) {
        stopAnimation()

        animationStartInset = startInset
        animationEndInset = endInset
        currentLeadingInset = endInset
        isAnimating = true

        // Tell ONLY the visible WebView we're starting live resize (if not settings)
        // This triggers WKWebView's optimized rendering path
        if !currentTabIsSettings, let visibleId = currentTabId, let wrapper = webViewWrappers[visibleId] {
            wrapper.webView?.viewWillStartLiveResize()
        }

        animationStartTime = CACurrentMediaTime()

        // Create display link from this view (modern macOS 14+ API)
        displayLink = self.displayLink(target: self, selector: #selector(animationTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func animationTick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let progress = min(1.0, elapsed / animationDuration)

        // Ease in-out cubic
        let easedProgress: CGFloat
        if progress < 0.5 {
            easedProgress = CGFloat(4 * progress * progress * progress)
        } else {
            let t = progress - 1
            easedProgress = CGFloat(1 + 4 * t * t * t)
        }

        // Interpolate inset
        let currentInset = animationStartInset + (animationEndInset - animationStartInset) * easedProgress
        let frame = NSIntegralRect(calculateContentFrame(withLeadingInset: currentInset))

        // Update frames synchronously (disable implicit animations)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        backgroundView.frame = frame

        // Only resize the VISIBLE view during animation
        if currentTabIsSettings {
            settingsHostingView.frame = frame
        } else if let visibleId = currentTabId, let wrapper = webViewWrappers[visibleId] {
            wrapper.frame = frame
        }

        CATransaction.commit()

        if progress >= 1.0 {
            finishAnimation()
        }
    }

    private func finishAnimation() {
        stopAnimation()
        isAnimating = false

        // Tell the visible WebView live resize is done (if not settings)
        if !currentTabIsSettings, let visibleId = currentTabId, let wrapper = webViewWrappers[visibleId] {
            wrapper.webView?.viewDidEndLiveResize()
        }

        // Now resize ALL hidden views to final size (they weren't touched during animation)
        layoutAllWebViews()
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func calculateContentFrame(withLeadingInset leadingInset: CGFloat) -> NSRect {
        let left = leadingInset
        let bottom: CGFloat = 8
        let rightEdge = bounds.width - 8
        let topEdge = bounds.height - 8

        return NSRect(x: left, y: bottom, width: max(0, rightEdge - left), height: max(0, topEdge - bottom))
    }

    private func layoutAllWebViews() {
        guard !isAnimating else { return }
        let frame = NSIntegralRect(calculateContentFrame(withLeadingInset: currentLeadingInset))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.frame = frame
        settingsHostingView.frame = frame
        for (_, wrapper) in webViewWrappers {
            wrapper.frame = frame
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        if !isAnimating {
            layoutAllWebViews()
        }
        hasLaidOutOnce = true
    }

    func updateWebViews(tabs: [Tab], browserStates: [UUID: BrowserState], currentTabId: UUID?) {
        self.currentTabId = currentTabId

        // Check if current tab is settings
        let currentTab = tabs.first { $0.id == currentTabId }
        currentTabIsSettings = currentTab?.isSettings ?? false

        // Only manage web view wrappers for non-settings tabs
        let webTabs = tabs.filter { !$0.isSettings }
        let webTabIds = Set(webTabs.map { $0.id })

        for tab in webTabs {
            if webViewWrappers[tab.id] == nil, let state = browserStates[tab.id] {
                let wrapper = WebViewWrapper(browserState: state)
                wrapper.wantsLayer = true
                wrapper.layer?.cornerRadius = 9
                wrapper.layer?.masksToBounds = true
                wrapper.layer?.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
                wrapper.frame = NSIntegralRect(calculateContentFrame(withLeadingInset: currentLeadingInset))
                addSubview(wrapper, positioned: .above, relativeTo: backgroundView)
                webViewWrappers[tab.id] = wrapper
            }
        }

        for id in webViewWrappers.keys {
            if !webTabIds.contains(id) {
                webViewWrappers[id]?.removeFromSuperview()
                webViewWrappers.removeValue(forKey: id)
            }
        }

        // Show/hide based on whether current tab is settings or web
        if currentTabIsSettings {
            // Show settings, hide all web views
            settingsHostingView.isHidden = false
            for (_, wrapper) in webViewWrappers {
                wrapper.isHidden = true
            }
            // Set background color for settings
            backgroundView.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0).cgColor
        } else {
            // Hide settings, show correct web view
            settingsHostingView.isHidden = true
            for (id, wrapper) in webViewWrappers {
                wrapper.isHidden = (id != currentTabId)
            }
            // Update background color from web view
            if let id = currentTabId, let state = browserStates[id] {
                updateBackgroundColor(from: state)
            }
        }
    }

    private func updateBackgroundColor(from state: BrowserState) {
        DispatchQueue.main.async { [weak self] in
            if let webView = state.webView, let themeColor = webView.themeColor {
                self?.backgroundView.layer?.backgroundColor = themeColor.cgColor
            }
        }
    }

    deinit {
        stopAnimation()
    }
}

// MARK: - WebView Wrapper
class WebViewWrapper: NSView {
    let browserState: BrowserState
    private(set) var webView: WKWebView?  // Exposed for live resize calls
    private var coordinator: WebViewCoordinator?

    init(browserState: BrowserState) {
        self.browserState = browserState
        super.init(frame: .zero)
        setupWebView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let script = """
        let scrollTimeout;
        window.addEventListener('scroll', () => {
            if (!scrollTimeout) {
                scrollTimeout = setTimeout(() => {
                    window.webkit.messageHandlers.scrollHandler.postMessage({
                        x: window.scrollX,
                        y: window.scrollY
                    });
                    scrollTimeout = null;
                }, 1000);
            }
        });

        function sendColor() {
            if (document.querySelector('meta[name="theme-color"]')) return;
            let bodyStyle = window.getComputedStyle(document.body);
            let colorStr = bodyStyle.backgroundColor;
            if (colorStr === 'rgba(0, 0, 0, 0)' || colorStr === 'transparent') {
                colorStr = window.getComputedStyle(document.documentElement).backgroundColor;
            }
            let rgba = colorStr.match(/\\d+(\\.\\d+)?/g);
            if (rgba && rgba.length >= 3) {
                window.webkit.messageHandlers.colorHandler.postMessage({
                    r: parseFloat(rgba[0]), g: parseFloat(rgba[1]), b: parseFloat(rgba[2]),
                    a: rgba[3] ? parseFloat(rgba[3]) : 1.0
                });
            } else {
                window.webkit.messageHandlers.colorHandler.postMessage({r: 255, g: 255, b: 255, a: 1.0});
            }
        }
        window.addEventListener('pageshow', () => { sendColor(); });
        const observer = new MutationObserver(() => { sendColor(); });
        observer.observe(document.body, { attributes: true, attributeFilter: ['style', 'class'] });
        observer.observe(document.documentElement, { attributes: true, attributeFilter: ['style', 'class'] });
        """

        let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)

        let coord = WebViewCoordinator(state: browserState)
        self.coordinator = coord

        config.userContentController.add(coord, name: "scrollHandler")
        config.userContentController.add(coord, name: "colorHandler")

        let w = WKWebView(frame: bounds, configuration: config)
        w.navigationDelegate = coord
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true

        // Use autoresizing mask - this is how window resize works smoothly
        w.autoresizingMask = [.width, .height]

        if let data = browserState.restorationData {
            w.interactionState = data
            browserState.restorationData = nil
        } else if let url = browserState.pendingURL {
            w.load(URLRequest(url: url))
            browserState.pendingURL = nil
        }

        w.addObserver(coord, forKeyPath: "loading", options: .new, context: nil)
        w.addObserver(coord, forKeyPath: "title", options: .new, context: nil)
        w.addObserver(coord, forKeyPath: "URL", options: .new, context: nil)
        w.addObserver(coord, forKeyPath: "themeColor", options: .new, context: nil)

        browserState.webView = w
        self.webView = w
        addSubview(w)
    }

    override func layout() {
        super.layout()
        // autoresizingMask handles the webview frame
    }

    deinit {
        if let w = webView, let coord = coordinator {
            w.removeObserver(coord, forKeyPath: "loading")
            w.removeObserver(coord, forKeyPath: "title")
            w.removeObserver(coord, forKeyPath: "URL")
            w.removeObserver(coord, forKeyPath: "themeColor")
        }
    }
}

// MARK: - WebView Coordinator
class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var state: BrowserState

    init(state: BrowserState) {
        self.state = state
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(saveStateSnapshot), name: NSApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(saveStateSnapshot), name: NSApplication.willTerminateNotification, object: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "scrollHandler",
           let dict = message.body as? [String: Double],
           let x = dict["x"], let y = dict["y"] {
            state.tabManager?.updateTab(state.tabId, scroll: CGPoint(x: x, y: y))
        }
        if message.name == "colorHandler", let dict = message.body as? [String: Double] {
            if state.webView?.themeColor == nil {
                DispatchQueue.main.async {
                    self.state.backgroundColor = Color.from(dict: dict)
                }
            }
        }
    }

    @objc func saveStateSnapshot() {
        guard let w = state.webView else { return }
        let iState = w.interactionState as? Data
        let zoom = w.magnification
        state.tabManager?.updateTab(state.tabId, interactionState: iState, zoom: zoom)
        state.tabManager?.saveNow()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let w = object as? WKWebView else { return }

        if keyPath == "loading" {
            DispatchQueue.main.async {
                self.state.isLoading = w.isLoading
                self.state.canGoBack = w.canGoBack
                self.state.canGoForward = w.canGoForward
                if !w.isLoading { self.saveStateSnapshot() }
            }
        }

        if keyPath == "URL" {
            DispatchQueue.main.async {
                self.state.tabManager?.updateTab(self.state.tabId, url: w.url?.absoluteString)
            }
        }

        if keyPath == "title" {
            DispatchQueue.main.async {
                let newTitle = w.title
                let titleToUpdate = (newTitle?.isEmpty == false) ? newTitle : nil
                self.state.tabManager?.updateTab(self.state.tabId, title: titleToUpdate)
            }
        }

        if keyPath == "themeColor" {
            DispatchQueue.main.async {
                if let theme = w.themeColor {
                    self.state.backgroundColor = Color(nsColor: theme)
                } else {
                    w.evaluateJavaScript("sendColor()")
                }
            }
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        state.isLoading = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            if let scroll = self.state.savedScroll {
                w.evaluateJavaScript("window.scrollTo(\(scroll.x), \(scroll.y))")
            }
            if let zoom = self.state.savedZoom, zoom != 1.0 {
                w.setMagnification(zoom, centeredAt: .zero)
            }
            w.evaluateJavaScript("sendColor()")
        }
        saveStateSnapshot()
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        state.isLoading = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
