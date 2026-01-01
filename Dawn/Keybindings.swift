import SwiftUI
import Combine
import Carbon.HIToolbox

// MARK: - Special Key Display Names
/// Keys that need custom display names (can't just use the character they produce)
let specialKeyNames: [UInt16: String] = [
    0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete",
    0x35: "Escape", 0x75: "Forward Delete",
    0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
    0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
    0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
    0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
]

// MARK: - KeyCode to Character Translation
/// Translates a keyCode to its base character (without modifiers) using the current keyboard layout
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
        0, // No modifiers - get the base character
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
    let modifiers: UInt // NSEvent.ModifierFlags.rawValue
    let fallbackCharacter: String? // For keys not in the keyCode map

    var hasCommand: Bool { modifiers & NSEvent.ModifierFlags.command.rawValue != 0 }
    var hasOption: Bool { modifiers & NSEvent.ModifierFlags.option.rawValue != 0 }
    var hasControl: Bool { modifiers & NSEvent.ModifierFlags.control.rawValue != 0 }
    var hasShift: Bool { modifiers & NSEvent.ModifierFlags.shift.rawValue != 0 }

    /// Returns true if this is a valid keybind (requires Cmd, Ctrl, or Option - not just Shift)
    var isValidKeybind: Bool {
        // Must have at least one "real" modifier (not just shift)
        let hasRealModifier = hasCommand || hasControl || hasOption
        // Must have a valid key (not just modifiers)
        let hasValidKey = keyCode != 0xFFFF
        return hasRealModifier && hasValidKey
    }

    var keyString: String {
        // Special keys have custom display names
        if let special = specialKeyNames[keyCode] {
            return special
        }
        // Regular keys: translate keyCode to base character using current keyboard layout
        if let char = characterForKeyCode(keyCode), !char.isEmpty {
            return char.uppercased()
        }
        // Fallback to stored character if translation fails
        if let char = fallbackCharacter, !char.isEmpty {
            return char.uppercased()
        }
        return "?"
    }

    var displayString: String {
        var parts: [String] = []
        if hasControl { parts.append("⌃") }
        if hasOption { parts.append("⌥") }
        if hasShift { parts.append("⇧") }
        if hasCommand { parts.append("⌘") }
        parts.append(keyString)
        return parts.joined()
    }

    var searchableString: String {
        var parts: [String] = []
        if hasControl { parts.append("control ctrl") }
        if hasOption { parts.append("option opt alt") }
        if hasShift { parts.append("shift") }
        if hasCommand { parts.append("command cmd meta super win") }
        // Use base character from keyCode for searching
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
        // Use charactersIgnoringModifiers to get the base key regardless of shift state
        let fallback = event.charactersIgnoringModifiers
        return KeyCombo(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.rawValue,
            fallbackCharacter: fallback
        )
    }
}

// Custom Equatable/Hashable - only compare keyCode and modifiers (ignore fallbackCharacter)
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
                KeyCombo(keyCode: 0x30, control: true, shift: true) // Tab - special key
            ]
        case .nextTab:
            return [
                KeyCombo(keyCode: 0x1E, char: "]", command: true, shift: true),
                KeyCombo(keyCode: 0x30, control: true) // Tab - special key
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
            return [KeyCombo(keyCode: 0x18, char: "=", command: true)] // = key (same as + without shift)
        case .zoomOut:
            return [KeyCombo(keyCode: 0x1B, char: "-", command: true)]
        case .resetZoom:
            return [KeyCombo(keyCode: 0x1D, char: "0", command: true)]
        }
    }
}

// MARK: - Keybindings Storage
struct KeybindingsData: Codable {
    var bindings: [String: [KeyCombo]] // action rawValue -> combos

    init() {
        bindings = [:]
        // Initialize with defaults
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
                    // If it's the same action, only conflict if it's a different index (duplicate within same action)
                    if otherAction == action {
                        if let excludeIdx = excludingIndex, excludeIdx == index {
                            continue // Skip the combo we're editing
                        }
                        return action // Duplicate within same action
                    }
                    return otherAction // Conflict with different action
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

            // If editing keybinds, let events through for KeyRecorderView to capture
            if self.manager.isEditing {
                return event
            }

            // Check if this matches a keybind
            if let action = self.manager.matchingAction(for: event) {
                self.onAction?(action)
                return nil // Consume the event
            }

            return event // Let unmatched events through
        }
    }

    func stop() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Key Cap View
struct KeyCapView: View {
    let text: String
    let isSymbol: Bool
    var isPressed: Bool = false
    var isError: Bool = false

    private let fixedHeight: CGFloat = 24
    private let minWidth: CGFloat = 24

    init(_ text: String, isSymbol: Bool = false, isPressed: Bool = false, isError: Bool = false) {
        self.text = text
        self.isSymbol = isSymbol
        self.isPressed = isPressed
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.system(size: isSymbol ? 14 : 12, weight: .medium, design: .rounded))
            .foregroundColor(isError ? .red : .primary)
            .frame(minWidth: minWidth, minHeight: fixedHeight, alignment: .center)
            .padding(.horizontal, isSymbol ? 0 : 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isPressed ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isError ? Color.red.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

// MARK: - Key Combo Display View
struct KeyComboView: View {
    let combo: KeyCombo
    var isPressed: Bool = false
    var isError: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if combo.hasControl {
                KeyCapView("⌃", isSymbol: true, isPressed: isPressed, isError: isError)
            }
            if combo.hasOption {
                KeyCapView("⌥", isSymbol: true, isPressed: isPressed, isError: isError)
            }
            if combo.hasShift {
                KeyCapView("⇧", isSymbol: true, isPressed: isPressed, isError: isError)
            }
            if combo.hasCommand {
                KeyCapView("⌘", isSymbol: true, isPressed: isPressed, isError: isError)
            }
            KeyCapView(combo.keyString, isPressed: isPressed, isError: isError)
        }
    }
}

// MARK: - Live Key Combo Editor
struct KeyComboEditor: NSViewRepresentable {
    @Binding var currentCombo: KeyCombo?
    @Binding var isRecording: Bool
    let onComboRecorded: (KeyCombo) -> Void

    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView()
        view.onComboRecorded = onComboRecorded
        view.isRecordingBinding = $isRecording
        view.currentComboBinding = $currentCombo
        return view
    }

    func updateNSView(_ nsView: KeyRecorderView, context: Context) {
        if isRecording && nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

class KeyRecorderView: NSView {
    var onComboRecorded: ((KeyCombo) -> Void)?
    var isRecordingBinding: Binding<Bool>?
    var currentComboBinding: Binding<KeyCombo?>?

    private var currentModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecordingBinding?.wrappedValue == true else { return }

        guard let combo = KeyCombo.from(event: event) else { return }
        currentComboBinding?.wrappedValue = combo
        onComboRecorded?(combo)
        isRecordingBinding?.wrappedValue = false
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecordingBinding?.wrappedValue == true else { return }
        currentModifiers = event.modifierFlags

        // Show current modifiers being held
        if currentModifiers.rawValue & (
            NSEvent.ModifierFlags.command.rawValue |
            NSEvent.ModifierFlags.option.rawValue |
            NSEvent.ModifierFlags.control.rawValue |
            NSEvent.ModifierFlags.shift.rawValue
        ) != 0 {
            // Create a temporary combo with just modifiers (keyCode 0 means no key yet)
            let tempCombo = KeyCombo(keyCode: 0xFFFF, modifiers: currentModifiers.rawValue)
            currentComboBinding?.wrappedValue = tempCombo
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecordingBinding?.wrappedValue = false
        return super.resignFirstResponder()
    }
}

// MARK: - Keybind Row View
struct KeybindRowView: View {
    let action: KeybindAction
    @ObservedObject var manager: KeybindingsManager
    @Binding var editingAction: KeybindAction?
    @Binding var editingIndex: Int?

    @State private var isHovered = false
    @State private var isRecording = false
    @State private var recordingCombo: KeyCombo?
    @State private var showConflictError = false

    var combos: [KeyCombo] {
        manager.combos(for: action)
    }

    var isEditing: Bool {
        editingAction == action
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Action name - vertically centered with first combo
            Text(action.displayName)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .frame(minWidth: 180, alignment: .leading)

            Spacer()

            // Key combos column
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(combos.enumerated()), id: \.element.id) { index, combo in
                    HStack(spacing: 8) {
                        // Remove/Reset button (shown on hover)
                        if isHovered {
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    cancelEditing()
                                }
                                if combos.count == 1 {
                                    // Reset to default
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        manager.resetToDefault(for: action)
                                    }
                                } else {
                                    // Remove this combo
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        manager.removeCombo(combo, from: action)
                                    }
                                }
                            }) {
                                Image(systemName: combos.count == 1 ? "arrow.counterclockwise" : "minus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 20, height: 20)
                                    .background(Color.white.opacity(0.1))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }

                        // Key combo display/editor
                        if isEditing && editingIndex == index {
                            recordingView
                        } else {
                            KeyComboView(combo: combo, isError: showConflictError && editingIndex == index)
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded {
                                    startEditing(index: index)
                                })
                        }

                        // Add button (only on last row, when hovered)
                        if isHovered && index == combos.count - 1 {
                            Button(action: {
                                // Cancel any existing edit before starting new
                                if isEditing {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        cancelEditing()
                                    }
                                }
                                addNewCombo()
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 20, height: 20)
                                    .background(Color.white.opacity(0.1))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                }

                // New combo recording row
                if isEditing && editingIndex == -1 {
                    HStack(spacing: 8) {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                cancelEditing()
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        recordingView
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)),
                        removal: .opacity.combined(with: .scale(scale: 0.8, anchor: .trailing))
                    ))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color.white.opacity(isHovered ? 0.04 : 0.02)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Clicking on row background cancels editing
                    if isEditing {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            cancelEditing()
                        }
                    }
                }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onChange(of: isRecording) { _, newValue in
            manager.isEditing = newValue
        }
    }

    private let keyTileHeight: CGFloat = 24

    @ViewBuilder
    var recordingView: some View {
        ZStack {
            if let combo = recordingCombo, combo.keyCode != 0xFFFF {
                KeyComboView(combo: combo, isPressed: true, isError: showConflictError)
            } else if let combo = recordingCombo {
                // Show modifiers being held
                HStack(spacing: 3) {
                    if combo.hasControl {
                        KeyCapView("⌃", isSymbol: true, isPressed: true)
                    }
                    if combo.hasOption {
                        KeyCapView("⌥", isSymbol: true, isPressed: true)
                    }
                    if combo.hasShift {
                        KeyCapView("⇧", isSymbol: true, isPressed: true)
                    }
                    if combo.hasCommand {
                        KeyCapView("⌘", isSymbol: true, isPressed: true)
                    }
                    Text("...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(height: keyTileHeight)
                }
            } else {
                Text("Press keys...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(height: keyTileHeight)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                    )
            }

            KeyComboEditor(
                currentCombo: $recordingCombo,
                isRecording: $isRecording,
                onComboRecorded: handleComboRecorded
            )
            .frame(width: 1, height: 1)
            .opacity(0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking on recording view should ensure we're recording, not cancel
            if !isRecording {
                isRecording = true
            }
        }
    }

    func startEditing(index: Int) {
        editingAction = action
        editingIndex = index
        recordingCombo = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isRecording = true
        }
    }

    func addNewCombo() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            editingAction = action
            editingIndex = -1
            recordingCombo = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isRecording = true
        }
    }

    func cancelEditing() {
        editingAction = nil
        editingIndex = nil
        recordingCombo = nil
        isRecording = false
    }

    func handleComboRecorded(_ combo: KeyCombo) {
        // Validate: must have Cmd, Ctrl, or Option (not just Shift or nothing)
        guard combo.isValidKeybind else {
            showConflictError = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showConflictError = false
                recordingCombo = nil
                isRecording = true // Keep recording
            }
            return
        }

        // Check for conflicts (including duplicates within same action)
        let excludeIdx = editingIndex == -1 ? nil : editingIndex
        if manager.findConflict(for: combo, excluding: action, excludingIndex: excludeIdx) != nil {
            showConflictError = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showConflictError = false
                recordingCombo = nil
                isRecording = true // Keep recording
            }
            return
        }

        // Apply the combo
        if let index = editingIndex {
            if index == -1 {
                // Adding new combo - close editing first, then add (no animation, happens together)
                cancelEditing()
                manager.addCombo(combo, to: action)
            } else {
                // Replacing existing combo
                var current = combos
                if index < current.count {
                    current[index] = combo
                    manager.setCombos(current, for: action)
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    cancelEditing()
                }
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                cancelEditing()
            }
        }
    }
}

// MARK: - Search Parsing
struct KeybindSearchParser {
    static func matches(action: KeybindAction, combos: [KeyCombo], query: String) -> Bool {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }

        // Match action name
        if action.displayName.lowercased().contains(query) {
            return true
        }

        // Parse query as potential key combo
        let normalizedQuery = normalizeQuery(query)

        // Match against combos
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

        // Normalize modifier names
        let modifierAliases: [(String, String)] = [
            ("command", "cmd"), ("meta", "cmd"), ("super", "cmd"), ("win", "cmd"), ("⌘", "cmd"),
            ("option", "opt"), ("alt", "opt"), ("⌥", "opt"),
            ("control", "ctrl"), ("⌃", "ctrl"),
            ("⇧", "shift"),
        ]

        for (alias, normalized) in modifierAliases {
            result = result.replacingOccurrences(of: alias, with: normalized)
        }

        return result
    }

    private static func matchesComboQuery(combo: KeyCombo, query: String) -> Bool {
        // Split query into parts, handling various separators
        let parts = query
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return false }

        // Check each part
        var hasCmd = false, hasOpt = false, hasCtrl = false, hasShift = false
        var keyPart: String?

        for part in parts {
            switch part {
            case "cmd", "command", "meta", "super", "win", "⌘":
                hasCmd = true
            case "opt", "option", "alt", "⌥":
                hasOpt = true
            case "ctrl", "control", "⌃":
                hasCtrl = true
            case "shift", "⇧":
                hasShift = true
            default:
                keyPart = part
            }
        }

        // Match modifiers (if specified, they must match)
        if hasCmd && !combo.hasCommand { return false }
        if hasOpt && !combo.hasOption { return false }
        if hasCtrl && !combo.hasControl { return false }
        if hasShift && !combo.hasShift { return false }

        // Match key (if specified)
        if let key = keyPart {
            let comboKey = combo.keyString.lowercased()
            // Direct match or alias match
            if comboKey != key {
                // Check aliases for special keys
                let keyAliases: [String: [String]] = [
                    "return": ["enter", "ret"],
                    "escape": ["esc"],
                    "delete": ["backspace", "del"],
                    "forward delete": ["del", "delete"],
                    "space": ["spc"],
                    "←": ["left"],
                    "→": ["right"],
                    "↑": ["up"],
                    "↓": ["down"],
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

// MARK: - Keybinds List View
struct KeybindsView: View {
    @ObservedObject var manager: KeybindingsManager
    let onBack: () -> Void

    @State private var searchText = ""
    @State private var editingAction: KeybindAction?
    @State private var editingIndex: Int?

    var isEditing: Bool {
        editingAction != nil
    }

    var filteredActions: [KeybindAction] {
        if searchText.isEmpty {
            return KeybindAction.allCases
        }
        return KeybindAction.allCases.filter { action in
            KeybindSearchParser.matches(
                action: action,
                combos: manager.combos(for: action),
                query: searchText
            )
        }
    }

    func cancelEditing() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            editingAction = nil
            editingIndex = nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header with back button
                    HStack(spacing: 12) {
                        Button(action: {
                            onBack()
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Text("Keyboard Shortcuts")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.primary)

                        Spacer()

                        Button(action: {
                            cancelEditing()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                manager.resetAllToDefaults()
                            }
                        }) {
                            Text("Reset All")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // Search bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)

                        TextField("Search by name or shortcut (e.g., cmd+w)", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    // Keybinds list
                    VStack(spacing: 1) {
                        ForEach(filteredActions) { action in
                            KeybindRowView(
                                action: action,
                                manager: manager,
                                editingAction: $editingAction,
                                editingIndex: $editingIndex
                            )
                        }
                    }
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    // Help text
                    Text("Click a shortcut to change it. Hover to add or remove shortcuts.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 120)
                .padding(.bottom, 32)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isEditing {
                    cancelEditing()
                }
            }
        }
    }
}
