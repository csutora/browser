import AppKit
import WebKit

// Every favorite's page, shared by all windows. An open favorite's page is live from launch until it's
// closed (never unloaded to save memory: it's meant to be there the moment it's wanted), and is shown in
// one window at a time: the one that last used it. Another window that has the same favorite selected
// keeps a still of it in its place, and takes the page back when it's used again.
final class FavoritesController {
    private let tabManager: TabManager
    private let historyManager: HistoryManager
    private(set) var states: [UUID: BrowserState] = [:]
    // the window whose content view holds each page
    private var hosts: [UUID: WeakController] = [:]
    // where a favorite's new tabs and windows open: the window using it
    var openTab: ((URL, Bool, MainWindowController?) -> Void)?
    var openWindow: ((URL) -> Void)?
    var openPage: ((WKWebViewConfiguration, URL?, Bool, MainWindowController?) -> WKWebView?)?

    private struct WeakController {
        weak var controller: MainWindowController?
    }

    init(tabManager: TabManager, historyManager: HistoryManager) {
        self.tabManager = tabManager
        self.historyManager = historyManager
    }

    // dawn just started, which is someone looking again: every favorite's page starts loading (closed
    // ones too, since closing only ever lasts until then), laid out at about the size it'll be seen at
    // (the screen's), rather than at none while no window shows it yet
    func start() {
        let size = NSScreen.main?.visibleFrame.size ?? .zero
        for tab in tabManager.favorites() {
            let state = ensureLive(tab)
            state.webView.frame = NSRect(origin: .zero, size: size)
            state.loadInitialContentIfNeeded()
        }
    }

    func state(for id: UUID) -> BrowserState? {
        states[id]
    }

    func host(of id: UUID) -> MainWindowController? {
        hosts[id]?.controller
    }

    // the favorite's page, made live if it was closed
    @discardableResult
    func ensureLive(_ tab: Tab) -> BrowserState {
        if let state = states[tab.id] { return state }
        tabManager.openFavorite(tab)
        let state = BrowserState(tabId: tab.id, tabManager: tabManager, historyManager: historyManager,
                                 initialURL: URL(string: tab.url), saved: tab.savedPage, iconKey: tab.iconKey)
        adopt(state)
        // its tile in every window shows it running
        NotificationCenter.default.post(name: .tabDataDidChange, object: tab.id)
        return state
    }

    // a live page joining the favorites: one made here, or a tab's being pinned, which stays in the
    // window that holds it
    func adopt(_ state: BrowserState, hostedBy host: MainWindowController? = nil) {
        let id = state.tabId
        state.onNewTabRequested = { [weak self] url, switchTo in
            self?.openTab?(url, switchTo, self?.host(of: id))
        }
        state.onNewWindowRequested = { [weak self] url in self?.openWindow?(url) }
        state.onOpenPage = { [weak self] configuration, url, switchTo in
            self?.openPage?(configuration, url, switchTo, self?.host(of: id))
        }
        // a favorite stays, even when its page closes itself
        state.onClose = nil
        states[id] = state
        if let host { hosts[id] = WeakController(controller: host) }
    }

    // a live page leaving the favorites (being unpinned) for `destination`, which takes it over. the
    // window holding it lets go of it, unless that's the destination.
    func release(_ id: UUID, keepingIn destination: MainWindowController) -> BrowserState? {
        if let host = hosts[id]?.controller, host !== destination { host.webContent.relinquish(id, still: nil) }
        hosts[id] = nil
        return states.removeValue(forKey: id)
    }

    // has `controller` show the favorite's page, moving it out of the window that holds it. that window,
    // when it's showing the page, keeps a still of it in its place. `then` runs once the page is
    // controller's to show.
    func claim(_ id: UUID, for controller: MainWindowController, then: @escaping () -> Void) {
        let previous = hosts[id]?.controller
        hosts[id] = WeakController(controller: controller)
        guard let previous, previous !== controller else { return then() }
        guard previous.webContent.isShowing(id), let state = states[id] else {
            previous.webContent.relinquish(id, still: nil)
            return then()
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        state.webView.takeSnapshot(with: configuration) { [weak previous] image, _ in
            previous?.webContent.relinquish(id, still: image)
            then()
        }
    }

    // a favorite closed for good, until it's opened again: its page goes (and whatever it held with
    // it), and it'll start over at its pinned url
    func close(_ tab: Tab) {
        hosts[tab.id]?.controller?.webContent.relinquish(tab.id, still: nil)
        hosts[tab.id] = nil
        states.removeValue(forKey: tab.id)?.webView.removeFromSuperview()
        tabManager.closeFavorite(tab)
    }

    // a favorite removed while its page is gone, or a window that went away
    func forgetHost(_ controller: MainWindowController) {
        for (id, host) in hosts where host.controller === controller || host.controller == nil { hosts[id] = nil }
    }
}
