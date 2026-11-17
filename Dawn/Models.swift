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
    // The window this tab belongs to. Inverse of WindowModel.tabs; nil only for legacy tabs before
    // the multi-window migration adopts them. sortIndex orders tabs within their window.
    var window: WindowModel?

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

// MARK: - Window Model

// One browser window: owns its tabs (cascade-deleted with it), remembers its current tab and its
// on-screen frame, and orders itself among windows for restore. sortIndex orders tabs within it.
@Model
final class WindowModel {
    @Attribute(.unique) var id: UUID
    var orderIndex: Int
    var currentTabIdString: String
    var isDocked: Bool = true
    var frameX: Double
    var frameY: Double
    var frameW: Double
    var frameH: Double
    @Relationship(deleteRule: .cascade, inverse: \Tab.window) var tabs: [Tab]

    var currentTabId: UUID? {
        get { UUID(uuidString: currentTabIdString) }
        set { currentTabIdString = newValue?.uuidString ?? "" }
    }

    var frame: NSRect {
        get { NSRect(x: frameX, y: frameY, width: frameW, height: frameH) }
        set { frameX = newValue.minX; frameY = newValue.minY; frameW = newValue.width; frameH = newValue.height }
    }

    init(id: UUID = UUID(), orderIndex: Int = 0, frame: NSRect = .zero) {
        self.id = id
        self.orderIndex = orderIndex
        self.currentTabIdString = ""
        self.frameX = frame.minX
        self.frameY = frame.minY
        self.frameW = frame.width
        self.frameH = frame.height
        self.tabs = []
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
//
// Store service for the SwiftData tab/window store. Tab operations are window-scoped (they take a
// WindowModel); the owning MainWindowController drives its own refresh afterwards, so there's no
// global "tabs changed" broadcast. The current tab lives on the WindowModel, not here.
class TabManager: ObservableObject {
    var modelContext: ModelContext?
    private var saveTask: DispatchWorkItem?

    // Recently-closed tabs per window (most recent last), in-memory for the session.
    private var closedTabsByWindow: [UUID: [ClosedTabInfo]] = [:]
    private let maxClosedTabs = 20

    func canReopenClosedTab(in window: WindowModel) -> Bool {
        !(closedTabsByWindow[window.id]?.isEmpty ?? true)
    }

    func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in try? self?.modelContext?.save() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    func saveNow() {
        saveTask?.cancel()
        try? modelContext?.save()
    }

    // All tabs across every window (used at quit to persist interaction state).
    func fetchTabs() -> [Tab] {
        let descriptor = FetchDescriptor<Tab>(sortBy: [SortDescriptor(\.sortIndex)])
        return (try? modelContext?.fetch(descriptor)) ?? []
    }

    func orderedTabs(in window: WindowModel) -> [Tab] {
        window.tabs.sorted { $0.sortIndex < $1.sortIndex }
    }

    // Multi-window bootstrap: make sure at least one window exists and every tab belongs to one.
    // Legacy stores (pre-window) have all tabs with window == nil; they get adopted into one window
    // that inherits the old global current tab (from UserDefaults). Run once at launch.
    func ensureDefaultWindow() {
        guard let context = modelContext else { return }
        let windows = (try? context.fetch(FetchDescriptor<WindowModel>())) ?? []
        if let first = windows.min(by: { $0.orderIndex < $1.orderIndex }) {
            let orphans = (try? context.fetch(FetchDescriptor<Tab>(predicate: #Predicate { $0.window == nil }))) ?? []
            guard !orphans.isEmpty else { return }
            for tab in orphans { tab.window = first }
        } else {
            let win = WindowModel(orderIndex: 0)
            context.insert(win)
            for tab in fetchTabs() { tab.window = win }
            win.currentTabId = UserDefaults.standard.string(forKey: "currentTabId").flatMap { UUID(uuidString: $0) }
            if UserDefaults.standard.object(forKey: "isDocked") != nil {
                win.isDocked = UserDefaults.standard.bool(forKey: "isDocked")
            }
        }
        try? context.save()
    }

    @discardableResult
    func createTab(in window: WindowModel, url: String = "https://www.google.com", switchTo: Bool = false) -> Tab {
        let t = Tab(url: url, sortIndex: window.tabs.count)
        modelContext?.insert(t)
        t.window = window
        if switchTo { window.currentTabId = t.id }
        try? modelContext?.save()
        return t
    }

    func closeTab(_ tab: Tab, in window: WindowModel, interactionState: Data? = nil) {
        guard let context = modelContext else { return }
        let closedId = tab.id

        if !tab.isSettings {
            var stack = closedTabsByWindow[window.id] ?? []
            stack.append(ClosedTabInfo(
                title: tab.title, url: tab.url, sortIndex: tab.sortIndex,
                tabType: tab.tabType, backgroundColorHex: tab.backgroundColorHex,
                interactionState: interactionState
            ))
            if stack.count > maxClosedTabs { stack.removeFirst() }
            closedTabsByWindow[window.id] = stack
        }

        let ordered = orderedTabs(in: window)
        if window.currentTabId == closedId, let index = ordered.firstIndex(where: { $0.id == closedId }) {
            let newIndex = index + 1 < ordered.count ? index + 1 : index - 1
            window.currentTabId = newIndex >= 0 ? ordered[newIndex].id : nil
        }
        context.delete(tab)
        for (i, t) in ordered.filter({ $0.id != closedId }).enumerated() { t.sortIndex = i }
        try? context.save()
    }

    @discardableResult
    func reopenLastClosedTab(in window: WindowModel) -> Tab? {
        guard let context = modelContext, var stack = closedTabsByWindow[window.id], let info = stack.popLast() else { return nil }
        closedTabsByWindow[window.id] = stack

        let ordered = orderedTabs(in: window)
        let insertAt = min(info.sortIndex, ordered.count)
        for existing in ordered where existing.sortIndex >= insertAt { existing.sortIndex += 1 }
        let t = Tab(title: info.title, url: info.url, sortIndex: insertAt, tabType: info.tabType)
        t.backgroundColorHex = info.backgroundColorHex
        t.interactionState = info.interactionState
        context.insert(t)
        t.window = window
        window.currentTabId = t.id
        try? context.save()
        return t
    }

    func selectTab(_ tab: Tab, in window: WindowModel) {
        window.currentTabId = tab.id
        tab.lastAccessedAt = Date()
        scheduleSave()
    }

    @discardableResult
    func openSettings(in window: WindowModel) -> Tab {
        if let settings = orderedTabs(in: window).first(where: { $0.isSettings }) {
            window.currentTabId = settings.id
            scheduleSave()
            return settings
        }
        let t = Tab(title: "Settings", url: "dawn://settings", sortIndex: window.tabs.count, tabType: .settings)
        modelContext?.insert(t)
        t.window = window
        window.currentTabId = t.id
        try? modelContext?.save()
        return t
    }

    func updateSettingsPath(_ path: String, in window: WindowModel) {
        guard let currentId = window.currentTabId,
              let tab = orderedTabs(in: window).first(where: { $0.id == currentId }), tab.isSettings else { return }
        tab.url = "dawn://\(path)"
        try? modelContext?.save()
    }

    func updateTab(_ id: UUID, title: String? = nil, url: String? = nil, scroll: CGPoint? = nil, backgroundColorHex: String? = nil) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })
        if let tab = try? context.fetch(descriptor).first {
            if let t = title { tab.title = t }
            if let u = url { tab.url = u }
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
