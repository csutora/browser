import SwiftUI
import SwiftData

extension Notification.Name {
    static let focusURLBar = Notification.Name("focusURLBar")
}

struct ContentView: View {
    @EnvironmentObject var tabManager: TabManager

    @Query(sort: \Tab.sortIndex, animation: .spring(response: 0.35, dampingFraction: 0.75)) private var tabs: [Tab]

    @StateObject private var mouseTracker = MouseTracker()
    @StateObject private var commandPaletteState = CommandPaletteState()
    @State private var browserStates: [UUID: BrowserState] = [:]

    @AppStorage("isDocked") private var isDocked: Bool = true
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260.0
    @AppStorage("fullscreenSidebarRadius") private var fullscreenSidebarRadius: Int = 13

    @State private var dragStartWidth: Double? = nil
    @State private var isResizing: Bool = false
    @State private var draggedTab: Tab?
    @State private var useDockAnimation: Bool = false

    // Track when floating sidebar is fully open (after animation completes)
    @State private var isSidebarFullyOpen: Bool = false
    @State private var sidebarOpenWorkItem: DispatchWorkItem?
    @State private var isFullscreen: Bool = false

    private let keybindHandler = KeybindHandler.shared

    var isFloatingVisible: Bool {
        if isDocked { return false }
        if isResizing { return true }
        return mouseTracker.shouldShowSidebar
    }

    var sidebarOffset: CGFloat {
        isDocked ? 0 : (isFloatingVisible ? 0 : -(CGFloat(sidebarWidth) + 50))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundLayers

            // WebViewContainer handles both web tabs and settings tab
            WebViewContainer(
                tabs: tabs,
                browserStates: browserStates,
                currentTabId: tabManager.currentTabId,
                isDocked: isDocked,
                isFullscreen: isFullscreen,
                sidebarWidth: CGFloat(sidebarWidth),
                onSettingsNavigate: { path in
                    tabManager.updateSettingsPath(path)
                }
            )

            sidebar

            resizeHandle

            // Command Palette overlay
            if commandPaletteState.isVisible {
                CommandPaletteView(
                    state: commandPaletteState,
                    onSubmit: { suggestionType in
                        handleCommandPaletteSubmit(suggestionType)
                    },
                    onSwitchToTab: { tab in
                        tabManager.selectTab(tab)
                        commandPaletteState.hide()
                    },
                    onDismiss: {
                        commandPaletteState.hide()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: commandPaletteState.isVisible)
        .onAppear {
            mouseTracker.updateSettings(sidebarWidth: sidebarWidth, isDocked: isDocked)

            if tabManager.currentTabId == nil {
                if let first = tabs.first { tabManager.selectTab(first) }
            }
            syncStates()
            setupKeybindHandler()
        }
        .onChange(of: sidebarWidth) { _, newValue in
            mouseTracker.updateSettings(sidebarWidth: newValue, isDocked: isDocked)
        }
        .onChange(of: isDocked) { _, newValue in
            mouseTracker.updateSettings(sidebarWidth: sidebarWidth, isDocked: newValue)
        }
        .onChange(of: tabs) { _, _ in syncStates() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
        .onChange(of: isFloatingVisible) { _, newValue in
            if newValue {
                // Schedule delayed activation (matches animation duration)
                sidebarOpenWorkItem?.cancel()
                let workItem = DispatchWorkItem { [self] in
                    isSidebarFullyOpen = true
                }
                sidebarOpenWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
            } else {
                // Cancel pending and immediately deactivate
                sidebarOpenWorkItem?.cancel()
                sidebarOpenWorkItem = nil
                isSidebarFullyOpen = false
            }
        }
    }

    func setupKeybindHandler() {
        keybindHandler.onAction = { [self] action in
            // If command palette is open, close it for certain actions
            if commandPaletteState.isVisible {
                switch action {
                case .closeTab:
                    // Close palette when closing tab
                    commandPaletteState.hide(saveText: false)
                case .newTab, .focusURLBar:
                    // These reopen palette in different mode, so close first
                    commandPaletteState.hide(saveText: action == .newTab)
                default:
                    break
                }
            }
            handleKeybindAction(action)
        }
        keybindHandler.start()
    }

    func handleKeybindAction(_ action: KeybindAction) {
        switch action {
        case .newTab:
            // Show command palette in newTab mode - recent tabs by last accessed, excluding current
            let recentTabs = tabs
                .filter { $0.id != tabManager.currentTabId }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(5)
            commandPaletteState.show(mode: .newTab, recentTabs: Array(recentTabs))

        case .closeTab:
            guard let currentId = tabManager.currentTabId,
                  let tab = tabs.first(where: { $0.id == currentId }) else { return }
            tabManager.closeTab(tab, allTabs: tabs)

        case .reopenClosedTab:
            tabManager.reopenLastClosedTab(existingCount: tabs.count)

        case .refresh:
            guard let currentId = tabManager.currentTabId,
                  let state = browserStates[currentId] else { return }
            state.reload()

        case .goBack:
            guard let currentId = tabManager.currentTabId,
                  let state = browserStates[currentId] else { return }
            state.goBack()

        case .goForward:
            guard let currentId = tabManager.currentTabId,
                  let state = browserStates[currentId] else { return }
            state.goForward()

        case .previousTab:
            guard let currentId = tabManager.currentTabId,
                  let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
            let newIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
            if newIndex >= 0 && newIndex < tabs.count {
                tabManager.selectTab(tabs[newIndex])
            }

        case .nextTab:
            guard let currentId = tabManager.currentTabId,
                  let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
            let newIndex = currentIndex < tabs.count - 1 ? currentIndex + 1 : 0
            if newIndex >= 0 && newIndex < tabs.count {
                tabManager.selectTab(tabs[newIndex])
            }

        case .focusURLBar:
            // Show command palette in navigate mode with current URL
            let recentTabs = tabs
                .filter { $0.id != tabManager.currentTabId }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(5)
            commandPaletteState.show(mode: .navigate, currentURL: tabManager.currentTabURL, recentTabs: Array(recentTabs))

        case .toggleSidebar:
            toggleDock()

        case .copyURL:
            if let url = tabManager.currentTabURL as String? {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }

        case .openSettings:
            tabManager.openSettings()

        case .zoomIn:
            guard let currentId = tabManager.currentTabId,
                  let state = browserStates[currentId] else { return }
            state.zoomIn()

        case .zoomOut:
            guard let currentId = tabManager.currentTabId,
                  let state = browserStates[currentId] else { return }
            state.zoomOut()

        case .resetZoom:
            guard let currentId = tabManager.currentTabId,
                  let state = browserStates[currentId] else { return }
            state.resetZoom()
        }
    }

    func handleCommandPaletteSubmit(_ suggestionType: SuggestionType) {
        // Capture mode before hiding (in case hide() is later modified to reset mode)
        let mode = commandPaletteState.mode
        commandPaletteState.hide(saveText: false)

        var urlToLoad: String

        switch suggestionType {
        case .searchSuggestion(let query):
            // Search Google
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            urlToLoad = "https://www.google.com/search?q=\(encoded)"

        case .directURL(let url):
            urlToLoad = url.lowercased().hasPrefix("http") ? url : "https://\(url)"

        case .dnsResolved(let hostname):
            // Single word that resolved via DNS (e.g., MagicDNS, intranet)
            urlToLoad = "http://\(hostname)"

        case .historyEntry(_, let url):
            urlToLoad = url

        case .recentTab(let tab):
            // Switch to tab instead
            tabManager.selectTab(tab)
            return
        }

        if mode == .newTab {
            // Create new tab with URL
            tabManager.createTab(url: urlToLoad, existingCount: tabs.count)
        } else {
            // Navigate current tab
            guard let currentId = tabManager.currentTabId,
                  let state = browserStates[currentId] else { return }
            state.loadURL(urlToLoad)
        }
    }

    private var backgroundLayers: some View {
        Group {
            Rectangle().fill(.thickMaterial).ignoresSafeArea()
            Rectangle().fill(Color(NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8))).ignoresSafeArea()
        }
    }

    private var sidebar: some View {
        SidebarView(
            tabs: tabs,
            isDocked: isDocked,
            isSidebarVisible: isDocked || isFloatingVisible,
            isSidebarFullyOpen: isSidebarFullyOpen,
            onToggle: toggleDock,
            onNewTab: { handleKeybindAction(.newTab) },
            draggedTab: $draggedTab,
            currentBrowserState: browserStates[tabManager.currentTabId ?? UUID()]
        )
        .frame(width: CGFloat(sidebarWidth))
        .background {
            let radius = CGFloat(isFullscreen ? fullscreenSidebarRadius : 13)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.thinMaterial)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)))
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
            .opacity(isDocked ? 0 : 1)
            .padding(isDocked ? 0 : 4)
            .animation(.sidebarSpring.delay(isDocked ? 0.2 : 0), value: isDocked)
            .animation(.sidebarSpring, value: isFullscreen)
        }
        .shadow(color: .black.opacity(isDocked ? 0 : 0.3), radius: 25, x: 5, y: 10)
        .offset(x: sidebarOffset)
        .allowsHitTesting(sidebarOffset == 0)
        .zIndex(20)
        .animation(.sidebarSpring, value: sidebarOffset)
    }

    @ViewBuilder
    private var resizeHandle: some View {
        if isDocked || isFloatingVisible {
            let handlePos = (isDocked ? CGFloat(sidebarWidth) : CGFloat(sidebarWidth) + 4) - 6

            ResizeHandleView(width: $sidebarWidth, dragStartWidth: $dragStartWidth, isResizing: $isResizing)
                .frame(width: 12)
                .frame(maxHeight: .infinity)
                .offset(x: max(0, handlePos))
                .zIndex(30)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: handlePos)
        }
    }

    func toggleDock() {
        let currentlyDocked = UserDefaults.standard.bool(forKey: "isDocked")

        if currentlyDocked {
            mouseTracker.shouldShowSidebar = true
        }

        isDocked = !currentlyDocked
    }

    func syncStates() {
        // Only create BrowserState for web tabs, not settings
        for tab in tabs where !tab.isSettings {
            if browserStates[tab.id] == nil {
                let initialURL = URL(string: tab.url)
                let s = BrowserState(
                    tabId: tab.id,
                    tabManager: tabManager,
                    initialURL: initialURL
                )
                browserStates[tab.id] = s
            }
        }
        let activeWebTabIds = tabs.filter { !$0.isSettings }.map { $0.id }
        for id in browserStates.keys { if !activeWebTabIds.contains(id) { browserStates.removeValue(forKey: id) } }
    }
}
