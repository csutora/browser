import SwiftUI
import Combine

// MARK: - Command Palette Mode
enum CommandPaletteMode {
    case newTab      // cmd+t - creates new tab, keeps text between opens (30s timeout)
    case navigate    // cmd+l - navigates current tab, pre-fills current URL
}

// MARK: - Suggestion Types
enum SuggestionType {
    case recentTab(Tab)
    case searchSuggestion(String)
    case historyEntry(String, String) // title, url - placeholder for future
    case directURL(String)
}

struct Suggestion: Identifiable {
    let id = UUID()
    let type: SuggestionType
    let displayText: String
    let secondaryText: String?

    var iconName: String {
        switch type {
        case .recentTab: return "square.on.square"
        case .searchSuggestion: return "magnifyingglass"
        case .historyEntry: return "clock"
        case .directURL: return "globe"
        }
    }
}

// MARK: - Command Palette State
class CommandPaletteState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var mode: CommandPaletteMode = .newTab
    @Published var inputText: String = ""           // What user actually typed
    @Published var completionText: String = ""      // Suggested completion (highlighted/selected)
    @Published var selectedIndex: Int = 0
    @Published var suggestions: [Suggestion] = []

    // Display text = inputText + completionText
    var displayText: String { inputText + completionText }

    // For newTab mode - keep text for 30 seconds
    private var lastNewTabText: String = ""
    private var lastNewTabTime: Date?
    private let textRetentionDuration: TimeInterval = 30

    // Search suggestions from Google
    private var googleSuggestions: [String] = []
    private var searchTask: Task<Void, Never>?
    private var searchDebounceTask: DispatchWorkItem?

    // Track typing direction
    private var isTypingForward: Bool = true

    // Recent tabs reference
    var recentTabs: [Tab] = []

    func show(mode: CommandPaletteMode, currentURL: String? = nil, recentTabs: [Tab]) {
        self.mode = mode
        self.recentTabs = recentTabs
        self.googleSuggestions = []
        self.completionText = ""
        self.isTypingForward = true

        switch mode {
        case .newTab:
            if let lastTime = lastNewTabTime,
               Date().timeIntervalSince(lastTime) < textRetentionDuration {
                inputText = lastNewTabText
            } else {
                inputText = ""
                lastNewTabText = ""
            }

        case .navigate:
            inputText = currentURL ?? ""
        }

        selectedIndex = 0
        rebuildSuggestions()
        isVisible = true
    }

    func hide(saveText: Bool = true) {
        if mode == .newTab && saveText {
            lastNewTabText = inputText
            lastNewTabTime = Date()
        }
        isVisible = false
        searchTask?.cancel()
        searchDebounceTask?.cancel()
    }

    /// Called when text field content changes
    func handleTextChange(newDisplayText: String, selectionWasAtEnd: Bool) {
        let oldInput = inputText
        let oldCompletion = completionText

        // Case 1: User cleared the completion (backspace with selection)
        if newDisplayText == oldInput && !oldCompletion.isEmpty {
            // Completion was deleted, input stays the same
            completionText = ""
            isTypingForward = false
            // First option should now be exact query
            rebuildSuggestions()
            return
        }

        // Case 2: User deleted actual characters
        if newDisplayText.count < oldInput.count {
            inputText = newDisplayText
            completionText = ""
            isTypingForward = false
            rebuildSuggestions()
            fetchGoogleSuggestionsImmediate(for: newDisplayText)
            return
        }

        // Case 3: User typed forward (replaces selection if any, or appends)
        if newDisplayText.count > oldInput.count || (newDisplayText != oldInput && newDisplayText.count == oldInput.count) {
            // User typed - the new display text is the new input
            inputText = newDisplayText
            completionText = ""
            isTypingForward = true
            rebuildSuggestions()

            // Fetch suggestions
            let hasMatchingSuggestion = googleSuggestions.contains {
                $0.lowercased().hasPrefix(newDisplayText.lowercased()) && $0.lowercased() != newDisplayText.lowercased()
            }
            if !hasMatchingSuggestion {
                fetchGoogleSuggestionsImmediate(for: newDisplayText)
            }
            return
        }

        // Case 4: Text cleared entirely
        if newDisplayText.isEmpty {
            inputText = ""
            completionText = ""
            googleSuggestions = []
            isTypingForward = true
            selectedIndex = 0
            rebuildSuggestions()
        }
    }

    /// Accept the current completion as actual input
    func acceptCompletion() {
        guard !completionText.isEmpty else { return }
        inputText = inputText + completionText
        completionText = ""
        isTypingForward = true
        rebuildSuggestions()
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
        updateCompletion()
    }

    func selectCurrent() -> SuggestionType? {
        guard selectedIndex < suggestions.count else { return nil }
        return suggestions[selectedIndex].type
    }

    // MARK: - Suggestions Logic

    private func rebuildSuggestions() {
        if inputText.isEmpty {
            // Show recent tabs
            suggestions = recentTabs.prefix(5).map { tab in
                Suggestion(
                    type: .recentTab(tab),
                    displayText: tab.title.isEmpty ? "New Tab" : tab.title,
                    secondaryText: cleanURLForDisplay(tab.url)
                )
            }
            completionText = ""
            return
        }

        let query = inputText
        let queryLower = query.lowercased()
        let isLikelyURL = query.contains(".") && !query.contains(" ")

        var newSuggestions: [Suggestion] = []

        // Find suggestions that are continuations of the input
        let continuations = googleSuggestions.filter {
            $0.lowercased().hasPrefix(queryLower) && $0.lowercased() != queryLower
        }

        // Exact query suggestion
        let exactSuggestion: Suggestion
        if isLikelyURL {
            exactSuggestion = Suggestion(
                type: .directURL(query),
                displayText: query,
                secondaryText: "Go to website"
            )
        } else {
            exactSuggestion = Suggestion(
                type: .searchSuggestion(query),
                displayText: query,
                secondaryText: "Search Google"
            )
        }

        // First option depends on typing direction:
        // - Typing forward: best continuation (if any), otherwise exact
        // - Deleting: always exact query first
        if isTypingForward, let bestContinuation = continuations.first {
            newSuggestions.append(Suggestion(
                type: .searchSuggestion(bestContinuation),
                displayText: bestContinuation,
                secondaryText: nil
            ))
            // Add remaining continuations
            for suggestion in continuations.dropFirst().prefix(3) {
                newSuggestions.append(Suggestion(
                    type: .searchSuggestion(suggestion),
                    displayText: suggestion,
                    secondaryText: nil
                ))
            }
        } else {
            // Not typing forward or no continuations - exact query first
            newSuggestions.append(exactSuggestion)
            // Add continuations after exact
            for suggestion in continuations.prefix(3) {
                newSuggestions.append(Suggestion(
                    type: .searchSuggestion(suggestion),
                    displayText: suggestion,
                    secondaryText: nil
                ))
            }
        }

        // Add non-continuation suggestions (fill up to 5 total)
        let nonContinuations = googleSuggestions.filter {
            !$0.lowercased().hasPrefix(queryLower)
        }
        let remainingSlots = max(0, 5 - newSuggestions.count)
        for suggestion in nonContinuations.prefix(remainingSlots) {
            newSuggestions.append(Suggestion(
                type: .searchSuggestion(suggestion),
                displayText: suggestion,
                secondaryText: nil
            ))
        }

        // Limit to 5 suggestions
        suggestions = Array(newSuggestions.prefix(5))

        // Keep selection in bounds
        if selectedIndex >= suggestions.count {
            selectedIndex = 0
        }

        updateCompletion()
    }

    private func updateCompletion() {
        // Only show completion when typing forward
        guard isTypingForward, !inputText.isEmpty, selectedIndex < suggestions.count else {
            completionText = ""
            return
        }

        let suggestion = suggestions[selectedIndex]
        let suggestionLower = suggestion.displayText.lowercased()
        let inputLower = inputText.lowercased()

        // Only show completion if suggestion is a continuation of input
        if suggestionLower.hasPrefix(inputLower) && suggestionLower != inputLower {
            completionText = String(suggestion.displayText.dropFirst(inputText.count))
        } else {
            completionText = ""
        }
    }

    // MARK: - Google Suggestions Fetching

    private func fetchGoogleSuggestionsImmediate(for query: String) {
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        let currentQuery = query

        searchTask = Task { @MainActor in
            do {
                let results = try await fetchFromGoogle(query: query)
                guard self.inputText == currentQuery else { return }
                self.googleSuggestions = results
                self.rebuildSuggestions()
            } catch {
                // Keep existing suggestions on error
            }
        }
    }

    private func fetchFromGoogle(query: String) async throws -> [String] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encodedQuery)") else {
            return []
        }

        let (data, _) = try await URLSession.shared.data(from: url)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
           json.count >= 2,
           let suggestions = json[1] as? [String] {
            return suggestions
        }

        return []
    }

    private func cleanURLForDisplay(_ url: String) -> String {
        var cleaned = url
        if cleaned.hasPrefix("https://") { cleaned = String(cleaned.dropFirst(8)) }
        else if cleaned.hasPrefix("http://") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("www.") { cleaned = String(cleaned.dropFirst(4)) }
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        return cleaned
    }
}

// MARK: - Command Palette View
struct CommandPaletteView: View {
    @ObservedObject var state: CommandPaletteState
    let onSubmit: (SuggestionType) -> Void
    let onSwitchToTab: (Tab) -> Void
    let onDismiss: () -> Void

    @State private var keyMonitor: Any?

    private let paletteHeightWith5Items: CGFloat = 273

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Transparent backdrop for tap-to-dismiss
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .ignoresSafeArea()

                let topOffset = (geometry.size.height - paletteHeightWith5Items) / 2

                VStack(spacing: 0) {
                    // Input field
                    AutocompleteTextField(
                        inputText: $state.inputText,
                        completionText: $state.completionText,
                        onTextChange: { newText in
                            state.handleTextChange(newDisplayText: newText, selectionWasAtEnd: true)
                        },
                        selectAllOnAppear: state.mode == .navigate
                    )
                    .frame(height: 56)
                    .padding(.horizontal, 16)

                    if !state.suggestions.isEmpty {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        suggestionsListView
                            .padding(.vertical, 8)
                    }
                }
                .frame(width: 560)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 0.85)))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                .padding(.top, topOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { setupKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 0x35: // Escape
                onDismiss()
                return nil
            case 0x7E: // Arrow Up
                state.moveSelection(by: -1)
                return nil
            case 0x7D: // Arrow Down
                state.moveSelection(by: 1)
                return nil
            case 0x30: // Tab
                state.acceptCompletion()
                return nil
            case 0x7C: // Right Arrow - accept completion
                if !state.completionText.isEmpty {
                    state.acceptCompletion()
                    return nil
                }
                return event
            case 0x24: // Return
                handleSubmit()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private var suggestionsListView: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRowView(suggestion: suggestion, isSelected: index == state.selectedIndex)
                    .onTapGesture {
                        state.selectedIndex = index
                        handleSubmit()
                    }
            }
        }
    }

    private func handleSubmit() {
        if let selected = state.selectCurrent() {
            switch selected {
            case .recentTab(let tab):
                onSwitchToTab(tab)
            default:
                onSubmit(selected)
            }
        }
    }
}

// MARK: - Suggestion Row View
struct SuggestionRowView: View {
    let suggestion: Suggestion
    let isSelected: Bool
    @State private var isHovered = false

    private let rowHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.iconName)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? .primary : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.displayText)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let secondary = suggestion.secondaryText {
                    Text(secondary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: rowHeight)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.1) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Autocomplete TextField with Selection
struct AutocompleteTextField: NSViewRepresentable {
    @Binding var inputText: String
    @Binding var completionText: String
    let onTextChange: (String) -> Void
    let selectAllOnAppear: Bool

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 18)
        textField.textColor = NSColor.white
        textField.placeholderString = "Search or enter URL..."
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true

        context.coordinator.textField = textField

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            self.updateTextField(textField, context: context, isInitial: true)
        }

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        updateTextField(nsView, context: context, isInitial: false)
    }

    private func updateTextField(_ textField: NSTextField, context: Context, isInitial: Bool) {
        let fullText = inputText + completionText
        let coordinator = context.coordinator

        // Avoid recursive updates
        guard !coordinator.isUpdating else { return }

        if textField.stringValue != fullText {
            coordinator.isUpdating = true
            textField.stringValue = fullText

            // Set selection on the completion part
            if !completionText.isEmpty, let fieldEditor = textField.currentEditor() as? NSTextView {
                let selectionStart = inputText.count
                let selectionLength = completionText.count
                fieldEditor.setSelectedRange(NSRange(location: selectionStart, length: selectionLength))
            } else if isInitial && selectAllOnAppear && !inputText.isEmpty {
                textField.selectText(nil)
            }

            coordinator.isUpdating = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: AutocompleteTextField
        weak var textField: NSTextField?
        var isUpdating = false

        init(_ parent: AutocompleteTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isUpdating, let textField = obj.object as? NSTextField else { return }

            let newText = textField.stringValue
            parent.onTextChange(newText)
        }
    }
}
