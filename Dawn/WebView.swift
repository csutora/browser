import SwiftUI
import WebKit

// MARK: - Settings Path Helper
func extractSettingsPath(from url: String) -> String {
    // Parse dawn://settings or dawn://keybinds etc.
    guard url.hasPrefix("dawn://") else { return "settings" }
    let path = String(url.dropFirst("dawn://".count))
    return path.isEmpty ? "settings" : path
}

// MARK: - Web View Container
struct WebViewContainer: View {
    var tabs: [Tab]
    var browserStates: [UUID: BrowserState]
    var currentTabId: UUID?
    var isDocked: Bool
    var isFullscreen: Bool = false
    var sidebarWidth: CGFloat
    var onSettingsNavigate: ((String) -> Void)?

    private let defaultColor = Color(NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))

    // In fullscreen with floating sidebar, no border; otherwise use padding
    private var shouldHaveBorder: Bool {
        !(isFullscreen && !isDocked)
    }

    @State private var displayedBackgroundColor: Color = Color(NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0))
    @State private var showStroke: Bool = true
    @State private var strokeWorkItem: DispatchWorkItem?

    // Get cached color from Tab (returns nil if no cached color)
    private func cachedBackgroundColor(for tabId: UUID?) -> Color? {
        guard let id = tabId,
              let tab = tabs.first(where: { $0.id == id }),
              !tab.isSettings else {
            return nil
        }
        return tab.backgroundColor
    }

    // Check if current tab is settings
    private var currentTabIsSettings: Bool {
        guard let currentId = currentTabId,
              let currentTab = tabs.first(where: { $0.id == currentId }) else {
            return false
        }
        return currentTab.isSettings
    }

    // Get settings path for current tab
    private var currentSettingsPath: String {
        guard let currentId = currentTabId,
              let currentTab = tabs.first(where: { $0.id == currentId }),
              currentTab.isSettings else {
            return "settings"
        }
        return extractSettingsPath(from: currentTab.url)
    }

    var body: some View {
        GeometryReader { geo in
            let padding: CGFloat = shouldHaveBorder ? 8 : 0
            let leadingPadding = isDocked ? sidebarWidth : padding
            let frame = CGRect(
                x: leadingPadding,
                y: padding,
                width: max(0, geo.size.width - leadingPadding - padding),
                height: max(0, geo.size.height - padding * 2)
            )
            let cornerRadius: CGFloat = shouldHaveBorder ? 9 : 0

            ZStack {
                // Background - uses cached/fetched color
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(displayedBackgroundColor)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)

                // Keep all web views alive, control visibility with NSView.isHidden
                ForEach(tabs.filter { !$0.isSettings }) { tab in
                    if let state = browserStates[tab.id] {
                        let isActive = tab.id == currentTabId
                        WebPageView(
                            browserState: state,
                            isVisible: isActive,
                            onBackgroundColorChange: { color in
                                if isActive {
                                    displayedBackgroundColor = color
                                }
                            }
                        )
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .position(x: frame.midX, y: frame.midY)
                    }
                }

                // Settings view - kept alive, visibility controlled
                SettingsViewWrapper(
                    isVisible: currentTabIsSettings,
                    settingsPath: currentSettingsPath,
                    onNavigate: { path in onSettingsNavigate?(path) }
                )
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .position(x: frame.midX, y: frame.midY)

                // Opaque stroke to cover anti-aliased corner bleeding (delayed appearance)
                RoundedRectangle(cornerRadius: cornerRadius + 1)
                    .stroke(defaultColor, lineWidth: 2)
                    .frame(width: frame.width + 1, height: frame.height + 1)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(showStroke ? 1 : 0)
                    .animation(.easeIn(duration: 0.15), value: showStroke)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .animation(.sidebarSpring, value: isDocked)
        .animation(.sidebarSpring, value: isFullscreen)
        .onChange(of: shouldHaveBorder) { _, newValue in
            if newValue {
                // Delay showing stroke until animation completes
                strokeWorkItem?.cancel()
                let workItem = DispatchWorkItem {
                    showStroke = true
                }
                strokeWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
            } else {
                // Hide stroke immediately
                strokeWorkItem?.cancel()
                strokeWorkItem = nil
                showStroke = false
            }
        }
        .onChange(of: currentTabId) { _, newId in
            if let newId = newId, let cached = cachedBackgroundColor(for: newId) {
                displayedBackgroundColor = cached
            } else if newId == nil {
                displayedBackgroundColor = defaultColor
            }
        }
        .onAppear {
            if let cached = cachedBackgroundColor(for: currentTabId) {
                displayedBackgroundColor = cached
            }
        }
    }
}

// MARK: - Settings View Wrapper (kept alive, visibility controlled)
struct SettingsViewWrapper: NSViewRepresentable {
    let isVisible: Bool
    let settingsPath: String
    let onNavigate: (String) -> Void

    func makeNSView(context: Context) -> NSHostingView<SettingsView> {
        let navState = SettingsNavigationState()
        navState.currentPath = settingsPath
        navState.onNavigate = onNavigate
        context.coordinator.navigationState = navState

        let view = NSHostingView(rootView: SettingsView(navigationState: navState))
        view.safeAreaRegions = []
        view.layer?.cornerRadius = 9
        view.layer?.masksToBounds = true
        view.isHidden = !isVisible
        return view
    }

    func updateNSView(_ nsView: NSHostingView<SettingsView>, context: Context) {
        nsView.isHidden = !isVisible

        if let navState = context.coordinator.navigationState {
            if isVisible && navState.currentPath != settingsPath {
                navState.currentPath = settingsPath
            }
            navState.onNavigate = onNavigate
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var navigationState: SettingsNavigationState?
    }
}

// MARK: - WebPage View (native SwiftUI WebView)
struct WebPageView: View {
    @ObservedObject var browserState: BrowserState
    var isVisible: Bool = true
    var onBackgroundColorChange: ((Color) -> Void)?

    var body: some View {
        HiddenControlView(isVisible: isVisible) {
            WebView(browserState.webPage)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewContentBackground(.hidden)
        }
        .task(id: browserState.tabId) {
            browserState.loadInitialContentIfNeeded()
        }
        .onChange(of: browserState.fetchedBackgroundColor) { _, newColor in
            if let color = newColor {
                onBackgroundColorChange?(color)
            }
        }
        .onChange(of: browserState.webPage.url) { _, newURL in
            browserState.handleURLChange(newURL)
        }
        .onChange(of: browserState.webPage.title) { _, newTitle in
            browserState.handleTitleChange(newTitle)
        }
        .onChange(of: browserState.webPage.isLoading) { _, isLoading in
            browserState.handleLoadingChange(isLoading)
        }
    }
}

// MARK: - Hidden Control View (sets NSView.isHidden)
struct HiddenControlView<Content: View>: NSViewRepresentable {
    let isVisible: Bool
    @ViewBuilder let content: Content

    init(isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: content)
        hostingView.safeAreaRegions = []
        hostingView.isHidden = !isVisible
        return hostingView
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.isHidden = !isVisible
    }
}
