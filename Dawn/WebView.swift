import SwiftUI
import WebKit

// MARK: - Web View Container
struct WebViewContainer: View {
    var tabs: [Tab]
    var browserStates: [UUID: BrowserState]
    var currentTabId: UUID?
    var isDocked: Bool
    var sidebarWidth: CGFloat

    private let defaultColor = Color(NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))

    @State private var displayedBackgroundColor: Color = Color(NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0))

    // Get cached color from Tab (returns nil if no cached color)
    private func cachedBackgroundColor(for tabId: UUID?) -> Color? {
        guard let id = tabId,
              let tab = tabs.first(where: { $0.id == id }),
              !tab.isSettings else {
            return nil
        }
        return tab.backgroundColor
    }

    var body: some View {
        GeometryReader { geo in
            let leadingPadding = isDocked ? sidebarWidth : 8
            let frame = CGRect(
                x: leadingPadding,
                y: 8,
                width: max(0, geo.size.width - leadingPadding - 8),
                height: max(0, geo.size.height - 16)
            )

            ZStack {
                // Background - uses cached/fetched color
                RoundedRectangle(cornerRadius: 9)
                    .fill(displayedBackgroundColor)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)

                // Content
                if let currentId = currentTabId,
                   let currentTab = tabs.first(where: { $0.id == currentId }) {
                    if currentTab.isSettings {
                        SettingsViewContainer()
                            .frame(width: frame.width, height: frame.height)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .position(x: frame.midX, y: frame.midY)
                    } else if let state = browserStates[currentId] {
                        WebPageView(browserState: state, onBackgroundColorChange: { color in
                            displayedBackgroundColor = color
                        })
                            .frame(width: frame.width, height: frame.height)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .position(x: frame.midX, y: frame.midY)
                    }
                }

                // Opaque stroke to cover anti-aliased corner bleeding
                RoundedRectangle(cornerRadius: 10)
                    .stroke(defaultColor, lineWidth: 2)
                    .frame(width: frame.width + 1, height: frame.height + 1)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .animation(.sidebarSpring, value: isDocked)
        .onChange(of: currentTabId) { _, newId in
            // Only update if new tab has a cached color, otherwise keep previous
            if let cached = cachedBackgroundColor(for: newId) {
                displayedBackgroundColor = cached
            }
        }
        .onAppear {
            if let cached = cachedBackgroundColor(for: currentTabId) {
                displayedBackgroundColor = cached
            }
        }
    }
}

// MARK: - Settings View Container (prevents window dragging)
struct SettingsViewContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSHostingView<SettingsView> {
        let view = NonDraggableHostingView(rootView: SettingsView())
        view.layer?.cornerRadius = 9
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSHostingView<SettingsView>, context: Context) {}
}

// Helper to prevent window dragging from settings content
private class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - WebPage View (native SwiftUI WebView)
struct WebPageView: View {
    @ObservedObject var browserState: BrowserState
    var onBackgroundColorChange: ((Color) -> Void)?

    var body: some View {
        WebView(browserState.webPage)
            .webViewBackForwardNavigationGestures(.enabled)
            .webViewContentBackground(.hidden)
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
