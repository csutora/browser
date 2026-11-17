import AppKit
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowManager: WindowManager!
    var modelContainer: ModelContainer!
    let tabManager = TabManager()
    let historyManager = HistoryManager()
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "isDocked": true,
            "sidebarWidth": 260.0,
            "fullscreenSidebarRadius": 13,
            "includeSearchSuggestions": true,
            "includeHistorySuggestions": true
        ])

        do {
            modelContainer = try ModelContainer(for: Tab.self, WindowModel.self, HistoryEntry.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        tabManager.modelContext = modelContainer.mainContext
        historyManager.modelContext = modelContainer.mainContext

        // Multi-window: ensure a window exists and adopts any legacy window-less tabs.
        tabManager.ensureDefaultWindow()

        windowManager = WindowManager(
            tabManager: tabManager,
            historyManager: historyManager,
            modelContext: modelContainer.mainContext
        )

        // Route the global keybind monitor to whichever window is key.
        KeybindHandler.shared.onAction = { [weak self] action in
            self?.windowManager.keyController?.handleKeybindAction(action)
        }
        KeybindHandler.shared.start()

        windowManager.restoreWindows()
        setupMainMenu()
        didFinishLaunching = true
    }

    // Keep the app alive with no windows so its menu/keybinds still work; reactivating spawns one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowManager?.ensureAtLeastOneWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        windowManager?.ensureAtLeastOneWindow()
        windowManager?.startGlobalHoverMonitor()
    }

    // Don't track the mouse system-wide while we're backgrounded - nothing to hover.
    func applicationDidResignActive(_ notification: Notification) {
        windowManager?.stopGlobalHoverMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist interaction state for every open tab across all windows.
        let tabs = tabManager.fetchTabs()
        for c in windowManager.controllers {
            for (tabId, state) in c.browserStates {
                if let data = state.captureInteractionState(), let tab = tabs.first(where: { $0.id == tabId }) {
                    tab.interactionState = data
                }
            }
        }
        windowManager.persistAllForTermination()
    }

    // MARK: - Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Dawn", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Dawn", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Dawn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open File...", action: #selector(openFile), keyEquivalent: "o")
        mainMenu.addItem(fileMenuItem)

        // Edit menu (for text field cut/copy/paste)
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(reloadPage), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetZoom), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions (target the key window)

    @objc private func newWindow() {
        windowManager.newWindow()
    }

    @objc private func newTab() {
        if let c = windowManager.keyController {
            c.handleKeybindAction(.newTab)
        } else {
            windowManager.newWindow()
        }
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            FileAccessStore.shared.remember(url)
            let controller = self.windowManager.keyController ?? self.windowManager.newWindow()
            controller.createTab(url: url.absoluteString, switchTo: true)
        }
    }

    @objc private func openSettings() {
        windowManager.keyController?.openSettings()
    }

    @objc private func reloadPage() {
        windowManager.keyController?.handleKeybindAction(.refresh)
    }

    @objc private func zoomIn() {
        windowManager.keyController?.handleKeybindAction(.zoomIn)
    }

    @objc private func zoomOut() {
        windowManager.keyController?.handleKeybindAction(.zoomOut)
    }

    @objc private func resetZoom() {
        windowManager.keyController?.handleKeybindAction(.resetZoom)
    }
}

// MARK: - Window Manager

// Owns the live MainWindowControllers and maps them to persisted WindowModels. Creates / restores /
// closes windows; closing a window discards its model (and cascade its tabs), while app termination
// keeps every model for next-launch restore.
final class WindowManager {
    let tabManager: TabManager
    let historyManager: HistoryManager
    let modelContext: ModelContext
    private(set) var controllers: [MainWindowController] = []
    private var isTerminating = false
    private weak var dragForeignTarget: MainWindowController?

    // Sidebar hover is line-crossing, not zone-testing: each window opens its sidebar when the cursor
    // sweeps across a trigger line just inside its left edge (robust to fast moves that would skip a thin
    // zone, and it can't bleed into a neighbour the cursor never crosses into). The local monitor sees
    // moves over our own windows; the global one sees moves over the desktop/other apps (the OS keeps
    // those disjoint) and is the only one that costs anything in the background, so it's paused when we're
    // not the active app. Both feed the same throttled handler. `prevMouse` is the other end of each
    // sampled segment.
    private var hoverLocalMonitor: Any?
    private var hoverGlobalMonitor: Any?
    private var lastHoverCheck: CFTimeInterval = 0
    private var prevMouse: NSPoint?

    init(tabManager: TabManager, historyManager: HistoryManager, modelContext: ModelContext) {
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.modelContext = modelContext

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updateHover()
            return event
        }
        startGlobalHoverMonitor()
    }

    // Paused while Dawn isn't the active app (the global monitor is the one that fires on every system
    // mouse move regardless of focus). `prevMouse` is reset so the first segment after reactivating
    // doesn't span a stale jump and spuriously cross lines.
    func startGlobalHoverMonitor() {
        guard hoverGlobalMonitor == nil else { return }
        prevMouse = NSEvent.mouseLocation
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.updateHover()
        }
    }

    func stopGlobalHoverMonitor() {
        if let monitor = hoverGlobalMonitor { NSEvent.removeMonitor(monitor) }
        hoverGlobalMonitor = nil
    }

    func updateHover() {
        let now = CACurrentMediaTime()
        guard now - lastHoverCheck >= 1.0 / 30.0 else { return }
        lastHoverCheck = now
        let mouse = NSEvent.mouseLocation
        let prev = prevMouse ?? mouse
        prevMouse = mouse
        for controller in controllers {
            controller.updateHover(from: prev, to: mouse)
        }
    }

    var keyController: MainWindowController? {
        controllers.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.last
    }

    private func windowModels() -> [WindowModel] {
        (try? modelContext.fetch(FetchDescriptor<WindowModel>(sortBy: [SortDescriptor(\.orderIndex)]))) ?? []
    }

    func restoreWindows() {
        for wm in windowModels() { open(wm) }
        ensureAtLeastOneWindow()
    }

    func ensureAtLeastOneWindow() {
        guard controllers.isEmpty else { return }
        // Reopen the kept window model (the last closed window, with its tabs) rather than spawning a
        // blank one - single-window-with-many-tabs is the default workflow, so it should always return.
        if let wm = windowModels().first {
            let controller = open(wm)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow()
        }
    }

    @discardableResult
    func newWindow() -> MainWindowController {
        let orderIndex = (windowModels().map(\.orderIndex).max() ?? -1) + 1
        let wm = WindowModel(orderIndex: orderIndex)
        modelContext.insert(wm)
        _ = tabManager.createTab(in: wm, switchTo: true)
        try? modelContext.save()

        let previousKeyWindow = keyController?.window
        let controller = open(wm)
        if let prev = previousKeyWindow, let win = controller.window {
            win.cascadeTopLeft(from: NSPoint(x: prev.frame.minX, y: prev.frame.maxY))
        }
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }


    @discardableResult
    private func open(_ wm: WindowModel) -> MainWindowController {
        let controller = MainWindowController(
            tabManager: tabManager,
            historyManager: historyManager,
            modelContext: modelContext,
            windowModel: wm
        )
        controller.windowManager = self
        controller.onWindowClose = { [weak self, weak controller] in self?.handleClose(controller) }
        controllers.append(controller)
        controller.showWindow(nil)
        if wm.frame.width > 0, let win = controller.window {
            win.setFrame(wm.frame, display: true)
        }
        return controller
    }

    private func handleClose(_ controller: MainWindowController?) {
        guard let controller = controller else { return }
        controller.persistFrame()
        controller.persistInteractionState()
        guard !isTerminating else { return }   // quit keeps every model for restore

        controllers.removeAll { $0 === controller }
        // Keep the last window's model (and tabs) so the next spawned window restores it; only delete
        // a window's model when other windows are still open.
        if !controllers.isEmpty {
            modelContext.delete(controller.windowModel)
        }
        try? modelContext.save()
    }

    func persistAllForTermination() {
        isTerminating = true
        for controller in controllers { controller.persistFrame() }
        tabManager.saveNow()
    }

    // MARK: - Cross-window drag coordination

    // Reported on each move of a tab drag (screen coords). Reveals/makes-space in whatever window the
    // cursor is over, so the whole multi-window set behaves like one tab system.
    func tabDragMoved(to screenPoint: CGPoint, source: MainWindowController) {
        // Make space in the frontmost window under the cursor (z-order, so a window revealed behind via
        // cmd-` wins over the one it overlaps). The source makes its own space via its pile gap.
        let under = topmostController(under: screenPoint)
        let foreign = (under !== source) ? under : nil
        if dragForeignTarget !== foreign {
            dragForeignTarget?.endForeignTabDrag()
            dragForeignTarget = foreign
            foreign?.beginForeignTabDrag()
        }
        foreign?.updateForeignTabGap(atScreen: screenPoint)
    }

    func tabDragEnded() {
        dragForeignTarget?.endForeignTabDrag()
        dragForeignTarget = nil
    }

    // The frontmost Dawn window under a screen point (skipping the click-through drag overlay). The drag
    // pile is handed to whatever this returns, so every window is just a drop target like any other.
    func topmostController(under p: CGPoint) -> MainWindowController? {
        for win in NSApp.orderedWindows where win.isVisible && win.frame.contains(p) {
            if let controller = controllers.first(where: { $0.window === win }) { return controller }
            if !win.ignoresMouseEvents { return nil }   // an opaque non-Dawn window occludes
        }
        return nil
    }

    // A pile was dropped outside its own list. Commit the model move into whatever window is under the
    // cursor (or a new torn-off one) and hand back that window's sidebar, which adopts the SAME live
    // pile and runs the identical drop animation. nil -> nothing valid under the cursor: spring home.
    func handOffPile(_ ids: [UUID], from source: MainWindowController, at screenPoint: CGPoint) -> SidebarViewController? {
        if let target = topmostController(under: screenPoint) {
            if target === source { return nil }   // my own window/content: the source handles it
            guard let slot = target.tabListInsertionIndex(atScreen: screenPoint) else { return nil }
            commitMove(ids, from: source, to: target, at: slot)
            return target.sidebar
        }
        return tearOffNewWindow(ids, from: source, at: screenPoint)?.sidebar
    }

    // MARK: - Moving tabs between windows

    // Tear `ids` (in list order) out of `src` into a brand-new window positioned at the drop point, and
    // return it so the handed-off pile can scatter into its list. The cells start visible; the adopting
    // pile hides and then animates them in (same run loop, so no flash).
    func tearOffNewWindow(_ ids: [UUID], from src: MainWindowController, at screenPoint: CGPoint) -> MainWindowController? {
        let movingTabs = ids.compactMap { id in src.tabs.first(where: { $0.id == id }) }
        guard !movingTabs.isEmpty else { return nil }

        // New window model owning the moved tabs, built BEFORE the controller so its loadTabs sees a
        // non-empty window (and doesn't auto-insert a blank tab).
        let orderIndex = (windowModels().map(\.orderIndex).max() ?? -1) + 1
        let wm = WindowModel(orderIndex: orderIndex)
        modelContext.insert(wm)
        for (i, tab) in movingTabs.enumerated() { tab.window = wm; tab.sortIndex = i }
        wm.currentTabId = movingTabs.first?.id
        finalizeSource(src, removedIds: Set(ids))
        try? modelContext.save()

        let dst = open(wm)              // schedules dst's web setup async
        if let win = dst.window {
            win.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 120, y: screenPoint.y + 24))
        }
        dst.window?.makeKeyAndOrderFront(nil)

        transferBrowserStates(ids, from: src, to: dst)
        finishSource(src)
        return dst
    }

    // Commit `ids` from `src` into the existing window `dst` at `index` (model + live web views only).
    // The visual handoff (scatter into dst's list) is run by dst's sidebar adopting the pile, so this
    // does no animation and leaves dst's current tab untouched.
    func commitMove(_ ids: [UUID], from src: MainWindowController, to dst: MainWindowController, at index: Int) {
        guard src !== dst else { return }
        let movingTabs = ids.compactMap { id in src.tabs.first(where: { $0.id == id }) }
        guard !movingTabs.isEmpty else { return }

        let dstOrder = dst.tabs
        let at = max(0, min(index, dstOrder.count))
        var newDstOrder = dstOrder
        newDstOrder.insert(contentsOf: movingTabs, at: at)
        for tab in movingTabs { tab.window = dst.windowModel }
        for (i, tab) in newDstOrder.enumerated() { tab.sortIndex = i }
        // Don't steal focus: the destination keeps its own current tab; the dropped tabs just appear.

        finalizeSource(src, removedIds: Set(ids))
        try? modelContext.save()

        transferBrowserStates(ids, from: src, to: dst)
        finishSource(src)
        dst.clearForeignTabDrag()       // drop the phantom gap before rebuilding with the real cells
        dst.refreshTabs()
        dst.handleTabSwitch()
        dst.window?.makeKeyAndOrderFront(nil)
    }

    // Move the live BrowserState (and its WKWebView) for each id; re-point new-tab requests at dst.
    private func transferBrowserStates(_ ids: [UUID], from src: MainWindowController, to dst: MainWindowController) {
        for id in ids {
            guard let state = src.browserStates.removeValue(forKey: id) else { continue }
            state.onNewTabRequested = { [weak dst] url, switchTo in
                dst?.createTab(url: url.absoluteString, switchTo: switchTo)
            }
            dst.browserStates[id] = state
        }
    }

    // Renumber the source window's remaining tabs and pick a sensible new current tab if it left.
    private func finalizeSource(_ src: MainWindowController, removedIds: Set<UUID>) {
        let original = src.tabs.sorted { $0.sortIndex < $1.sortIndex }
        let remaining = original.filter { !removedIds.contains($0.id) }
        for (i, tab) in remaining.enumerated() { tab.sortIndex = i }
        if let current = src.windowModel.currentTabId, removedIds.contains(current) {
            let firstRemovedIdx = original.firstIndex { removedIds.contains($0.id) } ?? 0
            let idx = min(firstRemovedIdx, max(0, remaining.count - 1))
            src.windowModel.currentTabId = remaining.isEmpty ? nil : remaining[idx].id
        }
    }

    // After tabs left the source: detach their (now-stale) web views via a sync refresh, then close
    // the window if it has no tabs left.
    private func finishSource(_ src: MainWindowController) {
        if src.windowModel.tabs.isEmpty {
            DispatchQueue.main.async { [weak src] in src?.window?.close() }
        } else {
            src.refreshTabs()
            src.handleTabSwitch()
        }
    }
}
