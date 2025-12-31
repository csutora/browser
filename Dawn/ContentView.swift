import SwiftUI
import SwiftData

extension Notification.Name {
    static let focusURLBar = Notification.Name("focusURLBar")
}

struct ContentView: View {
    @EnvironmentObject var tabManager: TabManager

    @Query(sort: \Tab.sortIndex, animation: .spring(response: 0.35, dampingFraction: 0.75)) private var tabs: [Tab]

    @StateObject private var mouseTracker = MouseTracker()
    @State private var browserStates: [UUID: BrowserState] = [:]

    @AppStorage("isDocked") private var isDocked: Bool = true
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260.0

    @State private var dragStartWidth: Double? = nil
    @State private var isResizing: Bool = false
    @State private var draggedTab: Tab?
    @State private var useDockAnimation: Bool = false

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
                sidebarWidth: CGFloat(sidebarWidth)
            )

            sidebar

            resizeHandle
        }
        .ignoresSafeArea()
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
    }

    func setupKeybindHandler() {
        keybindHandler.onAction = { [self] action in
            handleKeybindAction(action)
        }
        keybindHandler.start()
    }

    func handleKeybindAction(_ action: KeybindAction) {
        switch action {
        case .newTab:
            tabManager.createTab(existingCount: tabs.count)

        case .closeTab:
            guard let currentId = tabManager.currentTabId,
                  let tab = tabs.first(where: { $0.id == currentId }) else { return }
            tabManager.closeTab(tab, allTabs: tabs)

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
            NotificationCenter.default.post(name: .focusURLBar, object: nil)

        case .toggleSidebar:
            toggleDock()

        case .copyURL:
            if let url = tabManager.currentTabURL as String? {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }

        case .openSettings:
            tabManager.openSettings()
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
            onToggle: toggleDock,
            draggedTab: $draggedTab,
            currentBrowserState: browserStates[tabManager.currentTabId ?? UUID()]
        )
        .frame(width: CGFloat(sidebarWidth))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)))
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
            .opacity(isDocked ? 0 : 1)
            .padding(isDocked ? 0 : 4)
            .animation(.sidebarSpring.delay(isDocked ? 0.2 : 0), value: isDocked)
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
