import AppKit
import WebKit

// MARK: - Settings

enum UserAgentChoice: String, CaseIterable {
    case dawn
    case chrome
    case firefox

    var title: String {
        switch self {
        case .dawn: return "Default (Safari)"
        case .chrome: return "Chrome on macOS"
        case .firefox: return "Firefox on macOS"
        }
    }

    var string: String {
        switch self {
        case .dawn:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"
        case .chrome:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
        case .firefox:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:145.0) Gecko/20100101 Firefox/145.0"
        }
    }
}

// the develop menu's app-wide toggles, persisted like safari's
enum DevelopSettings {
    private static let userAgentKey = "developUserAgent"
    private static let javaScriptKey = "developJavaScriptDisabled"

    static var userAgent: UserAgentChoice {
        get { UserDefaults.standard.string(forKey: userAgentKey).flatMap(UserAgentChoice.init(rawValue:)) ?? .dawn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: userAgentKey) }
    }

    static var javaScriptDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: javaScriptKey) }
        set { UserDefaults.standard.set(newValue, forKey: javaScriptKey) }
    }
}

// MARK: - Menu

// The parts of Safari's Develop menu that WebKit itself provides. Everything acts on the key window's
// current tab; app-wide toggles apply to every open tab.
final class DevelopMenu: NSObject, NSMenuItemValidation {
    private let currentState: () -> BrowserState?
    private let allStates: () -> [BrowserState]

    init(currentState: @escaping () -> BrowserState?, allStates: @escaping () -> [BrowserState]) {
        self.currentState = currentState
        self.allStates = allStates
    }

    func makeMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Develop")
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command, .option]) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = self
            menu.addItem(entry)
        }
        add("Show Web Inspector", #selector(showInspector), "i")
        add("Show JavaScript Console", #selector(showConsole), "c")
        add("Show Page Resources", #selector(showResources), "a")
        add("Start Element Selection", #selector(toggleElementSelection))
        add("Start Timeline Recording", #selector(toggleTimeline), "t", [.command, .option, .shift])
        menu.addItem(.separator())
        add("Empty Caches", #selector(emptyCaches), "e")
        add("Reload Page From Origin", #selector(reloadFromOrigin), "r")
        menu.addItem(.separator())
        add("Disable JavaScript", #selector(toggleJavaScript))

        let agents = NSMenu(title: "User Agent")
        for choice in UserAgentChoice.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(chooseUserAgent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            agents.addItem(entry)
        }
        let agentItem = NSMenuItem(title: "User Agent", action: nil, keyEquivalent: "")
        agentItem.submenu = agents
        menu.addItem(agentItem)

        let item = NSMenuItem(title: "Develop", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleJavaScript):
            menuItem.state = DevelopSettings.javaScriptDisabled ? .on : .off
            return true
        case #selector(chooseUserAgent(_:)):
            menuItem.state = (menuItem.representedObject as? String) == DevelopSettings.userAgent.rawValue ? .on : .off
            return true
        case #selector(emptyCaches):
            return true
        case #selector(showInspector):
            let visible = currentState()?.isWebInspectorVisible ?? false
            menuItem.title = visible ? "Hide Web Inspector" : "Show Web Inspector"
            return currentState() != nil
        case #selector(toggleElementSelection):
            let active = currentState()?.isElementSelectionActive ?? false
            menuItem.title = active ? "Stop Element Selection" : "Start Element Selection"
            return currentState() != nil
        case #selector(toggleTimeline):
            let recording = currentState()?.isTimelineRecording ?? false
            menuItem.title = recording ? "Stop Timeline Recording" : "Start Timeline Recording"
            return currentState() != nil
        default:
            return currentState() != nil
        }
    }

    @objc private func showInspector() { currentState()?.toggleWebInspector() }
    @objc private func showConsole() { currentState()?.performInspectorAction("showConsole") }
    @objc private func showResources() { currentState()?.performInspectorAction("showResources") }
    @objc private func toggleElementSelection() { currentState()?.performInspectorAction("toggleElementSelection") }
    @objc private func toggleTimeline() { currentState()?.performInspectorAction("togglePageProfiling") }
    @objc private func reloadFromOrigin() { currentState()?.webView.reloadFromOrigin() }

    @objc private func emptyCaches() {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {}
    }

    @objc private func toggleJavaScript() {
        DevelopSettings.javaScriptDisabled.toggle()
        // takes effect on the next navigation, so reload the page being looked at
        currentState()?.webView.reload()
    }

    @objc private func chooseUserAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = UserAgentChoice(rawValue: raw),
              choice != DevelopSettings.userAgent else { return }
        DevelopSettings.userAgent = choice
        for state in allStates() { state.webView.customUserAgent = choice.string }
        currentState()?.webView.reload()
    }
}
