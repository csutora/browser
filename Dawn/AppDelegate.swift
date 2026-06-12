import AppKit
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController!
    var modelContainer: ModelContainer!
    let tabManager = TabManager()
    let historyManager = HistoryManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "isDocked": true,
            "sidebarWidth": 260.0,
            "fullscreenSidebarRadius": 13,
            "includeSearchSuggestions": true,
            "includeHistorySuggestions": true
        ])

        do {
            modelContainer = try ModelContainer(for: Tab.self, HistoryEntry.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        tabManager.modelContext = modelContainer.mainContext
        historyManager.modelContext = modelContainer.mainContext

        mainWindowController = MainWindowController(
            tabManager: tabManager,
            historyManager: historyManager,
            modelContext: modelContainer.mainContext
        )
        mainWindowController.showWindow(nil)

        setupMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save interaction state for all open tabs
        for (tabId, state) in mainWindowController.browserStates {
            if let data = state.captureInteractionState() {
                let tabs = tabManager.fetchTabs()
                if let tab = tabs.first(where: { $0.id == tabId }) {
                    tab.interactionState = data
                }
            }
        }
        tabManager.saveNow()
    }

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

    @objc private func openSettings() {
        tabManager.openSettings()
    }

    @objc private func reloadPage() {
        mainWindowController.handleKeybindAction(.refresh)
    }

    @objc private func zoomIn() {
        mainWindowController.handleKeybindAction(.zoomIn)
    }

    @objc private func zoomOut() {
        mainWindowController.handleKeybindAction(.zoomOut)
    }

    @objc private func resetZoom() {
        mainWindowController.handleKeybindAction(.resetZoom)
    }
}
