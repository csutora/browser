import AppKit
import WebKit
import Combine

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

    // Modern Safari User-Agent for website compatibility
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
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

    init(tabId: UUID, tabManager: TabManager, historyManager: HistoryManager? = nil, initialURL: URL?, interactionState: Data? = nil) {
        self.navigationDelegate = NavigationDelegate()

        // Create WKWebView with shared configuration
        self.webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())

        self.tabId = tabId
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.pendingURL = initialURL
        self.pendingInteractionState = interactionState

        super.init()

        self.webView.navigationDelegate = navigationDelegate
        self.webView.uiDelegate = navigationDelegate
        self.webView.customUserAgent = Self.safariUserAgent
        self.webView.allowsBackForwardNavigationGestures = true

        setupObservations()
    }

    private func setupObservations() {
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let self = self, let url = change.newValue as? URL else { return }
            self.currentURL = url
            self.handleURLChange(url)
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
            historyManager?.recordVisit(title: newTitle, url: url.absoluteString)
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
        webView.load(URLRequest(url: url))
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
