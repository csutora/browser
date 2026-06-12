import AppKit
import WebKit
import Combine

class WebContentViewController: NSViewController {
    let tabManager: TabManager
    let historyManager: HistoryManager

    private var backgroundColorView: NSView!
    private var webViewContainer: NSView!
    private var settingsVC: SettingsViewController?
    private var settingsContainer: NSView?

    // Every tab's web view is retained here, but only the active one (and one warm previous tab,
    // kept attached for instant switch-back) is in the view hierarchy. Detached tabs are suspended
    // by WebKit and, crucially, never reflow on window resize / dock (a hidden-but-attached web view
    // still does, because WebKit's setFrameSize has no visibility guard).
    private var addedWebViews: [UUID: WKWebView] = [:]
    private var activeTabId: UUID?
    private var warmTabId: UUID?
    private let defaultColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0)

    private var activeWebView: WKWebView? { activeTabId.flatMap { addedWebViews[$0] } }

    init(tabManager: TabManager, historyManager: HistoryManager) {
        self.tabManager = tabManager
        self.historyManager = historyManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        backgroundColorView = NSView()
        backgroundColorView.wantsLayer = true
        backgroundColorView.layer?.backgroundColor = defaultColor.cgColor
        backgroundColorView.autoresizingMask = [.width, .height]
        container.addSubview(backgroundColorView)

        webViewContainer = NSView()
        webViewContainer.wantsLayer = true
        webViewContainer.autoresizingMask = [.width, .height]
        container.addSubview(webViewContainer)

        self.view = container
    }

    // While a dock/undock animation drives the web view size (frame-by-frame for dock, or pinned
    // to its final size for undock), neither viewDidLayout nor the autoresizing mask may resize it
    // out from under us.
    var drivingWebViewSizeExternally = false {
        didSet {
            activeWebView?.autoresizingMask = drivingWebViewSizeExternally ? [] : [.width, .height]
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        backgroundColorView.frame = bounds
        webViewContainer.frame = bounds
        settingsContainer?.frame = bounds

        if !drivingWebViewSizeExternally {
            activeWebView?.frame = webViewContainer.bounds
        }
    }

    // Pin the visible web view to a fixed (final) size, centered in its container via centered
    // autoresizing margins. As the container animates during dock/undock, the already-reflowed page
    // stays anchored at the center while the area resizes around it (overflowing or insetting), so
    // the live view never reflows on screen.
    func pinVisibleWebViewCentered(_ size: CGSize) {
        drivingWebViewSizeExternally = true
        guard let wv = activeWebView else { return }
        let b = webViewContainer.bounds
        let frame = CGRect(
            x: ((b.width - size.width) / 2).rounded(),
            y: ((b.height - size.height) / 2).rounded(),
            width: size.width, height: size.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wv.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        wv.frame = frame
        CATransaction.commit()
    }

    // Run completion once the active web view has committed a repaint, so a reveal waits until the
    // content has actually reflowed to its new size. Uses WebKit's private SPI where available, with
    // an immediate fallback and a timeout so a suspended page can never strand the animation.
    func afterVisibleWebViewPaint(_ completion: @escaping () -> Void) {
        guard let wv = activeWebView else { completion(); return }
        afterPaint(of: wv, completion)
    }

    private func afterPaint(of wv: WKWebView, _ completion: @escaping () -> Void) {
        var fired = false
        let fire = { if !fired { fired = true; completion() } }
        let sel = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        if wv.responds(to: sel) {
            let block: @convention(block) () -> Void = { fire() }
            wv.perform(sel, with: block)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fire)
        } else {
            completion()
        }
    }

    // Snapshot the active web view's rendered content, so a dock/undock can cover it with a still
    // image while the live view reflows to its new size off screen.
    func snapshotVisibleWebView(_ completion: @escaping (NSImage?) -> Void) {
        guard let wv = activeWebView else { completion(nil); return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        wv.takeSnapshot(with: config) { image, _ in completion(image) }
    }

    // MARK: - Web View Management

    func syncWebViews(browserStates: [UUID: BrowserState], tabs: [Tab], currentTabId: UUID?) {
        // Register new web views without attaching them; they get attached on activation.
        for (id, state) in browserStates {
            if addedWebViews[id] == nil {
                let wv = state.webView
                wv.autoresizingMask = []
                wv.frame = webViewContainer.bounds
                addedWebViews[id] = wv
                state.loadInitialContentIfNeeded()
            }
        }

        // Remove stale web views
        let staleIds = Set(addedWebViews.keys).subtracting(browserStates.keys)
        for id in staleIds {
            addedWebViews[id]?.removeFromSuperview()
            addedWebViews.removeValue(forKey: id)
            if activeTabId == id { activeTabId = nil }
            if warmTabId == id { warmTabId = nil }
        }

        switchToTab(currentTabId, browserStates: browserStates, tabs: tabs)
    }

    func switchToTab(_ currentTabId: UUID?, browserStates: [UUID: BrowserState], tabs: [Tab]) {
        let isSettingsTab = tabs.first(where: { $0.id == currentTabId })?.isSettings ?? false

        if isSettingsTab {
            ensureSettingsView()
            settingsContainer?.isHidden = false
            if let tab = tabs.first(where: { $0.id == currentTabId }) {
                let path = extractSettingsPath(from: tab.url)
                if settingsVC?.navigationState.currentPath != path {
                    settingsVC?.navigationState.currentPath = path
                }
            }
            // Keep the current web tab warm (attached, hidden) so returning to it is instant.
            if let wv = activeWebView {
                wv.isHidden = true
                wv.autoresizingMask = []
            }
            if let active = activeTabId {
                warmTabId = active
                activeTabId = nil
            }
            trimDetachedTabs()
            return
        }

        settingsContainer?.isHidden = true

        if let id = currentTabId, let target = addedWebViews[id] {
            activate(id: id, target: target)
        }

        if let id = currentTabId, let state = browserStates[id], let color = state.fetchedBackgroundColor {
            backgroundColorView.layer?.backgroundColor = color.cgColor
        } else {
            backgroundColorView.layer?.backgroundColor = defaultColor.cgColor
        }
    }

    private func activate(id: UUID, target: WKWebView) {
        let oldActive = activeTabId
        if id == oldActive {
            target.isHidden = false
            if target.superview == nil { webViewContainer.addSubview(target) }
            if !drivingWebViewSizeExternally {
                target.autoresizingMask = [.width, .height]
                target.frame = webViewContainer.bounds
            }
            return
        }

        let oldActiveWv = oldActive.flatMap { addedWebViews[$0] }

        let swapIn: () -> Void = { [weak self] in
            guard let self = self else { return }
            target.isHidden = false
            target.autoresizingMask = [.width, .height]
            self.webViewContainer.addSubview(target) // bring to front
            if let oldActiveWv, oldActiveWv !== target {
                oldActiveWv.isHidden = true
                oldActiveWv.autoresizingMask = []
            }
            self.activeTabId = id
            if oldActive != id { self.warmTabId = oldActive }
            self.trimDetachedTabs()
        }

        // Instant when the target is already attached at the current size (the common A<->B toggle);
        // otherwise attach it behind the current tab, reflow it, and reveal only once it has painted.
        let instant = target.superview != nil && target.frame.size == webViewContainer.bounds.size
        if instant {
            swapIn()
        } else {
            if let oldActiveWv, oldActiveWv !== target {
                webViewContainer.addSubview(target, positioned: .below, relativeTo: oldActiveWv)
            } else {
                webViewContainer.addSubview(target)
            }
            target.isHidden = false
            target.autoresizingMask = [.width, .height]
            target.frame = webViewContainer.bounds
            afterPaint(of: target, swapIn)
        }
    }

    // Detach every web view that isn't the active or the warm (previous) tab.
    private func trimDetachedTabs() {
        let keep = Set([activeTabId, warmTabId].compactMap { $0 })
        for (id, wv) in addedWebViews where !keep.contains(id) && wv.superview != nil {
            wv.removeFromSuperview()
        }
    }

    private func ensureSettingsView() {
        guard settingsContainer == nil else { return }

        let vc = SettingsViewController(historyManager: historyManager)
        vc.navigationState.onNavigate = { [weak self] path in
            self?.tabManager.updateSettingsPath(path)
        }
        vc.onOpenURL = { [weak self] url in
            guard let self = self else { return }
            self.tabManager.createTab(
                url: url,
                existingCount: self.tabManager.fetchTabs().count
            )
        }

        let container = vc.view
        container.frame = view.bounds
        container.autoresizingMask = [.width, .height]
        view.addSubview(container)

        settingsVC = vc
        settingsContainer = container
    }
}
