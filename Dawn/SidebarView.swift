import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sidebar Background Helper
struct SidebarBackgroundHelper: NSViewRepresentable {
    func makeNSView(context: Context) -> HelperView { return HelperView() }
    func updateNSView(_ nsView: HelperView, context: Context) {}

    class HelperView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                self.window?.zoom(nil)
            } else {
                self.window?.performDrag(with: event)
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit == self ? self : hit
        }
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    @EnvironmentObject var tabManager: TabManager
    var tabs: [Tab]
    var isDocked: Bool
    var isSidebarVisible: Bool
    var isSidebarFullyOpen: Bool
    var onToggle: () -> Void
    var onNewTab: () -> Void
    @Binding var draggedTab: Tab?
    var currentBrowserState: BrowserState?
    @State private var urlText = ""
    @FocusState private var isUrlFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    TrafficLightsView(isDocked: isDocked, isSidebarFullyOpen: isSidebarFullyOpen)
                    Button(action: onToggle) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 4) {
                    NavButton(icon: "chevron.left", action: { currentBrowserState?.goBack() }, disabled: !(currentBrowserState?.canGoBack ?? false))
                    NavButton(icon: "chevron.right", action: { currentBrowserState?.goForward() }, disabled: !(currentBrowserState?.canGoForward ?? false))
                    let isLoading = currentBrowserState?.isLoading ?? false
                    NavButton(
                        icon: isLoading ? "xmark" : "arrow.clockwise",
                        action: { if isLoading { currentBrowserState?.stopLoading() } else { currentBrowserState?.reload() } },
                        disabled: false
                    )
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 12)
            .background(SidebarBackgroundHelper())

            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .leading)
                TextField("Search", text: $urlText)
                      .textFieldStyle(.plain).font(.system(size: 13))
                      .foregroundColor(.white).tint(.white)
                      .focused($isUrlFieldFocused)
                      .onSubmit {
                          // Handle dawn:// URLs
                          if urlText.lowercased() == "dawn://settings" {
                              tabManager.openSettings()
                          } else {
                              currentBrowserState?.loadURL(urlText)
                          }
                          isUrlFieldFocused = false
                      }
            }
            .padding(10).background(Color(NSColor(white: 0.5, alpha: 0.2)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(isUrlFieldFocused ? 0.5 : 0.05), lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 10)

            Divider().opacity(0.3)

            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 2) {
                        Color.clear.frame(height: 1)
                        ForEach(tabs) { tab in
                            SidebarTabItem(tab: tab, tabManager: tabManager, draggedTab: $draggedTab, focusBinding: $isUrlFieldFocused, allTabs: tabs)
                                .transition(.opacity)
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: tabs)
                    .padding(10).frame(minHeight: geo.size.height, alignment: .top)
                    .onTapGesture { isUrlFieldFocused = false }
                    .background(SidebarBackgroundHelper())
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button(action: onNewTab) { Label("New Tab", systemImage: "plus").font(.system(size: 12)).foregroundColor(.secondary) }.buttonStyle(.plain)
                Spacer()
            }.padding(16).background(SidebarBackgroundHelper())
        }
        .onAppear { urlText = tabManager.currentTabURL }
        .onChange(of: tabManager.currentTabURL) { _, val in urlText = val }
        .onTapGesture { isUrlFieldFocused = false }
        .background(SidebarBackgroundHelper())
        .onReceive(NotificationCenter.default.publisher(for: .focusURLBar)) { _ in
            isUrlFieldFocused = true
        }
    }
}

// MARK: - Sidebar Tab Item
struct SidebarTabItem: View {
    let tab: Tab
    @ObservedObject var tabManager: TabManager
    @Binding var draggedTab: Tab?
    var focusBinding: FocusState<Bool>.Binding
    var allTabs: [Tab]

    var body: some View {
        DraggableTab(tab: tab, draggedTab: $draggedTab) {
            TabRow(tab: tab, isSelected: tabManager.currentTabId == tab.id, isDragging: draggedTab?.id == tab.id) {
                tabManager.selectTab(tab)
                focusBinding.wrappedValue = false
            } onClose: {
                tabManager.closeTab(tab, allTabs: allTabs)
            }
        }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(tab: tab, tabs: allTabs, draggedTab: $draggedTab))
    }
}

// MARK: - Tab Row
struct TabRow: View {
    let tab: Tab
    let isSelected: Bool
    let isDragging: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var h = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if tab.isSettings {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .offset(y: -0.5)
                } else {
                    // Placeholder for favicon (will be implemented later)
                    Circle().fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: 16, height: 16)

            Text(tab.title.isEmpty ? "Untitled" : tab.title).font(.system(size: 13)).foregroundColor(isSelected ? .primary : .secondary).lineLimit(1)
            Spacer()
            if h || isSelected {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
            }
        }
        .padding(8).background(isSelected ? Color.primary.opacity(0.1) : (h ? Color.primary.opacity(0.05) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).contentShape(Rectangle())
        .onTapGesture(perform: onSelect).onHover { h = $0 }.opacity(isDragging ? 0.5 : 1)
    }
}
