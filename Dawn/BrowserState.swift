import AppKit
import WebKit
import Combine

// webkit takes mouse moves through a rect-based tracking area, so it keeps hovering the page and
// setting the page's cursor even where native views (the floating sidebar, the command palette)
// cover it. only let moves through when the page is actually the topmost view under the pointer.
final class DawnWebView: WKWebView {
    private var pointerOverPage = false

    // while the page asks something, the question takes the keyboard and the pointer
    weak var dialogView: PageDialogView?

    override func becomeFirstResponder() -> Bool {
        if let dialogView {
            DispatchQueue.main.async { dialogView.takeFocus() }
            return false
        }
        return super.becomeFirstResponder()
    }

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
        guard hit.isDescendant(of: self), !(dialogView.map { hit.isDescendant(of: $0) } ?? false) else {
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

// runs once the current pass of the main run loop is about to sleep, after every other observer of that
// moment (webkit sends a web view's visibility changes on from one of them)
func afterRunLoopPass(_ body: @escaping () -> Void) {
    var fired = false
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { observer, _ in
        guard !fired else { return }
        fired = true
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        body()
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
}

// everything about a page that outlives its web view, so the page comes back as it was left after its
// tab is unloaded or dawn quits: its history (each entry with its scroll position and form fields),
// its session storage and its zoom
struct SavedPage {
    var interactionState: Data?
    var sessionStorage: Data?
    var zoom: Double = 1
}

// script messages go through this, since the web view's content controller keeps its handlers alive
private final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    weak var state: BrowserState?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        state?.userTyped()
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
    private var pendingSavedPage: SavedPage
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

    var onOpenPage: ((WKWebViewConfiguration, URL?, Bool) -> WKWebView?)? {
        get { navigationDelegate.onOpenPage }
        set { navigationDelegate.onOpenPage = newValue }
    }

    var onClose: (() -> Void)? {
        get { navigationDelegate.onClose }
        set { navigationDelegate.onClose = newValue }
    }

    // `opening` is the configuration webkit gave for a page another page opened, which webkit then
    // loads into this one's web view itself
    init(tabId: UUID, tabManager: TabManager, historyManager: HistoryManager? = nil, initialURL: URL?, saved: SavedPage = SavedPage(),
         iconKey: String? = nil, showsIcon: Bool = true, opening: WKWebViewConfiguration? = nil) {
        self.navigationDelegate = NavigationDelegate()
        self.iconKey = iconKey
        self.showsIcon = showsIcon

        if let opening {
            // the opener's configuration carries its content controller, whose handlers report to the opener
            opening.userContentController = WKUserContentController()
            self.webView = DawnWebView(frame: .zero, configuration: opening)
            self.hasLoadedInitialContent = true
        } else {
            self.webView = DawnWebView(frame: .zero, configuration: Self.makeConfiguration())
        }

        self.tabId = tabId
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.pendingURL = initialURL
        self.pendingSavedPage = saved
        self.currentZoom = saved.zoom

        super.init()

        scriptRelay.state = self
        let controller = webView.configuration.userContentController
        controller.add(scriptRelay, contentWorld: Self.dawnWorld, name: "userInput")
        controller.addUserScript(WKUserScript(source: Self.userInputScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.dawnWorld))

        self.webView.navigationDelegate = navigationDelegate
        // web inspector access (also adds inspect element to the context menu); off by default for apps
        self.webView.isInspectable = true
        self.webView.uiDelegate = navigationDelegate
        self.webView.customUserAgent = DevelopSettings.userAgent.string
        self.webView.allowsBackForwardNavigationGestures = true
        navigationDelegate.onDropOpen = { [weak self] urls in self?.openDropped(urls) }
        navigationDelegate.onDialog = { [weak self] dialog in
            guard let self else { return dialog.completion(false, []) }
            self.present(dialog)
        }
        navigationDelegate.onAuthenticate = { [weak self] challenge, completion in
            guard let self else { return completion(nil) }
            self.authenticate(challenge, completion)
        }
        if showsIcon { iconBridge.attach(to: webView) }

        setupObservations()
    }

    // MARK: - Icon

    // the page's icon, in the icon store. a new page keeps showing the old page's icon until its own is
    // decoded and ready to draw, or it's clear the page has none, so a tab is never caught without one.
    @Published private(set) var iconKey: String?
    private let showsIcon: Bool
    private lazy var iconBridge = IconLoadingBridge { [weak self] touch in self?.iconOffered(touch: touch) }
    // which page the icon is being found for, counting each page that replaces the last
    private var iconPage = 0
    // the icon known to be this page's: one it loaded, or the one it was last seen with
    private var pageIconKey: String?
    private var pageIconDetail = -1
    // a favorite's page also gets its touch icon (the larger one made for home screens), for a
    // favorite's tile when its favicon is too small to show sharply there
    private var pageTouchIconKey: String?
    private var pageTouchIconDetail = -1
    private var iconLoadsPending = 0
    private var pageNavigation: WKNavigation?
    private var pageFinished = false

    private func iconPageCommitted(_ navigation: WKNavigation?) {
        iconPage += 1
        pageNavigation = navigation
        iconLoadsPending = 0
        pageFinished = false
        pageIconDetail = -1
        pageTouchIconKey = nil
        pageTouchIconDetail = -1
        // a page seen before shows its icon at once (a page restored from the back-forward cache never
        // loads icons at all); what it loads replaces that if it differs
        pageIconKey = webView.url.flatMap { historyManager?.iconKey(for: $0.absoluteString) }
        if IconStore.shared.favicon(for: pageIconKey) == nil { pageIconKey = nil }
        if let pageIconKey { showIcon(pageIconKey) }
    }

    // webkit offers the page's icons before it reports the page finished
    private func iconOffered(touch: Bool) -> ((Data?) -> Void)? {
        if touch, tabManager?.tab(tabId)?.isFavorite != true { return nil }
        let page = iconPage
        iconLoadsPending += 1
        return { [weak self] data in
            guard let data, !data.isEmpty else {
                self?.iconLoadEnded(page, nil, touch: touch)
                return
            }
            Task.detached(priority: .utility) {
                let prepared = IconStore.prepare(data)
                await MainActor.run { self?.iconLoadEnded(page, prepared, touch: touch) }
            }
        }
    }

    private func iconLoadEnded(_ page: Int, _ prepared: IconStore.Prepared?, touch: Bool) {
        guard page == iconPage else { return }
        iconLoadsPending -= 1
        // of several icons, the most detailed one is kept
        if let prepared, touch, prepared.favicon.detail > pageTouchIconDetail {
            pageTouchIconDetail = prepared.favicon.detail
            pageTouchIconKey = IconStore.shared.store(prepared)
            tabManager?.updateTabTouchIcon(tabId, iconKey: pageTouchIconKey)
        } else if let prepared, !touch, prepared.favicon.detail > pageIconDetail {
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
        if tabManager?.tab(tabId)?.isFavorite == true { tabManager?.updateTabTouchIcon(tabId, iconKey: pageTouchIconKey) }
    }

    private func showIcon(_ key: String?) {
        if let url = webView.url { historyManager?.setIconKey(key, for: url.absoluteString) }
        guard key != iconKey else { return }
        iconKey = key
        tabManager?.updateTabIcon(tabId, iconKey: key)
    }

    // MARK: - Unloading

    // typing a page received since it loaded. webkit restores only the form fields a page's html
    // declares, not ones its scripts built, nor rich text, passwords or fields that opt out of
    // autocomplete, and a script can't tell those apart reliably, so any typing at all keeps a page
    // from being unloaded until it's replaced by another
    private(set) var hasUserInput = false
    // the page is what a form sent, which loading it again would send again
    private(set) var isFormResult = false
    private var requestedPageIsFormResult = false
    private let scriptRelay = ScriptMessageRelay()

    // dawn's own scripts run in a world of their own, which pages can't see or reach
    private static let dawnWorld = WKContentWorld.world(name: "dawn")
    private static let userInputScript = """
    (() => {
        let told = false
        addEventListener('input', event => {
            if (told || !event.isTrusted) return
            told = true
            webkit.messageHandlers.userInput.postMessage(null)
        }, true)
    })()
    """

    fileprivate func userTyped() {
        hasUserInput = true
    }

    // whether the page can go away now and come back later as it was: not while it plays sound or
    // video, records, shows fullscreen, is inspected or is still loading, and not once it holds typing
    // or a form's result (see above)
    func checkUnloadable(_ completion: @escaping (Bool) -> Void) {
        func privateFlag(_ key: String) -> Bool {
            webView.responds(to: NSSelectorFromString(key)) && (webView.value(forKey: key) as? Bool ?? false)
        }
        let capturingScreen = webView.responds(to: NSSelectorFromString("_displayCaptureState"))
            && (webView.value(forKey: "_displayCaptureState") as? Int ?? 0) != WKMediaCaptureState.none.rawValue
        guard hasLoadedInitialContent, !hasUserInput, !isFormResult, !webView.isLoading, !isWebInspectorVisible, currentDialog == nil,
              webView.fullscreenState == .notInFullscreen, webView.cameraCaptureState == .none,
              webView.microphoneCaptureState == .none, !capturingScreen, !privateFlag("_isPlayingAudio") else {
            return completion(false)
        }
        webView.requestMediaPlaybackState { state in completion(state != .playing) }
    }

    // the web content process showing the page, which exits once nothing shows a page in it
    var webProcessIdentifier: pid_t? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = webView.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0 else { return nil }
        return pid
    }

    // the page as it would come back, read once it has stopped being visible. webkit writes a page's
    // form fields into its history entry only when the page is hidden, which it passes on at the end of
    // the run loop pass that hid it; a round trip to the page's process after that comes back once what
    // it saved has arrived.
    func captureState(_ completion: @escaping (SavedPage) -> Void) {
        // a page not loaded yet (or still being restored) is exactly what it was given
        guard hasLoadedInitialContent, pendingSavedPage.interactionState == nil, pendingSavedPage.sessionStorage == nil else {
            return completion(SavedPage(interactionState: pendingSavedPage.interactionState, sessionStorage: pendingSavedPage.sessionStorage, zoom: currentZoom))
        }
        // held until it's done, so whoever asked always hears back
        afterRunLoopPass {
            self.webView.evaluateJavaScript("0", in: nil, in: Self.dawnWorld) { _ in
                let interaction = self.webView.interactionState as? Data
                self.webView.fetchData(of: [.sessionStorage]) { session, _ in
                    completion(SavedPage(interactionState: interaction, sessionStorage: session, zoom: self.currentZoom))
                }
            }
        }
    }

    // MARK: - Dialogs

    // one question at a time, in the order the page asked them
    private var currentDialog: PageDialogView?
    private var queuedDialogs: [PageDialog] = []
    // requests waiting on a sign-in, by where they sign in to. several can ask at once for the same
    // place; it's asked about once, and they all get the answer.
    private var authWaiters: [String: [(URLCredential?) -> Void]] = [:]

    func present(_ dialog: PageDialog) {
        queuedDialogs.append(dialog)
        showNextDialog()
    }

    private func showNextDialog() {
        guard currentDialog == nil, !queuedDialogs.isEmpty else { return }
        let view = PageDialogView(queuedDialogs.removeFirst()) { [weak self] in
            self?.currentDialog = nil
            self?.showNextDialog()
        }
        currentDialog = view
        view.present(in: webView)
    }

    // the person moved the page on, leaving whatever it asked unanswered, as if cancelled
    private func dismissDialogs() {
        let queued = queuedDialogs
        queuedDialogs = []
        queued.forEach { $0.completion(false, []) }
        currentDialog?.cancel()
    }

    private func authenticate(_ challenge: URLAuthenticationChallenge, _ completion: @escaping (URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let key = [space.protocol ?? "", space.host, String(space.port), space.realm ?? "", space.authenticationMethod, space.isProxy() ? "proxy" : ""]
            .joined(separator: "\n")
        if authWaiters[key] != nil { return authWaiters[key]!.append(completion) }
        authWaiters[key] = [completion]

        let defaultPort = space.protocol == "https" ? 443 : 80
        let place = space.port == 0 || space.port == defaultPort ? space.host : "\(space.host):\(space.port)"
        var notes: [String] = []
        if challenge.previousFailureCount > 0 { notes.append("The username or password was incorrect.") }
        if !space.receivesCredentialSecurely { notes.append("Your password will be sent unencrypted.") }
        // the realm is left out: it's the site's own words, free to impersonate anyone
        present(PageDialog(
            title: space.isProxy() ? "Log in to the proxy \(place)" : "Log in to \(place)",
            message: notes.joined(separator: " "),
            fields: [.text(placeholder: "Username", value: challenge.proposedCredential?.user ?? "", contentType: .username), .secure(placeholder: "Password")],
            confirmTitle: "Log In"
        ) { [weak self] confirmed, values in
            guard let self else { return }
            let credential = confirmed ? URLCredential(user: values[0], password: values[1], persistence: .forSession) : nil
            self.authWaiters.removeValue(forKey: key)?.forEach { $0(credential) }
        })
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
        navigationDelegate.onMainFrameRequest = { [weak self] request in
            self?.requestedPageIsFormResult = request.httpMethod?.uppercased() == "POST"
        }
        navigationDelegate.onCommit = { [weak self] navigation in
            guard let self else { return }
            self.hasUserInput = false
            self.isFormResult = self.requestedPageIsFormResult
            if self.showsIcon { self.iconPageCommitted(navigation) }
        }
        navigationDelegate.onFinish = { [weak self] navigation in
            guard let self else { return }
            if self.showsIcon { self.iconPageFinished(navigation) }
            // a page that finished without a title is named by its address, like safari does, rather
            // than keeping whatever the tab was called before
            if (self.webView.title ?? "").isEmpty, let url = self.webView.url, !url.absoluteString.hasPrefix("about:") {
                let host = url.host ?? ""
                let name = host.isEmpty ? url.absoluteString : host + (url.path == "/" ? "" : url.path)
                self.tabManager?.updateTab(self.tabId, title: name)
            }
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

        webView.pageZoom = currentZoom

        // File URLs must be loaded with loadFileURL (load(URLRequest:) won't fetch file://, and
        // restoring interactionState doesn't reliably reload a local file - it comes back blank). So a
        // restored file tab loads fresh instead, trading its in-page back/forward for actually showing.
        if let url = pendingURL, url.isFileURL {
            pendingSavedPage = SavedPage(zoom: currentZoom)
            loadFile(url)
            return
        }

        // session storage goes back first, so a page that reads it while loading finds it
        guard let session = pendingSavedPage.sessionStorage else { return loadSavedHistory() }
        webView.restoreData(session) { [weak self] _ in
            self?.pendingSavedPage.sessionStorage = nil
            self?.loadSavedHistory()
        }
    }

    private func loadSavedHistory() {
        // Restore interaction state if available (back/forward history)
        if let stateData = pendingSavedPage.interactionState {
            webView.interactionState = stateData
            pendingSavedPage.interactionState = nil
            return
        }

        if let url = pendingURL {
            webView.load(URLRequest(url: url))
        }
    }

    func loadURL(_ s: String) {
        guard let url = URL(string: withDefaultScheme(s)) else { return }
        dismissDialogs()
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
        // webkit needs every question answered, even for a page that's going away
        let waiting = authWaiters.values.joined()
        authWaiters = [:]
        waiting.forEach { $0(nil) }
        dismissDialogs()
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
        dismissDialogs()
        webView.goBack()
    }

    func goForward() {
        dismissDialogs()
        webView.goForward()
    }

    func reload() {
        dismissDialogs()
        lastStyledURL = nil
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    // MARK: - Zoom

    // whole steps, so repeated zooming in and out lands back on exactly the same zoom
    func zoomIn() {
        setZoom(min(((currentZoom + zoomStep) / zoomStep).rounded() * zoomStep, maxZoom))
    }

    func zoomOut() {
        setZoom(max(((currentZoom - zoomStep) / zoomStep).rounded() * zoomStep, minZoom))
    }

    func resetZoom() {
        setZoom(1.0)
    }

    // the web view's own zoom, which holds across the tab's navigations and is kept with the tab
    private func setZoom(_ zoom: Double) {
        currentZoom = zoom
        webView.pageZoom = zoom
        tabManager?.updateTabZoom(tabId, zoom: zoom)
    }
}
