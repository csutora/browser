import AppKit
import WebKit
import Combine

// webkit takes mouse moves through a rect-based tracking area, so it keeps hovering the page and
// setting the page's cursor even where native views (the floating sidebar, the command palette)
// cover it. only let moves through when the page is actually the topmost view under the pointer.
final class DawnWebView: WKWebView {
    private var pointerOverPage = false

    // what was dropped on the page, held while webkit decides whether the page takes it. if webkit
    // instead loads the drop itself, the navigation delegate claims it and dawn opens it, so dropped
    // files get a lasting grant and every dropped file opens, not only the first.
    private var pendingDrop: [URL] = []
    private var pendingDropExpiry: DispatchWorkItem?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pendingDrop = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        pendingDropExpiry?.cancel()
        return super.performDragOperation(sender)
    }

    func claimDrop(loading url: URL) -> [URL]? {
        func same(_ a: URL, _ b: URL) -> Bool {
            guard a.isFileURL, b.isFileURL else { return a == b }
            return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
        }
        guard pendingDrop.contains(where: { same($0, url) }) else { return nil }
        return takeDrop()
    }

    // webkit reports the drop as handled both when the page took it and when it loads it itself, and
    // that load's policy check can arrive after the report, so a handled drop is only let go of later
    func dropFinished(handled: Bool) -> [URL]? {
        guard !pendingDrop.isEmpty else { return nil }
        if !handled { return takeDrop() }
        let expiry = DispatchWorkItem { [weak self] in self?.pendingDrop = [] }
        pendingDropExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: expiry)
        return nil
    }

    private func takeDrop() -> [URL] {
        defer {
            pendingDrop = []
            pendingDropExpiry?.cancel()
        }
        return pendingDrop
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window, let hit = window.contentView?.hitTest(event.locationInWindow) else {
            super.mouseMoved(with: event)
            return
        }
        guard hit.isDescendant(of: self) else {
            if pointerOverPage {
                pointerOverPage = false
                NSCursor.arrow.set()
                window.invalidateCursorRects(for: hit)
            }
            return
        }
        pointerOverPage = true
        super.mouseMoved(with: event)
    }
}

// MARK: - Browser State (wraps WKWebView)
class BrowserState: NSObject, ObservableObject {
    let webView: WKWebView
    let tabId: UUID
    weak var tabManager: TabManager?
    weak var historyManager: HistoryManager?

    // Navigation delegate for handling new tab requests and downloads
    let navigationDelegate: NavigationDelegate

    private var pendingURL: URL?
    private var hasLoadedInitialContent = false
    private var lastStyledURL: URL?
    private var lastRecordedURL: String?


    // Tabs share cookies/storage and web content processes for free: WKWebViewConfiguration defaults
    // websiteDataStore to the shared .default() store, and since macOS 12 WebKit pools/suspends
    // processes internally (WKProcessPool is a deprecated no-op). So no shared pool is needed here.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        // the in-app web inspector (inspect element, the shortcut) hangs off webkit's developer extras
        // preference, separate from isInspectable, which only covers remote inspection from safari
        if config.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        return config
    }

    // Published properties for UI bindings
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published var fetchedBackgroundColor: NSColor?
    @Published var currentZoom: Double = 1.0

    // Zoom constraints
    private let minZoom: Double = 0.5
    private let maxZoom: Double = 3.0
    private let zoomStep: Double = 0.1

    private var pendingInteractionState: Data?

    // KVO observations
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?

    // Callback for new tab requests
    var onNewTabRequested: ((URL, Bool) -> Void)? {
        get { navigationDelegate.onNewTabRequested }
        set { navigationDelegate.onNewTabRequested = newValue }
    }

    var onNewWindowRequested: ((URL) -> Void)? {
        get { navigationDelegate.onNewWindowRequested }
        set { navigationDelegate.onNewWindowRequested = newValue }
    }

    init(tabId: UUID, tabManager: TabManager, historyManager: HistoryManager? = nil, initialURL: URL?, interactionState: Data? = nil,
         iconKey: String? = nil, showsIcon: Bool = true) {
        self.navigationDelegate = NavigationDelegate()
        self.iconKey = iconKey
        self.showsIcon = showsIcon

        self.webView = DawnWebView(frame: .zero, configuration: Self.makeConfiguration())

        self.tabId = tabId
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.pendingURL = initialURL
        self.pendingInteractionState = interactionState

        super.init()

        self.webView.navigationDelegate = navigationDelegate
        // web inspector access (also adds inspect element to the context menu); off by default for apps
        self.webView.isInspectable = true
        self.webView.uiDelegate = navigationDelegate
        self.webView.customUserAgent = DevelopSettings.userAgent.string
        self.webView.allowsBackForwardNavigationGestures = true
        navigationDelegate.onDropOpen = { [weak self] urls in self?.openDropped(urls) }
        if showsIcon { iconBridge.attach(to: webView) }

        setupObservations()
    }

    // MARK: - Icon

    // the page's icon, in the icon store. a new page keeps showing the old page's icon until its own is
    // decoded and ready to draw, or it's clear the page has none, so a tab is never caught without one.
    @Published private(set) var iconKey: String?
    private let showsIcon: Bool
    private lazy var iconBridge = IconLoadingBridge { [weak self] in self?.iconOffered() }
    // which page the icon is being found for, counting each page that replaces the last
    private var iconPage = 0
    // the icon known to be this page's: one it loaded, or the one it was last seen with
    private var pageIconKey: String?
    private var pageIconDetail = -1
    private var iconLoadsPending = 0
    private var pageNavigation: WKNavigation?
    private var pageFinished = false

    private func iconPageCommitted(_ navigation: WKNavigation?) {
        iconPage += 1
        pageNavigation = navigation
        iconLoadsPending = 0
        pageFinished = false
        pageIconDetail = -1
        // a page seen before shows its icon at once (a page restored from the back-forward cache never
        // loads icons at all); what it loads replaces that if it differs
        pageIconKey = webView.url.flatMap { historyManager?.iconKey(for: $0.absoluteString) }
        if IconStore.shared.favicon(for: pageIconKey) == nil { pageIconKey = nil }
        if let pageIconKey { showIcon(pageIconKey) }
    }

    // webkit offers the page's icons before it reports the page finished
    private func iconOffered() -> ((Data?) -> Void)? {
        let page = iconPage
        iconLoadsPending += 1
        return { [weak self] data in
            guard let data, !data.isEmpty else {
                self?.iconLoadEnded(page, nil)
                return
            }
            Task.detached(priority: .utility) {
                let prepared = IconStore.prepare(data)
                await MainActor.run { self?.iconLoadEnded(page, prepared) }
            }
        }
    }

    private func iconLoadEnded(_ page: Int, _ prepared: IconStore.Prepared?) {
        guard page == iconPage else { return }
        iconLoadsPending -= 1
        // of several icons, the most detailed one is kept
        if let prepared, prepared.favicon.detail > pageIconDetail {
            pageIconDetail = prepared.favicon.detail
            pageIconKey = IconStore.shared.store(prepared)
            showIcon(pageIconKey)
        }
        iconSettled()
    }

    private func iconPageFinished(_ navigation: WKNavigation?) {
        guard navigation === pageNavigation else { return }
        pageFinished = true
        iconSettled()
    }

    // once the page has loaded and so have all its icons, a page that turned out to have none shows so
    private func iconSettled() {
        guard pageFinished, iconLoadsPending == 0 else { return }
        showIcon(pageIconKey)
    }

    private func showIcon(_ key: String?) {
        if let url = webView.url { historyManager?.setIconKey(key, for: url.absoluteString) }
        guard key != iconKey else { return }
        iconKey = key
        tabManager?.updateTabIcon(tabId, iconKey: key)
    }

    // the first dropped item replaces this tab's page, like safari; any others open in background tabs
    private func openDropped(_ urls: [URL]) {
        let openable = urls.filter { url in
            if url.isFileURL { return !url.hasDirectoryPath && (try? url.checkResourceIsReachable()) == true }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        }
        guard let first = openable.first else { return }
        openable.filter(\.isFileURL).forEach { FileAccessStore.shared.remember($0) }
        loadURL(first.absoluteString)
        openable.dropFirst().forEach { onNewTabRequested?($0, false) }
    }

    // webkit reports a provisional navigation's url right away, even one that turns into a download
    // and never commits. publishing it would flash the file's url in the url bar and could persist it
    // as the tab's url (re-downloading the file on the next launch), so it's held until the
    // navigation commits or fails. same-document changes (pushState, fragments) have no provisional
    // phase and publish immediately.
    private var hasProvisionalNavigation = false

    private func publishCurrentURL() {
        guard let url = webView.url else { return }
        if currentURL != url { currentURL = url }
        handleURLChange(url)
    }

    private func setupObservations() {
        navigationDelegate.onProvisionalStart = { [weak self] in self?.hasProvisionalNavigation = true }
        navigationDelegate.onProvisionalEnd = { [weak self] in
            self?.hasProvisionalNavigation = false
            self?.publishCurrentURL()
        }
        if showsIcon {
            navigationDelegate.onCommit = { [weak self] navigation in self?.iconPageCommitted(navigation) }
            navigationDelegate.onFinish = { [weak self] navigation in self?.iconPageFinished(navigation) }
        }

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            guard let self, !self.hasProvisionalNavigation else { return }
            self.publishCurrentURL()
        }

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            guard let self = self, let title = change.newValue as? String else { return }
            self.pageTitle = title
            self.handleTitleChange(title)
        }

        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            guard let self = self, let loading = change.newValue else { return }
            self.isLoading = loading
            self.handleLoadingChange(loading)
        }

        canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
            guard let self = self, let value = change.newValue else { return }
            self.canGoBack = value
        }

        canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
            guard let self = self, let value = change.newValue else { return }
            self.canGoForward = value
        }
    }

    // MARK: - Event Handlers

    private func handleURLChange(_ url: URL) {
        tabManager?.updateTab(tabId, url: url.absoluteString)
    }

    private func handleTitleChange(_ newTitle: String) {
        guard !newTitle.isEmpty else { return }
        tabManager?.updateTab(tabId, title: newTitle)

        // Record to history when title is available
        if let url = webView.url,
           !url.absoluteString.hasPrefix("dawn://"),
           url.absoluteString != lastRecordedURL {
            lastRecordedURL = url.absoluteString
            historyManager?.recordVisit(title: newTitle, url: url.absoluteString, iconKey: pageIconKey)
        }
    }

    private func handleLoadingChange(_ loading: Bool) {
        // Fetch background color when loading finishes
        if !loading, let url = webView.url, url != lastStyledURL {
            lastStyledURL = url

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                self.fetchBackgroundColor()
            }
        }
    }

    private func fetchBackgroundColor() {
        let js = """
        (function() {
            function getColor(el) {
                if (!el) return null;
                var bg = getComputedStyle(el).backgroundColor;
                if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') return bg;
                return null;
            }
            return getColor(document.body) || getColor(document.documentElement) || 'rgb(255, 255, 255)';
        })()
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self,
                  let colorString = result as? String,
                  let hex = self.parseColorToHex(colorString) else { return }
            let color = NSColor(hex: hex)
            self.fetchedBackgroundColor = color
            // The area the web view paints before content reflows (e.g. during a resize/dock
            // animation) uses underPageBackgroundColor — match it to the page so the gap blends
            // instead of flashing the web view's default backdrop.
            if let color { self.webView.underPageBackgroundColor = color }
            self.tabManager?.updateTab(self.tabId, backgroundColorHex: hex)
        }
    }

    private func parseColorToHex(_ colorString: String) -> String? {
        let pattern = #"rgba?\((\d+),\s*(\d+),\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: colorString, range: NSRange(colorString.startIndex..., in: colorString)) else {
            return nil
        }

        guard let rRange = Range(match.range(at: 1), in: colorString),
              let gRange = Range(match.range(at: 2), in: colorString),
              let bRange = Range(match.range(at: 3), in: colorString),
              let r = Int(colorString[rRange]),
              let g = Int(colorString[gRange]),
              let b = Int(colorString[bRange]) else {
            return nil
        }

        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Content Loading

    func loadInitialContentIfNeeded() {
        guard !hasLoadedInitialContent else { return }
        hasLoadedInitialContent = true

        // File URLs must be loaded with loadFileURL (load(URLRequest:) won't fetch file://, and
        // restoring interactionState doesn't reliably reload a local file - it comes back blank). So a
        // restored file tab loads fresh instead, trading its in-page back/forward for actually showing.
        if let url = pendingURL, url.isFileURL {
            pendingInteractionState = nil
            loadFile(url)
            return
        }

        // Restore interaction state if available (back/forward history)
        if let stateData = pendingInteractionState {
            webView.interactionState = stateData
            pendingInteractionState = nil
            return
        }

        if let url = pendingURL {
            webView.load(URLRequest(url: url))
        }
    }

    func loadURL(_ s: String) {
        var urlString = s
        if !urlString.contains("://") {
            urlString = "https://" + urlString
        }
        guard let url = URL(string: urlString) else { return }
        // a navigation the user asked for shows its target immediately; if it fails or turns into a
        // download, the provisional end puts the page's url back
        currentURL = url
        if url.isFileURL {
            loadFile(url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    // security-scoped grants this tab holds; released when the tab goes away
    private var accessedFiles: [URL] = []

    private func loadFile(_ url: URL) {
        var target = url
        let path = url.standardizedFileURL.path
        if let held = accessedFiles.first(where: { $0.standardizedFileURL.path == path }) {
            target = held
        } else if let granted = FileAccessStore.shared.startAccess(url) {
            accessedFiles.append(granted)
            target = granted
        }
        // the folder is only readable when the sandbox grants it (e.g. downloads). a file picked on
        // its own grants just that file, so its sibling assets are out of reach and asking webkit to
        // extend read access to the folder would exceed what the app holds.
        let folder = target.deletingLastPathComponent()
        let scope = FileManager.default.isReadableFile(atPath: folder.path) ? folder : target
        webView.loadFileURL(target, allowingReadAccessTo: scope)
    }

    deinit {
        accessedFiles.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    // webkit has no public calls for its inspector, only its context menu item. its inspector object is
    // reached defensively: if a future webkit renames something, the action does nothing rather than crash.
    private var inspector: NSObject? {
        guard webView.responds(to: NSSelectorFromString("_inspector")) else { return nil }
        return webView.value(forKey: "_inspector") as? NSObject
    }

    private func inspectorFlag(_ name: String) -> Bool {
        guard let inspector, inspector.responds(to: NSSelectorFromString(name)) else { return false }
        return inspector.value(forKey: name) as? Bool ?? false
    }

    var isWebInspectorVisible: Bool { inspectorFlag("isVisible") }
    var isElementSelectionActive: Bool { inspectorFlag("isElementSelectionActive") }
    var isTimelineRecording: Bool { inspectorFlag("isProfilingPage") }

    func performInspectorAction(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard let inspector, inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    func toggleWebInspector() {
        performInspectorAction(isWebInspectorVisible ? "close" : "show")
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        lastStyledURL = nil
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func captureInteractionState() -> Data? {
        return webView.interactionState as? Data
    }

    // MARK: - Zoom

    func zoomIn() {
        let newZoom = min(currentZoom + zoomStep, maxZoom)
        setZoom(newZoom)
    }

    func zoomOut() {
        let newZoom = max(currentZoom - zoomStep, minZoom)
        setZoom(newZoom)
    }

    func resetZoom() {
        setZoom(1.0)
    }

    private func setZoom(_ zoom: Double) {
        currentZoom = zoom
        let js = "document.documentElement.style.zoom = '\(zoom)'"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
