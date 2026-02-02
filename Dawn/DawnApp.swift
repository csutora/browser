import SwiftUI
import SwiftData

@main
struct BrowserApp: App {
    @StateObject var tabManager = TabManager()
    @StateObject var historyManager = HistoryManager()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: Tab.self, HistoryEntry.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabManager)
                .environmentObject(historyManager)
                .onAppear {
                    // Set modelContext on managers
                    tabManager.modelContext = modelContainer.mainContext
                    historyManager.modelContext = modelContainer.mainContext

                    if let window = NSApplication.shared.windows.first {
                        window.titleVisibility = .hidden
                        window.titlebarAppearsTransparent = true
                        window.styleMask.insert(.fullSizeContentView)
                        window.standardWindowButton(.closeButton)?.isHidden = true
                        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                        window.standardWindowButton(.zoomButton)?.isHidden = true
                        window.isOpaque = false
                        window.backgroundColor = .clear
                        window.hasShadow = true
                        window.isMovableByWindowBackground = true
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // Settings menu item (keybind handled by KeybindHandler)
            CommandGroup(after: .appInfo) {
                Button("Settings...") {
                    if tabManager.modelContext == nil {
                        tabManager.modelContext = modelContainer.mainContext
                    }
                    tabManager.openSettings()
                }
            }
        }
        .modelContainer(modelContainer)
    }
}
