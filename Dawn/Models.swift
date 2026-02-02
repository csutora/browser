import SwiftUI
import SwiftData
import Combine
import WebKit

// MARK: - Tab Type
enum TabType: String, Codable {
    case web
    case settings
}

// MARK: - Tab Model
@Model
final class Tab: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var url: String
    var sortIndex: Int
    var tabTypeRaw: String = TabType.web.rawValue
    @Attribute(.externalStorage) var interactionState: Data?
    var scrollX: Double = 0.0
    var scrollY: Double = 0.0
    var zoomScale: Double = 1.0
    var backgroundColorHex: String?
    var lastAccessedAt: Date = Date()

    var tabType: TabType {
        get { TabType(rawValue: tabTypeRaw) ?? .web }
        set { tabTypeRaw = newValue.rawValue }
    }

    var isSettings: Bool { tabType == .settings }

    var backgroundColor: Color? {
        guard let hex = backgroundColorHex else { return nil }
        return Color(hex: hex)
    }

    init(id: UUID = UUID(), title: String = "New Tab", url: String = "https://www.google.com", sortIndex: Int = 0, tabType: TabType = .web) {
        self.id = id
        self.title = title
        self.url = url
        self.sortIndex = sortIndex
        self.tabTypeRaw = tabType.rawValue
    }
}

extension Tab: Equatable {
    static func == (lhs: Tab, rhs: Tab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Closed Tab Info (for reopen stack)
struct ClosedTabInfo: Codable {
    let title: String
    let url: String
    let sortIndex: Int
    let tabType: TabType
    let backgroundColorHex: String?
    let interactionState: Data?  // Navigation state (back/forward history)
}

// MARK: - Tab Manager
class TabManager: ObservableObject {
    @AppStorage("currentTabId") var currentTabIdString: String = ""
    var modelContext: ModelContext?
    private var saveTask: DispatchWorkItem?

    /// Stack of recently closed tabs (most recent last)
    private var closedTabsStack: [ClosedTabInfo] = [] {
        didSet { saveClosedTabsStack() }
    }
    private let maxClosedTabs = 20
    private let closedTabsKey = "closedTabsStack"

    init() {
        loadClosedTabsStack()
    }

    private func saveClosedTabsStack() {
        if let encoded = try? JSONEncoder().encode(closedTabsStack) {
            UserDefaults.standard.set(encoded, forKey: closedTabsKey)
        }
    }

    private func loadClosedTabsStack() {
        if let data = UserDefaults.standard.data(forKey: closedTabsKey),
           let decoded = try? JSONDecoder().decode([ClosedTabInfo].self, from: data) {
            closedTabsStack = decoded
        }
    }

    var currentTabId: UUID? {
        get { UUID(uuidString: currentTabIdString) }
        set { currentTabIdString = newValue?.uuidString ?? "" }
    }

    var currentTabURL: String = ""

    var canReopenClosedTab: Bool {
        !closedTabsStack.isEmpty
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in try? self?.modelContext?.save() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    func saveNow() {
        saveTask?.cancel()
        try? modelContext?.save()
    }

    func createTab(url: String = "https://www.google.com", existingCount: Int) {
        guard let context = modelContext else { return }
        let t = Tab(url: url, sortIndex: existingCount)
        context.insert(t)
        currentTabId = t.id
        currentTabURL = t.url
        try? context.save()
    }

    func closeTab(_ tab: Tab, allTabs: [Tab], interactionState: Data? = nil) {
        guard let context = modelContext else { return }

        // Save tab info to closed stack before deleting (skip settings tabs)
        if !tab.isSettings {
            let closedInfo = ClosedTabInfo(
                title: tab.title,
                url: tab.url,
                sortIndex: tab.sortIndex,
                tabType: tab.tabType,
                backgroundColorHex: tab.backgroundColorHex,
                interactionState: interactionState
            )
            closedTabsStack.append(closedInfo)
            // Limit stack size
            if closedTabsStack.count > maxClosedTabs {
                closedTabsStack.removeFirst()
            }
        }

        if currentTabId == tab.id {
            if let index = allTabs.firstIndex(of: tab) {
                let newIndex = index > 0 ? index - 1 : (index + 1 < allTabs.count ? index + 1 : -1)
                if newIndex >= 0 {
                    let newTab = allTabs[newIndex]
                    currentTabId = newTab.id
                    currentTabURL = newTab.url
                } else {
                    currentTabId = nil
                }
            }
        }
        context.delete(tab)
        try? context.save()
    }

    func reopenLastClosedTab(existingCount: Int) {
        guard let context = modelContext, let closedInfo = closedTabsStack.popLast() else { return }

        let tab = Tab(
            title: closedInfo.title,
            url: closedInfo.url,
            sortIndex: existingCount,
            tabType: closedInfo.tabType
        )
        tab.backgroundColorHex = closedInfo.backgroundColorHex
        tab.interactionState = closedInfo.interactionState

        context.insert(tab)
        currentTabId = tab.id
        currentTabURL = tab.url
        try? context.save()
    }

    func selectTab(_ tab: Tab) {
        currentTabId = tab.id
        currentTabURL = tab.url
        // Update lastAccessedAt through the context to avoid threading issues
        updateLastAccessedAt(for: tab.id)
    }

    private func updateLastAccessedAt(for tabId: UUID) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == tabId })
        if let tab = try? context.fetch(descriptor).first {
            tab.lastAccessedAt = Date()
            scheduleSave()
        }
    }

    func updateSettingsPath(_ path: String) {
        guard let context = modelContext,
              let currentId = currentTabId else { return }
        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == currentId })
        if let tab = try? context.fetch(descriptor).first, tab.isSettings {
            let newURL = "dawn://\(path)"
            tab.url = newURL
            currentTabURL = newURL
            try? context.save()
        }
    }

    func openSettings() {
        guard let context = modelContext else { return }

        // Fetch all tabs to check for existing settings tab
        let descriptor = FetchDescriptor<Tab>(sortBy: [SortDescriptor(\.sortIndex)])
        let allTabs = (try? context.fetch(descriptor)) ?? []

        // Find existing settings tab or create one
        if let settingsTab = allTabs.first(where: { $0.isSettings }) {
            selectTab(settingsTab)
        } else {
            let t = Tab(title: "Settings", url: "dawn://settings", sortIndex: allTabs.count, tabType: .settings)
            context.insert(t)
            currentTabId = t.id
            currentTabURL = "dawn://settings"
            try? context.save()
        }
    }

    func updateTab(_ id: UUID, title: String? = nil, url: String? = nil, scroll: CGPoint? = nil, backgroundColorHex: String? = nil) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })
        if let tab = try? context.fetch(descriptor).first {
            if let t = title { tab.title = t }
            if let u = url {
                tab.url = u
                if id == currentTabId { currentTabURL = u }
            }
            if let s = scroll {
                tab.scrollX = s.x
                tab.scrollY = s.y
            }
            if let bg = backgroundColorHex { tab.backgroundColorHex = bg }
            scheduleSave()
        }
    }
}

// MARK: - Browser State
class BrowserState: ObservableObject {
    let webPage: WebPage
    let tabId: UUID
    weak var tabManager: TabManager?
    weak var historyManager: HistoryManager?

    private var pendingURL: URL?
    private var hasLoadedInitialContent = false
    private var lastStyledURL: URL?
    private var lastRecordedURL: String?

    // Modern Safari User-Agent for website compatibility
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"

    // Published properties for UI bindings
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var fetchedBackgroundColor: Color?
    @Published var currentZoom: Double = 1.0

    // Zoom constraints
    private let minZoom: Double = 0.5
    private let maxZoom: Double = 3.0
    private let zoomStep: Double = 0.1

    private var pendingInteractionState: Data?

    init(tabId: UUID, tabManager: TabManager, historyManager: HistoryManager? = nil, initialURL: URL?, interactionState: Data? = nil) {
        self.webPage = WebPage()
        self.tabId = tabId
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.pendingURL = initialURL
        self.pendingInteractionState = interactionState

        // Set custom User-Agent so websites treat this as modern Safari
        self.webPage.customUserAgent = Self.safariUserAgent
    }

    // MARK: - Event Handlers (called from SwiftUI onChange)

    func handleURLChange(_ newURL: URL?) {
        guard let url = newURL else { return }
        tabManager?.updateTab(tabId, url: url.absoluteString)
        // Update navigation state immediately and again after a short delay
        // (backForwardList may not be updated synchronously)
        updateNavigationState()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.updateNavigationState()
        }
    }

    func handleTitleChange(_ newTitle: String) {
        guard !newTitle.isEmpty else { return }
        tabManager?.updateTab(tabId, title: newTitle)

        // Record to history when title is available (indicates page loaded)
        if let url = webPage.url,
           !url.absoluteString.hasPrefix("dawn://"),
           url.absoluteString != lastRecordedURL {
            lastRecordedURL = url.absoluteString
            historyManager?.recordVisit(title: newTitle, url: url.absoluteString)
        }
    }

    func handleLoadingChange(_ loading: Bool) {
        isLoading = loading

        // Always update navigation state when loading state changes
        updateNavigationState()

        // Fetch background color when loading finishes
        if !loading, let url = webPage.url, url != lastStyledURL {
            lastStyledURL = url

            Task { @MainActor in
                // Delay to ensure CSS is fully applied and navigation state is stable
                try? await Task.sleep(for: .milliseconds(500))
                self.fetchBackgroundColor()
                self.updateNavigationState()
            }
        }
    }

    private func updateNavigationState() {
        canGoBack = !webPage.backForwardList.backList.isEmpty
        canGoForward = !webPage.backForwardList.forwardList.isEmpty
    }

    private func fetchBackgroundColor() {
        let js = """
        function getColor(el) {
            if (!el) return null;
            var bg = getComputedStyle(el).backgroundColor;
            if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') return bg;
            return null;
        }
        return getColor(document.body) || getColor(document.documentElement) || 'rgb(255, 255, 255)';
        """

        Task { @MainActor in
            do {
                let result = try await webPage.callJavaScript(js)
                if let colorString = result as? String, let hex = self.parseColorToHex(colorString) {
                    self.fetchedBackgroundColor = Color(hex: hex)
                    self.tabManager?.updateTab(self.tabId, backgroundColorHex: hex)
                }
            } catch {
                // Ignore JS errors
            }
        }
    }

    private func parseColorToHex(_ colorString: String) -> String? {
        // Parse rgb(r, g, b) or rgba(r, g, b, a) format
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

    func loadInitialContentIfNeeded() {
        // Only load once per BrowserState lifetime
        guard !hasLoadedInitialContent else { return }
        hasLoadedInitialContent = true

        // Note: interactionState restoration would require accessing the underlying WKWebView
        // For now, just load the URL
        if let url = pendingURL {
            webPage.load(URLRequest(url: url))
        }
        pendingInteractionState = nil
    }

    func loadURL(_ s: String) {
        var urlString = s
        // Don't prepend https:// if any protocol already exists
        if !urlString.contains("://") {
            urlString = "https://" + urlString
        }
        guard let url = URL(string: urlString) else { return }
        webPage.load(URLRequest(url: url))
    }

    func goBack() {
        guard let item = webPage.backForwardList.backList.last else { return }
        webPage.load(item)
        // Update navigation state immediately for responsive UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateNavigationState()
        }
    }

    func goForward() {
        guard let item = webPage.backForwardList.forwardList.first else { return }
        webPage.load(item)
        // Update navigation state immediately for responsive UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateNavigationState()
        }
    }

    func reload() {
        lastStyledURL = nil  // Force re-fetch on reload
        webPage.reload()
    }

    func stopLoading() {
        webPage.stopLoading()
    }

    func captureInteractionState() -> Data? {
        // Note: interactionState is on WKWebView, not exposed through SwiftUI WebPage wrapper
        // This would require accessing the underlying WKWebView to implement fully
        return nil
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
        // Use JavaScript to set zoom on the document
        let js = "document.documentElement.style.zoom = '\(zoom)'"
        Task { @MainActor in
            _ = try? await webPage.callJavaScript(js)
        }
    }
}

// MARK: - Color Extension
extension Color {
    init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        guard hexString.count == 6,
              let int = UInt64(hexString, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
