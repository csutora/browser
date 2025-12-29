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

    var tabType: TabType {
        get { TabType(rawValue: tabTypeRaw) ?? .web }
        set { tabTypeRaw = newValue.rawValue }
    }

    var isSettings: Bool { tabType == .settings }

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

    func updateTab(_ id: UUID, title: String? = nil, url: String? = nil, interactionState: Data? = nil, scroll: CGPoint? = nil, zoom: Double? = nil) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })
        if let tab = try? context.fetch(descriptor).first {
            if let t = title { tab.title = t }
            if let u = url {
                tab.url = u
                if id == currentTabId { currentTabURL = u }
            }
            if let state = interactionState { tab.interactionState = state }
            if let s = scroll {
                tab.scrollX = s.x
                tab.scrollY = s.y
            }
            if let z = zoom { tab.zoomScale = z }
            scheduleSave()
        }
    }
}

// MARK: - Browser State
class BrowserState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var backgroundColor: Color = .clear

    var webView: WKWebView?
    var tabId: UUID
    weak var tabManager: TabManager?

    var pendingURL: URL?
    var restorationData: Data?
    var savedScroll: CGPoint?
    var savedZoom: Double?

    init(tabId: UUID, tabManager: TabManager, restorationData: Data? = nil, scroll: CGPoint? = nil, zoom: Double? = nil) {
        self.tabId = tabId
        self.tabManager = tabManager
        self.restorationData = restorationData
        self.savedScroll = scroll
        self.savedZoom = zoom
    }

    func loadURL(_ s: String) {
        var u = s
        if !u.lowercased().hasPrefix("http") { u = "https://" + u }
        guard let url = URL(string: u) else { return }

        if let w = webView {
            w.load(URLRequest(url: url))
        } else {
            pendingURL = url
            restorationData = nil
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }
}
