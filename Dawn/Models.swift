import AppKit
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

    var nsBackgroundColor: NSColor? {
        guard let hex = backgroundColorHex else { return nil }
        return NSColor(hex: hex)
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
    let interactionState: Data?
}

// MARK: - Tab Manager
class TabManager: ObservableObject {
    @Published var currentTabIdString: String = UserDefaults.standard.string(forKey: "currentTabId") ?? "" {
        didSet { UserDefaults.standard.set(currentTabIdString, forKey: "currentTabId") }
    }
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

    @Published var currentTabURL: String = ""

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

    func fetchTabs() -> [Tab] {
        let descriptor = FetchDescriptor<Tab>(sortBy: [SortDescriptor(\.sortIndex)])
        return (try? modelContext?.fetch(descriptor)) ?? []
    }

    func createTab(url: String = "https://www.google.com", existingCount: Int, switchToTab: Bool = false) {
        guard let context = modelContext else { return }
        let t = Tab(url: url, sortIndex: existingCount)
        context.insert(t)
        if switchToTab {
            currentTabId = t.id
            currentTabURL = t.url
        }
        try? context.save()
        NotificationCenter.default.post(name: .tabsDidChange, object: nil)
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
        NotificationCenter.default.post(name: .tabsDidChange, object: nil)
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
        NotificationCenter.default.post(name: .tabsDidChange, object: nil)
    }

    func selectTab(_ tab: Tab) {
        currentTabId = tab.id
        currentTabURL = tab.url
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

        let descriptor = FetchDescriptor<Tab>(sortBy: [SortDescriptor(\.sortIndex)])
        let allTabs = (try? context.fetch(descriptor)) ?? []

        if let settingsTab = allTabs.first(where: { $0.isSettings }) {
            selectTab(settingsTab)
        } else {
            let t = Tab(title: "Settings", url: "dawn://settings", sortIndex: allTabs.count, tabType: .settings)
            context.insert(t)
            currentTabId = t.id
            currentTabURL = "dawn://settings"
            try? context.save()
            NotificationCenter.default.post(name: .tabsDidChange, object: nil)
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
        NotificationCenter.default.post(name: .tabDataDidChange, object: id)
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let tabsDidChange = Notification.Name("tabsDidChange")
    static let tabDataDidChange = Notification.Name("tabDataDidChange")
    static let focusURLBar = Notification.Name("focusURLBar")
}

// MARK: - Settings Path Helper
func extractSettingsPath(from url: String) -> String {
    guard url.hasPrefix("dawn://") else { return "settings" }
    let path = String(url.dropFirst("dawn://".count))
    return path.isEmpty ? "settings" : path
}

// MARK: - NSColor Extension
extension NSColor {
    convenience init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        guard hexString.count == 6,
              let int = UInt64(hexString, radix: 16) else { return nil }
        let r = CGFloat((int >> 16) & 0xFF) / 255.0
        let g = CGFloat((int >> 8) & 0xFF) / 255.0
        let b = CGFloat(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
