import SwiftUI
import SwiftData

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

    var isFloatingVisible: Bool {
        if isDocked { return false }
        if isResizing { return true }
        return mouseTracker.shouldShowSidebar
    }

    var sidebarOffset: CGFloat {
        isDocked ? 0 : (isFloatingVisible ? 0 : -(CGFloat(sidebarWidth) + 50))
    }

    var webLeftPadding: CGFloat {
        isDocked ? CGFloat(sidebarWidth) - 8 : 0
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
                webLeftPadding: webLeftPadding
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
        }
        .onChange(of: sidebarWidth) { _, newValue in
            mouseTracker.updateSettings(sidebarWidth: newValue, isDocked: isDocked)
        }
        .onChange(of: isDocked) { _, newValue in
            mouseTracker.updateSettings(sidebarWidth: sidebarWidth, isDocked: newValue)
        }
        .onChange(of: tabs) { _, _ in syncStates() }
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
        if isDocked {
            // Set visibility BEFORE undocking to prevent isSidebarVisible flicker
            mouseTracker.shouldShowSidebar = true
        }
        isDocked.toggle()
    }

    func syncStates() {
        // Only create BrowserState for web tabs, not settings
        for tab in tabs where !tab.isSettings {
            if browserStates[tab.id] == nil {
                let s = BrowserState(
                    tabId: tab.id,
                    tabManager: tabManager,
                    restorationData: tab.interactionState,
                    scroll: CGPoint(x: tab.scrollX, y: tab.scrollY),
                    zoom: tab.zoomScale
                )
                browserStates[tab.id] = s
                if s.restorationData == nil && s.pendingURL == nil { s.loadURL(tab.url) }
            }
        }
        let activeWebTabIds = tabs.filter { !$0.isSettings }.map { $0.id }
        for id in browserStates.keys { if !activeWebTabIds.contains(id) { browserStates.removeValue(forKey: id) } }
    }
}
