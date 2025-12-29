import SwiftUI
import SwiftData

@main
struct BrowserApp: App {
    @StateObject var tabManager = TabManager()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: Tab.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabManager)
                .onAppear {
                    // Set modelContext on tabManager
                    tabManager.modelContext = modelContainer.mainContext

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

            // Settings command (Cmd+,)
            CommandGroup(after: .appInfo) {
                Button("Settings...") {
                    // Ensure modelContext is set before opening settings
                    if tabManager.modelContext == nil {
                        tabManager.modelContext = modelContainer.mainContext
                    }
                    tabManager.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .modelContainer(modelContainer)
    }
}
