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
    @Attribute(.externalStorage) var sessionStorage: Data?
    // a favorite: shown as a tile in every window, set to come back to this url when it's closed. it
    // belongs to no window.
    var pinnedURL: String?
    var favoriteIndex: Int = 0
    // a favorite that was closed: it waits to be opened again, or for dawn to start again
    var favoriteClosed: Bool = false
    var scrollX: Double = 0.0
    var scrollY: Double = 0.0
    var zoomScale: Double = 1.0
    var backgroundColorHex: String?
    // the page's icon in the icon store; nil shows the placeholder
    var iconKey: String?
    // a favorite's page's touch icon, for its tile when the icon is too small for it
    var touchIconKey: String?
    var lastAccessedAt: Date = Date()
    // The window this tab belongs to. Inverse of WindowModel.tabs; nil only for legacy tabs before
    // the multi-window migration adopts them. sortIndex orders tabs within their window.
    var window: WindowModel?

    var tabType: TabType {
        get { TabType(rawValue: tabTypeRaw) ?? .web }
        set { tabTypeRaw = newValue.rawValue }
    }

    var isSettings: Bool { tabType == .settings }
    var isFavorite: Bool { pinnedURL != nil }

    var savedPage: SavedPage {
        get { SavedPage(interactionState: interactionState, sessionStorage: sessionStorage, zoom: zoomScale) }
        set {
            interactionState = newValue.interactionState
            sessionStorage = newValue.sessionStorage
            zoomScale = newValue.zoom
        }
    }

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
    let id: UUID
    let title: String
    let url: String
    let sortIndex: Int
    let tabType: TabType
    let backgroundColorHex: String?
    let iconKey: String?
    var interactionState: Data?
    var sessionStorage: Data?
    var zoom: Double = 1
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
            let orphans = (try? context.fetch(FetchDescriptor<Tab>(predicate: #Predicate { $0.window == nil && $0.pinnedURL == nil }))) ?? []
            guard !orphans.isEmpty else { return }
            for tab in orphans { tab.window = first }
        } else {
            let win = WindowModel(orderIndex: 0)
            context.insert(win)
            for tab in fetchTabs() where !tab.isFavorite { tab.window = win }
            win.currentTabId = UserDefaults.standard.string(forKey: "currentTabId").flatMap { UUID(uuidString: $0) }
            if UserDefaults.standard.object(forKey: "isDocked") != nil {
                win.isDocked = UserDefaults.standard.bool(forKey: "isDocked")
            }
        }
        try? context.save()
    }

    @discardableResult
    func createTab(in window: WindowModel, url: String = "https://www.google.com", switchTo: Bool = false, at index: Int? = nil) -> Tab {
        let ordered = orderedTabs(in: window)
        let at = min(index ?? ordered.count, ordered.count)
        for existing in ordered where existing.sortIndex >= at { existing.sortIndex += 1 }
        let t = Tab(url: url, sortIndex: at)
        modelContext?.insert(t)
        t.window = window
        if switchTo { window.currentTabId = t.id }
        try? modelContext?.save()
        return t
    }

    // closes a tab, keeping what's needed to reopen it. a tab whose page was live has its state filled
    // in once the page has been read (see closedTabStateCaptured); an unloaded one already holds it.
    func closeTab(_ tab: Tab, in window: WindowModel) {
        guard let context = modelContext else { return }
        let closedId = tab.id

        if !tab.isSettings {
            var stack = closedTabsByWindow[window.id] ?? []
            stack.append(ClosedTabInfo(
                id: tab.id, title: tab.title, url: tab.url, sortIndex: tab.sortIndex,
                tabType: tab.tabType, backgroundColorHex: tab.backgroundColorHex, iconKey: tab.iconKey,
                interactionState: tab.interactionState, sessionStorage: tab.sessionStorage, zoom: tab.zoomScale
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
        t.iconKey = info.iconKey
        t.savedPage = SavedPage(interactionState: info.interactionState, sessionStorage: info.sessionStorage, zoom: info.zoom)
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

    func tab(_ id: UUID) -> Tab? {
        try? modelContext?.fetch(FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })).first
    }

    func updateTabIcon(_ id: UUID, iconKey: String?) {
        guard let tab = tab(id), tab.iconKey != iconKey else { return }
        tab.iconKey = iconKey
        scheduleSave()
        NotificationCenter.default.post(name: .tabDataDidChange, object: id)
    }

    func updateTabTouchIcon(_ id: UUID, iconKey: String?) {
        guard let tab = tab(id), tab.touchIconKey != iconKey else { return }
        tab.touchIconKey = iconKey
        scheduleSave()
        NotificationCenter.default.post(name: .tabDataDidChange, object: id)
    }

    func updateTabZoom(_ id: UUID, zoom: Double) {
        guard let tab = tab(id) else { return }
        tab.zoomScale = zoom
        scheduleSave()
    }

    // keeps what a tab's page would come back as, for when its web view is gone
    func savePage(_ id: UUID, _ page: SavedPage) {
        guard let tab = tab(id) else { return }
        tab.savedPage = page
        scheduleSave()
    }

    // a closed tab's page, read after it was closed (it had to stop showing first)
    func closedTabStateCaptured(_ id: UUID, _ page: SavedPage) {
        for (window, stack) in closedTabsByWindow {
            guard let index = stack.firstIndex(where: { $0.id == id }) else { continue }
            closedTabsByWindow[window]?[index].interactionState = page.interactionState
            closedTabsByWindow[window]?[index].sessionStorage = page.sessionStorage
            closedTabsByWindow[window]?[index].zoom = page.zoom
        }
    }

    // MARK: Favorites
    //
    // favorites belong to no window: every window shows all of them, and a favorite's page is one page,
    // shown in whichever window is using it

    // in order as they are now: sorted here rather than by the store, which sorts by what was last
    // saved and so could hand back an order that's since changed
    func favorites() -> [Tab] {
        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.pinnedURL != nil })
        return ((try? modelContext?.fetch(descriptor)) ?? []).sorted { $0.favoriteIndex < $1.favoriteIndex }
    }

    // makes tabs favorites at a place among the favorites, set to come back to the page each shows now
    func pin(_ tabs: [Tab], at index: Int) {
        let pinning = Set(tabs.map(\.id))
        var order = favorites().filter { !pinning.contains($0.id) }
        order.insert(contentsOf: tabs, at: max(0, min(index, order.count)))
        let windows = Set(tabs.compactMap(\.window).map(\.persistentModelID))
        for tab in tabs {
            tab.pinnedURL = tab.pinnedURL ?? tab.url
            tab.favoriteClosed = false
            tab.window = nil
        }
        for (i, tab) in order.enumerated() { tab.favoriteIndex = i }
        for window in (try? modelContext?.fetch(FetchDescriptor<WindowModel>())) ?? [] where windows.contains(window.persistentModelID) {
            for (i, tab) in orderedTabs(in: window).enumerated() { tab.sortIndex = i }
        }
        try? modelContext?.save()
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    // turns a favorite back into an ordinary tab of a window, at a place among its tabs
    func unpin(_ tab: Tab, into window: WindowModel, at index: Int) {
        var order = orderedTabs(in: window)
        order.insert(tab, at: max(0, min(index, order.count)))
        tab.pinnedURL = nil
        tab.favoriteClosed = false
        tab.window = window
        for (i, t) in order.enumerated() { t.sortIndex = i }
        for (i, t) in favorites().enumerated() { t.favoriteIndex = i }
        try? modelContext?.save()
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    func reorderFavorites(_ ids: [UUID]) {
        let all = favorites()
        for (i, id) in ids.enumerated() { all.first(where: { $0.id == id })?.favoriteIndex = i }
        try? modelContext?.save()
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    // a closed favorite forgets where it went: it comes back fresh at its pinned url
    func closeFavorite(_ tab: Tab) {
        tab.favoriteClosed = true
        tab.url = tab.pinnedURL ?? tab.url
        tab.savedPage = SavedPage()
        try? modelContext?.save()
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    func openFavorite(_ tab: Tab) {
        guard tab.favoriteClosed else { return }
        tab.favoriteClosed = false
        scheduleSave()
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    // the icons of every tab, open or recently closed
    func iconKeys() -> Set<String> {
        let tabs = fetchTabs()
        return Set(tabs.compactMap(\.iconKey) + tabs.compactMap(\.touchIconKey) + closedTabsByWindow.values.joined().compactMap(\.iconKey))
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let tabsDidChange = Notification.Name("tabsDidChange")
    static let tabDataDidChange = Notification.Name("tabDataDidChange")
    static let favoritesDidChange = Notification.Name("favoritesDidChange")
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
