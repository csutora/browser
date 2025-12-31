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

// MARK: - Tab Manager
class TabManager: ObservableObject {
    @AppStorage("currentTabId") var currentTabIdString: String = ""
    var modelContext: ModelContext?
    private var saveTask: DispatchWorkItem?

    var currentTabId: UUID? {
        get { UUID(uuidString: currentTabIdString) }
        set { currentTabIdString = newValue?.uuidString ?? "" }
    }

    var currentTabURL: String = ""

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

    func closeTab(_ tab: Tab, allTabs: [Tab]) {
        guard let context = modelContext else { return }
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

    func selectTab(_ tab: Tab) {
        currentTabId = tab.id
        currentTabURL = tab.url
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
    let webPage = WebPage()
    let tabId: UUID
    weak var tabManager: TabManager?

    private var pendingURL: URL?
    private var hasLoadedInitialContent = false
    private var lastStyledURL: URL?

    // Published properties for UI bindings
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var fetchedBackgroundColor: Color?

    init(tabId: UUID, tabManager: TabManager, initialURL: URL?) {
        self.tabId = tabId
        self.tabManager = tabManager
        self.pendingURL = initialURL
    }

    // MARK: - Event Handlers (called from SwiftUI onChange)

    func handleURLChange(_ newURL: URL?) {
        guard let url = newURL else { return }
        tabManager?.updateTab(tabId, url: url.absoluteString)
        updateNavigationState()
    }

    func handleTitleChange(_ newTitle: String) {
        guard !newTitle.isEmpty else { return }
        tabManager?.updateTab(tabId, title: newTitle)
    }

    func handleLoadingChange(_ loading: Bool) {
        isLoading = loading

        // Fetch background color when loading finishes
        if !loading, let url = webPage.url, url != lastStyledURL {
            lastStyledURL = url
            updateNavigationState()

            Task { @MainActor in
                // Delay to ensure CSS is fully applied
                try? await Task.sleep(for: .milliseconds(500))
                self.fetchBackgroundColor()
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
        guard !hasLoadedInitialContent, let url = pendingURL else { return }
        hasLoadedInitialContent = true
        webPage.load(URLRequest(url: url))
    }

    func loadURL(_ s: String) {
        var urlString = s
        if !urlString.lowercased().hasPrefix("http") {
            urlString = "https://" + urlString
        }
        guard let url = URL(string: urlString) else { return }
        webPage.load(URLRequest(url: url))
    }

    func goBack() {
        guard let item = webPage.backForwardList.backList.last else { return }
        webPage.load(item)
    }

    func goForward() {
        guard let item = webPage.backForwardList.forwardList.first else { return }
        webPage.load(item)
    }

    func reload() {
        lastStyledURL = nil  // Force re-fetch on reload
        webPage.reload()
    }

    func stopLoading() {
        webPage.stopLoading()
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
