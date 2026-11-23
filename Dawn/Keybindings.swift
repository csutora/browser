import AppKit
import Combine
import Carbon.HIToolbox

// MARK: - Special Key Display Names
let specialKeyNames: [UInt16: String] = [
    0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete",
    0x35: "Escape", 0x75: "Forward Delete",
    0x7B: "\u{2190}", 0x7C: "\u{2192}", 0x7D: "\u{2193}", 0x7E: "\u{2191}",
    0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
    0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
    0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
    0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
]

// MARK: - KeyCode to Character Translation
func characterForKeyCode(_ keyCode: UInt16) -> String? {
    guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
        return nil
    }

    let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
    let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var actualLength: Int = 0

    let status = UCKeyTranslate(
        keyboardLayout,
        keyCode,
        UInt16(kUCKeyActionDown),
        0,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        chars.count,
        &actualLength,
        &chars
    )

    guard status == noErr, actualLength > 0 else { return nil }
    return String(utf16CodeUnits: chars, count: actualLength)
}

// MARK: - Key Combo
struct KeyCombo: Codable, Identifiable {
    var id: String { "\(keyCode)-\(modifiers)" }

    let keyCode: UInt16
    let modifiers: UInt
    let fallbackCharacter: String?

    var hasCommand: Bool { modifiers & NSEvent.ModifierFlags.command.rawValue != 0 }
    var hasOption: Bool { modifiers & NSEvent.ModifierFlags.option.rawValue != 0 }
    var hasControl: Bool { modifiers & NSEvent.ModifierFlags.control.rawValue != 0 }
    var hasShift: Bool { modifiers & NSEvent.ModifierFlags.shift.rawValue != 0 }

    var isValidKeybind: Bool {
        let hasRealModifier = hasCommand || hasControl || hasOption
        let hasValidKey = keyCode != 0xFFFF
        return hasRealModifier && hasValidKey
    }

    var keyString: String {
        if let special = specialKeyNames[keyCode] {
            return special
        }
        if let char = characterForKeyCode(keyCode), !char.isEmpty {
            return char.uppercased()
        }
        if let char = fallbackCharacter, !char.isEmpty {
            return char.uppercased()
        }
        return "?"
    }

    var displayString: String {
        var parts: [String] = []
        if hasControl { parts.append("\u{2303}") }
        if hasOption { parts.append("\u{2325}") }
        if hasShift { parts.append("\u{21E7}") }
        if hasCommand { parts.append("\u{2318}") }
        parts.append(keyString)
        return parts.joined()
    }

    var searchableString: String {
        var parts: [String] = []
        if hasControl { parts.append("control ctrl") }
        if hasOption { parts.append("option opt alt") }
        if hasShift { parts.append("shift") }
        if hasCommand { parts.append("command cmd meta super win") }
        let baseKey = characterForKeyCode(keyCode)?.lowercased() ?? keyString.lowercased()
        parts.append(baseKey)
        return parts.joined(separator: " ")
    }

    init(keyCode: UInt16, modifiers: UInt, fallbackCharacter: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (
            NSEvent.ModifierFlags.command.rawValue |
            NSEvent.ModifierFlags.option.rawValue |
            NSEvent.ModifierFlags.control.rawValue |
            NSEvent.ModifierFlags.shift.rawValue
        )
        self.fallbackCharacter = fallbackCharacter
    }

    init(keyCode: UInt16, char: String? = nil, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        var mods: UInt = 0
        if command { mods |= NSEvent.ModifierFlags.command.rawValue }
        if option { mods |= NSEvent.ModifierFlags.option.rawValue }
        if control { mods |= NSEvent.ModifierFlags.control.rawValue }
        if shift { mods |= NSEvent.ModifierFlags.shift.rawValue }
        self.keyCode = keyCode
        self.modifiers = mods
        self.fallbackCharacter = char
    }

    static func from(event: NSEvent) -> KeyCombo? {
        guard event.type == .keyDown else { return nil }
        let fallback = event.charactersIgnoringModifiers
        return KeyCombo(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.rawValue,
            fallbackCharacter: fallback
        )
    }
}

extension KeyCombo: Equatable {
    static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
}

extension KeyCombo: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }
}

// MARK: - Keybind Action
enum KeybindAction: String, CaseIterable, Codable, Identifiable {
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case reopenClosedTab = "reopen_closed_tab"
    case refresh = "refresh"
    case goBack = "go_back"
    case goForward = "go_forward"
    case previousTab = "previous_tab"
    case nextTab = "next_tab"
    case focusURLBar = "focus_url_bar"
    case toggleSidebar = "toggle_sidebar"
    case copyURL = "copy_url"
    case openSettings = "open_settings"
    case zoomIn = "zoom_in"
    case zoomOut = "zoom_out"
    case resetZoom = "reset_zoom"
    case showDownloads = "show_downloads"
    case showWebInspector = "show_web_inspector"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .reopenClosedTab: return "Reopen Closed Tab"
        case .refresh: return "Refresh Page"
        case .goBack: return "Go Back"
        case .goForward: return "Go Forward"
        case .previousTab: return "Previous Tab"
        case .nextTab: return "Next Tab"
        case .focusURLBar: return "Focus URL Bar"
        case .toggleSidebar: return "Dock/Undock Sidebar"
        case .copyURL: return "Copy URL to Clipboard"
        case .openSettings: return "Open Settings"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .resetZoom: return "Reset Zoom"
        case .showDownloads: return "Show Downloads"
        case .showWebInspector: return "Show Web Inspector"
        }
    }

    var defaultKeyCombos: [KeyCombo] {
        switch self {
        case .newTab:
            return [KeyCombo(keyCode: 0x11, char: "t", command: true)]
        case .closeTab:
            return [KeyCombo(keyCode: 0x0D, char: "w", command: true)]
        case .reopenClosedTab:
            return [KeyCombo(keyCode: 0x11, char: "t", command: true, shift: true)]
        case .refresh:
            return [KeyCombo(keyCode: 0x0F, char: "r", command: true)]
        case .goBack:
            return [KeyCombo(keyCode: 0x21, char: "[", command: true)]
        case .goForward:
            return [KeyCombo(keyCode: 0x1E, char: "]", command: true)]
        case .previousTab:
            return [
                KeyCombo(keyCode: 0x21, char: "[", command: true, shift: true),
                KeyCombo(keyCode: 0x30, control: true, shift: true)
            ]
        case .nextTab:
            return [
                KeyCombo(keyCode: 0x1E, char: "]", command: true, shift: true),
                KeyCombo(keyCode: 0x30, control: true)
            ]
        case .focusURLBar:
            return [KeyCombo(keyCode: 0x25, char: "l", command: true)]
        case .toggleSidebar:
            return [KeyCombo(keyCode: 0x01, char: "s", command: true, shift: true)]
        case .copyURL:
            return [KeyCombo(keyCode: 0x08, char: "c", command: true, shift: true)]
        case .openSettings:
            return [KeyCombo(keyCode: 0x2B, char: ",", command: true)]
        case .zoomIn:
            return [KeyCombo(keyCode: 0x18, char: "=", command: true)]
        case .zoomOut:
            return [KeyCombo(keyCode: 0x1B, char: "-", command: true)]
        case .resetZoom:
            return [KeyCombo(keyCode: 0x1D, char: "0", command: true)]
        case .showDownloads:
            return [KeyCombo(keyCode: 0x25, char: "l", command: true, option: true)]
        case .showWebInspector:
            return [KeyCombo(keyCode: 0x22, char: "i", command: true, option: true)]
        }
    }
}

// MARK: - Keybindings Storage
struct KeybindingsData: Codable {
    var bindings: [String: [KeyCombo]]

    init() {
        bindings = [:]
        for action in KeybindAction.allCases {
            bindings[action.rawValue] = action.defaultKeyCombos
        }
    }
}

// MARK: - Keybindings Manager
class KeybindingsManager: ObservableObject {
    static let shared = KeybindingsManager()

    @Published var data: KeybindingsData {
        didSet { save() }
    }
    @Published var isEditing: Bool = false

    private let storageKey = "keybindings_data"

    init() {
        if let savedData = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(KeybindingsData.self, from: savedData) {
            self.data = decoded
        } else {
            self.data = KeybindingsData()
        }
    }

    func matchingAction(for event: NSEvent) -> KeybindAction? {
        let eventKeyCode = event.keyCode
        let eventMods = event.modifierFlags.rawValue & (
            NSEvent.ModifierFlags.command.rawValue |
            NSEvent.ModifierFlags.option.rawValue |
            NSEvent.ModifierFlags.control.rawValue |
            NSEvent.ModifierFlags.shift.rawValue
        )

        for action in KeybindAction.allCases {
            for combo in combos(for: action) {
                if combo.keyCode == eventKeyCode && combo.modifiers == eventMods {
                    return action
                }
            }
        }
        return nil
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    func combos(for action: KeybindAction) -> [KeyCombo] {
        data.bindings[action.rawValue] ?? action.defaultKeyCombos
    }

    func setCombos(_ combos: [KeyCombo], for action: KeybindAction) {
        data.bindings[action.rawValue] = combos
    }

    func addCombo(_ combo: KeyCombo, to action: KeybindAction) {
        var current = combos(for: action)
        if !current.contains(combo) {
            current.append(combo)
            setCombos(current, for: action)
        }
    }

    func removeCombo(_ combo: KeyCombo, from action: KeybindAction) {
        var current = combos(for: action)
        current.removeAll { $0 == combo }
        if current.isEmpty {
            current = action.defaultKeyCombos
        }
        setCombos(current, for: action)
    }

    func resetToDefault(for action: KeybindAction) {
        data.bindings[action.rawValue] = action.defaultKeyCombos
    }

    func resetAllToDefaults() {
        data = KeybindingsData()
    }

    func isDefault(for action: KeybindAction) -> Bool {
        combos(for: action) == action.defaultKeyCombos
    }

    func findConflict(for combo: KeyCombo, excluding action: KeybindAction, excludingIndex: Int? = nil) -> KeybindAction? {
        for otherAction in KeybindAction.allCases {
            let otherCombos = combos(for: otherAction)
            for (index, existingCombo) in otherCombos.enumerated() {
                if existingCombo == combo {
                    if otherAction == action {
                        if let excludeIdx = excludingIndex, excludeIdx == index {
                            continue
                        }
                        return action
                    }
                    return otherAction
                }
            }
        }
        return nil
    }

    func action(for combo: KeyCombo) -> KeybindAction? {
        for action in KeybindAction.allCases {
            if combos(for: action).contains(combo) {
                return action
            }
        }
        return nil
    }
}

// MARK: - Keybind Handler
class KeybindHandler {
    static let shared = KeybindHandler()

    private var eventMonitor: Any?
    private let manager = KeybindingsManager.shared

    var onAction: ((KeybindAction) -> Void)?

    func start() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if self.manager.isEditing {
                return event
            }

            if let action = self.manager.matchingAction(for: event) {
                self.onAction?(action)
                return nil
            }

            return event
        }
    }

    func stop() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Key Recorder View

class KeyRecorderView: NSView {
    var onComboRecorded: ((KeyCombo) -> Void)?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?

    private var currentModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let combo = KeyCombo.from(event: event) else { return }
        onComboRecorded?(combo)
    }

    override func flagsChanged(with event: NSEvent) {
        currentModifiers = event.modifierFlags
        onModifiersChanged?(event.modifierFlags)
    }

    override func resignFirstResponder() -> Bool {
        return super.resignFirstResponder()
    }
}

// MARK: - Search Parsing
struct KeybindSearchParser {
    static func matches(action: KeybindAction, combos: [KeyCombo], query: String) -> Bool {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }

        if action.displayName.lowercased().contains(query) {
            return true
        }

        let normalizedQuery = normalizeQuery(query)

        for combo in combos {
            if combo.searchableString.contains(normalizedQuery) {
                return true
            }
            if matchesComboQuery(combo: combo, query: query) {
                return true
            }
        }

        return false
    }

    private static func normalizeQuery(_ query: String) -> String {
        var result = query.lowercased()

        let modifierAliases: [(String, String)] = [
            ("command", "cmd"), ("meta", "cmd"), ("super", "cmd"), ("win", "cmd"), ("\u{2318}", "cmd"),
            ("option", "opt"), ("alt", "opt"), ("\u{2325}", "opt"),
            ("control", "ctrl"), ("\u{2303}", "ctrl"),
            ("\u{21E7}", "shift"),
        ]

        for (alias, normalized) in modifierAliases {
            result = result.replacingOccurrences(of: alias, with: normalized)
        }

        return result
    }

    private static func matchesComboQuery(combo: KeyCombo, query: String) -> Bool {
        let parts = query
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return false }

        var hasCmd = false, hasOpt = false, hasCtrl = false, hasShift = false
        var keyPart: String?

        for part in parts {
            switch part {
            case "cmd", "command", "meta", "super", "win", "\u{2318}":
                hasCmd = true
            case "opt", "option", "alt", "\u{2325}":
                hasOpt = true
            case "ctrl", "control", "\u{2303}":
                hasCtrl = true
            case "shift", "\u{21E7}":
                hasShift = true
            default:
                keyPart = part
            }
        }

        if hasCmd && !combo.hasCommand { return false }
        if hasOpt && !combo.hasOption { return false }
        if hasCtrl && !combo.hasControl { return false }
        if hasShift && !combo.hasShift { return false }

        if let key = keyPart {
            let comboKey = combo.keyString.lowercased()
            if comboKey != key {
                let keyAliases: [String: [String]] = [
                    "return": ["enter", "ret"],
                    "escape": ["esc"],
                    "delete": ["backspace", "del"],
                    "forward delete": ["del", "delete"],
                    "space": ["spc"],
                    "\u{2190}": ["left"],
                    "\u{2192}": ["right"],
                    "\u{2191}": ["up"],
                    "\u{2193}": ["down"],
                ]

                let aliases = keyAliases[comboKey] ?? []
                if !aliases.contains(key) && comboKey != key {
                    return false
                }
            }
        }

        return true
    }
}
