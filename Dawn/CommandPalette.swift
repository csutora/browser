import SwiftUI
import Combine

// MARK: - Command Palette Mode
enum CommandPaletteMode {
    case newTab      // cmd+t - creates new tab, keeps text between opens (30s timeout)
    case navigate    // cmd+l - navigates current tab, pre-fills current URL
}

// MARK: - Input Classification
enum InputType {
    case url           // Definitely a URL - show "Go to website"
    case search        // Definitely a search query
    case singleWord    // Single word without dots - needs DNS check
}

// MARK: - Suggestion Types
enum SuggestionType: Equatable {
    case recentTab(Tab)
    case searchSuggestion(String)
    case historyEntry(String, String) // title, url - placeholder for future
    case directURL(String)
    case dnsResolved(String)  // Single word that resolved via DNS
}

struct Suggestion: Identifiable, Equatable {
    let id = UUID()
    let type: SuggestionType
    let displayText: String
    let secondaryText: String?

    var iconName: String {
        switch type {
        case .recentTab: return "square.on.square"
        case .searchSuggestion: return "magnifyingglass"
        case .historyEntry: return "clock"
        case .directURL, .dnsResolved: return "globe"
        }
    }

    static func == (lhs: Suggestion, rhs: Suggestion) -> Bool {
        lhs.type == rhs.type &&
        lhs.displayText == rhs.displayText &&
        lhs.secondaryText == rhs.secondaryText
    }
}

// MARK: - Command Palette State
class CommandPaletteState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var mode: CommandPaletteMode = .newTab
    @Published var inputText: String = ""           // What user actually typed
    @Published var completionText: String = ""      // Suggested completion (for congruent suggestions)
    @Published var previewText: String = ""         // Full text for non-congruent suggestion preview
    @Published var selectedIndex: Int = 0
    @Published var suggestions: [Suggestion] = []

    // Settings for suggestions
    @AppStorage("includeSearchSuggestions") private var includeSearchSuggestions: Bool = true
    @AppStorage("includeHistorySuggestions") private var includeHistorySuggestions: Bool = true

    // Display text: preview if set, otherwise input + completion
    var displayText: String {
        if !previewText.isEmpty { return previewText }
        return inputText + completionText
    }

    // For newTab mode - keep text for 30 seconds
    private var lastNewTabText: String = ""
    private var lastNewTabTime: Date?
    private let textRetentionDuration: TimeInterval = 30

    // Search suggestions from Google
    private var googleSuggestions: [String] = []
    private var googleSuggestionsQuery: String = ""  // The query these suggestions are for
    private var searchTask: Task<Void, Never>?

    // History suggestions
    var historyManager: HistoryManager?
    private var historyResults: [HistoryEntry] = []

    // DNS resolution for single words
    private var dnsResolvedHost: String?
    private var pendingDNSQuery: String?

    // Track typing direction
    private var isTypingForward: Bool = true

    // Track if completion was just accepted (for cursor positioning)
    @Published var completionJustAccepted: Bool = false

    // Show exact match suggestion at top (triggered by backspace, hidden by appending to end)
    private var showExactMatch: Bool = false

    // Recent tabs reference
    var recentTabs: [Tab] = []

    // MARK: - Input Classification

    /// Check if input has any URL scheme (handles http://, https://, dawn://, file://, etc.)
    private func hasScheme(_ input: String) -> Bool {
        guard let schemeEnd = input.range(of: "://") else { return false }
        let scheme = input[..<schemeEnd.lowerBound]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
        }
    }

    func classifyInput(_ text: String) -> InputType {
        let input = text.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return .search }

        // Any scheme (http://, https://, dawn://, file://, etc.) → URL
        if hasScheme(input) {
            return .url
        }

        // Firefox quick rejection: space/quote before first structural char → search
        if let firstStructural = input.firstIndex(where: { ".:/".contains($0) }) {
            let prefix = input[..<firstStructural]
            if prefix.contains(" ") || prefix.contains("\"") || prefix.contains("'") {
                return .search
            }
        } else if input.contains(" ") {
            return .search
        }

        // Starts with ? → search
        if input.hasPrefix("?") { return .search }

        // localhost → URL
        let lower = input.lowercased()
        if lower.hasPrefix("localhost") { return .url }

        // IPv4 address → URL
        if input.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) != nil {
            return .url
        }

        // IPv6 address → URL
        if input.hasPrefix("[") && input.contains("]") { return .url }

        // Has port (host:1234) → URL
        if let colonIdx = input.lastIndex(of: ":") {
            let afterColon = input[input.index(after: colonIdx)...]
            if !afterColon.isEmpty && afterColon.allSatisfy({ $0.isNumber }) { return .url }
        }

        // Trailing slash with dot → URL (user explicitly indicating URL)
        if input.hasSuffix("/") && input.contains(".") { return .url }

        // No dot = single word → needs DNS check
        guard input.contains(".") else { return .singleWord }

        // Has dot - check TLD against Public Suffix List
        let hostPart = String(input.split(separator: "/").first ?? Substring(input))
        let parts = hostPart.split(separator: ".")
        guard parts.count >= 2 else { return .search }

        // Check single-part TLD
        let lastPart = String(parts.last!).lowercased()
        if PublicSuffixList.shared.isValidSuffix(lastPart) {
            return .url
        }

        // Check two-part TLD (e.g., .co.uk)
        if parts.count >= 2 {
            let twoPartTLD = "\(parts[parts.count - 2]).\(parts[parts.count - 1])".lowercased()
            if PublicSuffixList.shared.isValidSuffix(twoPartTLD) {
                return .url
            }
        }

        // Check if domain has valid TLD
        if PublicSuffixList.shared.hasValidTLD(hostPart) {
            return .url
        }

        // Unknown TLD → treat as search
        return .search
    }

    // MARK: - Public Methods

    func show(mode: CommandPaletteMode, currentURL: String? = nil, recentTabs: [Tab]) {
        self.mode = mode
        self.recentTabs = recentTabs
        self.googleSuggestions = []
        self.googleSuggestionsQuery = ""
        self.historyResults = []
        self.completionText = ""
        self.previewText = ""
        self.isTypingForward = true
        self.dnsResolvedHost = nil
        self.pendingDNSQuery = nil
        self.completionJustAccepted = false
        self.showExactMatch = false

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
    }

    /// Check if suggestions are relevant to current input
    private func suggestionsAreRelevant() -> Bool {
        guard !googleSuggestions.isEmpty, !inputText.isEmpty else { return false }
        let inputLower = inputText.lowercased()
        let queryLower = googleSuggestionsQuery.lowercased()

        // Suggestions are relevant if:
        // 1. Current input starts with the query that fetched these suggestions, OR
        // 2. The query starts with current input (user deleted some chars)
        return inputLower.hasPrefix(queryLower) || queryLower.hasPrefix(inputLower)
    }

    /// Called when text field content changes
    func handleTextChange(newDisplayText: String) {
        // If we had a preview, commit it on any text change
        if !previewText.isEmpty {
            // User is editing - commit the preview as the new input base
            inputText = previewText
            previewText = ""
        }

        let oldInput = inputText
        let oldCompletion = completionText

        // Reset completion accepted flag
        completionJustAccepted = false

        // Determine if this is an append to the end (for showExactMatch logic)
        let isAppendToEnd = newDisplayText.hasPrefix(oldInput) && newDisplayText.count > oldInput.count

        // Case 1: User cleared the completion (backspace with selection)
        if newDisplayText == oldInput && !oldCompletion.isEmpty {
            completionText = ""
            isTypingForward = false
            selectedIndex = 0
            showExactMatch = true  // Backspace triggers exact match
            rebuildSuggestions()
            return
        }

        // Case 2: User deleted actual characters
        if newDisplayText.count < oldInput.count {
            inputText = newDisplayText
            completionText = ""
            previewText = ""
            isTypingForward = false
            selectedIndex = 0
            showExactMatch = !newDisplayText.isEmpty  // Show exact match on backspace (if not empty)

            // Clear suggestions if they're no longer relevant
            if !suggestionsAreRelevant() {
                googleSuggestions = []
                googleSuggestionsQuery = ""
            }

            rebuildSuggestions()

            if !newDisplayText.isEmpty {
                fetchGoogleSuggestionsDebounced(for: newDisplayText)
                fetchHistoryResults(for: newDisplayText)
            }
            return
        }

        // Case 3: User typed forward (replaces selection if any, or appends)
        if newDisplayText.count > oldInput.count || (newDisplayText != oldInput && newDisplayText.count == oldInput.count) {
            inputText = newDisplayText
            completionText = ""
            previewText = ""
            isTypingForward = true
            selectedIndex = 0

            // Update showExactMatch: hide if appending to end, keep if editing middle
            if isAppendToEnd {
                showExactMatch = false
            }
            // else: editing in middle - keep showExactMatch as is

            // Clear suggestions if they're no longer relevant
            if !suggestionsAreRelevant() {
                googleSuggestions = []
                googleSuggestionsQuery = ""
            }

            rebuildSuggestions()

            // Fetch suggestions if we have fewer than 5 matching ones
            let matchingCount = googleSuggestions.filter {
                $0.lowercased().hasPrefix(newDisplayText.lowercased()) && $0.lowercased() != newDisplayText.lowercased()
            }.count
            if matchingCount < 5 {
                fetchGoogleSuggestionsDebounced(for: newDisplayText)
            }

            // Check for DNS resolution on single words
            checkDNSResolution(for: newDisplayText)

            // Fetch history suggestions
            fetchHistoryResults(for: newDisplayText)
            return
        }

        // Case 4: Text cleared entirely
        if newDisplayText.isEmpty {
            inputText = ""
            completionText = ""
            previewText = ""
            googleSuggestions = []
            googleSuggestionsQuery = ""
            historyResults = []
            isTypingForward = true
            selectedIndex = 0
            showExactMatch = false
            dnsResolvedHost = nil
            rebuildSuggestions()
        }
    }

    /// Accept the current completion/preview as actual input
    func acceptCompletion() {
        if !previewText.isEmpty {
            // Accept preview
            inputText = previewText
            previewText = ""
            completionText = ""
            completionJustAccepted = true
            isTypingForward = false  // Don't auto-extend further after accepting
            showExactMatch = true    // Show exact match at top (same as backspace behavior)
            rebuildSuggestions()
        } else if !completionText.isEmpty {
            // Accept completion
            inputText = inputText + completionText
            completionText = ""
            completionJustAccepted = true
            isTypingForward = false  // Don't auto-extend further after accepting
            showExactMatch = true    // Show exact match at top (same as backspace behavior)
            rebuildSuggestions()
        }
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
        updateDisplayForSelection()
    }

    func selectCurrent() -> SuggestionType? {
        // If we have a preview, use that for submission
        if !previewText.isEmpty {
            // Find the suggestion that matches the preview
            if let suggestion = suggestions.first(where: { $0.displayText == previewText }) {
                return suggestion.type
            }
        }
        guard selectedIndex < suggestions.count else { return nil }
        return suggestions[selectedIndex].type
    }

    // MARK: - DNS Resolution

    private func checkDNSResolution(for query: String) {
        // Only check single words (no dots, no spaces)
        guard !query.contains(".") && !query.contains(" ") && query.count >= 2 else {
            return
        }

        // Don't re-check if we already have this resolved
        if dnsResolvedHost == query {
            return
        }

        // Cancel any pending DNS check
        pendingDNSQuery = query

        DNSResolver.resolveInBackground(query, timeout: 2.0) { [weak self] resolved, hostname in
            guard let self = self else { return }
            // Only update if this is still the current query
            guard self.pendingDNSQuery == query, self.inputText == query else { return }

            if resolved, let host = hostname {
                self.dnsResolvedHost = host
                self.rebuildSuggestions()
            }
        }
    }

    // MARK: - Suggestions Logic

    private func rebuildSuggestions() {
        // Always clear completion/preview when rebuilding from scratch
        completionText = ""
        previewText = ""

        if inputText.isEmpty {
            // Show recent tabs when empty
            suggestions = recentTabs.prefix(5).map { tab in
                Suggestion(
                    type: .recentTab(tab),
                    displayText: tab.title.isEmpty ? "New Tab" : tab.title,
                    secondaryText: cleanURLForDisplay(tab.url)
                )
            }
            return
        }

        let query = inputText
        let queryLower = query.lowercased()
        let inputType = classifyInput(query)

        var newSuggestions: [Suggestion] = []

        // For URLs: show direct URL option first, then matching history URLs
        if inputType == .url {
            newSuggestions.append(Suggestion(
                type: .directURL(query),
                displayText: query,
                secondaryText: "Go to website"
            ))

            // Add matching history URLs (sorted by frecency)
            if includeHistorySuggestions {
                let queryLower = query.lowercased()
                let urlHistoryMatches = historyResults
                    .filter { entry in
                        let entryURL = entry.url.lowercased()
                        // Match if history URL contains the input and isn't exactly the same
                        return entryURL.contains(queryLower) && entryURL != queryLower
                    }
                    .sorted { $0.frecencyScore > $1.frecencyScore }
                    .prefix(5)

                for entry in urlHistoryMatches {
                    newSuggestions.append(Suggestion(
                        type: .historyEntry(entry.title, entry.url),
                        displayText: entry.title.isEmpty ? cleanURLForDisplay(entry.url) : entry.title,
                        secondaryText: cleanURLForDisplay(entry.url)
                    ))
                }
            }

            // Add Google suggestions below (but don't auto-complete with them)
            if includeSearchSuggestions {
                for suggestion in googleSuggestions {
                    newSuggestions.append(Suggestion(
                        type: .searchSuggestion(suggestion),
                        displayText: suggestion,
                        secondaryText: nil
                    ))
                }
            }

            suggestions = newSuggestions

            // Keep selection in bounds
            if selectedIndex >= suggestions.count {
                selectedIndex = 0
            }
            return
        }

        // For single words: check if DNS resolved
        if inputType == .singleWord {
            // If DNS resolved, show "Go to X" option
            if dnsResolvedHost == query {
                newSuggestions.append(Suggestion(
                    type: .dnsResolved(query),
                    displayText: query,
                    secondaryText: "Go to \(query)"
                ))
            }
        }

        // Find Google suggestions that are continuations of the input
        let continuations = includeSearchSuggestions ? googleSuggestions.filter { suggestion in
            let lower = suggestion.lowercased()
            return lower.hasPrefix(queryLower) && lower != queryLower
        } : []

        // Show exact match at top when:
        // 1. Triggered by backspace (showExactMatch), OR
        // 2. No suggestions available (so there's always something to select)
        let hasAnySuggestions = !continuations.isEmpty || !historyResults.isEmpty
        if showExactMatch || !hasAnySuggestions {
            newSuggestions.append(Suggestion(
                type: .searchSuggestion(query),
                displayText: query,
                secondaryText: nil
            ))
        }

        // Merge history and Google suggestions by frecency
        if includeHistorySuggestions && !historyResults.isEmpty {
            // Create scored suggestions for merging
            var scoredSuggestions: [(Suggestion, Double)] = []

            // Add history entries with their frecency scores
            // Display title as primary, URL as secondary (consistent with tab suggestions)
            for entry in historyResults {
                let suggestion = Suggestion(
                    type: .historyEntry(entry.title, entry.url),
                    displayText: entry.title.isEmpty ? cleanURLForDisplay(entry.url) : entry.title,
                    secondaryText: cleanURLForDisplay(entry.url)
                )
                scoredSuggestions.append((suggestion, entry.frecencyScore))
            }

            // Add Google suggestions with base score of 1.0
            for text in continuations {
                let suggestion = Suggestion(
                    type: .searchSuggestion(text),
                    displayText: text,
                    secondaryText: nil
                )
                scoredSuggestions.append((suggestion, 1.0))
            }

            // Sort by score (higher first) and take top results
            scoredSuggestions.sort { $0.1 > $1.1 }
            let mergedSuggestions = scoredSuggestions.prefix(20).map { $0.0 }
            newSuggestions.append(contentsOf: mergedSuggestions)
        } else {
            // Just use Google suggestions
            for suggestion in continuations {
                newSuggestions.append(Suggestion(
                    type: .searchSuggestion(suggestion),
                    displayText: suggestion,
                    secondaryText: nil
                ))
            }
        }

        suggestions = newSuggestions

        // Keep selection in bounds
        if selectedIndex >= suggestions.count {
            selectedIndex = max(0, suggestions.count - 1)
        }

        // Update completion text for first suggestion if typing forward
        if isTypingForward && selectedIndex < suggestions.count {
            updateDisplayForSelection()
        }
    }

    private func updateDisplayForSelection() {
        guard !inputText.isEmpty, selectedIndex < suggestions.count else {
            completionText = ""
            previewText = ""
            return
        }

        let suggestion = suggestions[selectedIndex]

        // History entries should NOT auto-complete or preview - just be selectable
        if case .historyEntry = suggestion.type {
            completionText = ""
            previewText = ""
            return
        }

        let suggestionLower = suggestion.displayText.lowercased()
        let inputLower = inputText.lowercased()

        if suggestionLower == inputLower {
            // Exact match - no completion or preview needed
            previewText = ""
            completionText = ""
        } else if suggestionLower.hasPrefix(inputLower) {
            // Congruent - use completion mechanism
            previewText = ""
            completionText = String(suggestion.displayText.dropFirst(inputText.count))
        } else {
            // Non-congruent - show full preview
            completionText = ""
            previewText = suggestion.displayText
        }
    }

    // MARK: - History Suggestions

    private func fetchHistoryResults(for query: String) {
        guard includeHistorySuggestions, !query.isEmpty else {
            historyResults = []
            return
        }
        historyResults = historyManager?.search(query: query, limit: 10) ?? []
        rebuildSuggestions()
    }

    // MARK: - Google Suggestions Fetching

    private func fetchGoogleSuggestionsDebounced(for query: String) {
        guard includeSearchSuggestions, !query.isEmpty else { return }
        searchTask?.cancel()
        let currentQuery = query

        searchTask = Task { @MainActor in
            // Small debounce
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

            guard !Task.isCancelled, self.inputText == currentQuery else { return }

            do {
                let results = try await fetchFromGoogle(query: query)
                guard self.inputText == currentQuery else { return }
                self.googleSuggestions = results
                self.googleSuggestionsQuery = currentQuery
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
    @State private var scrollProxy: ScrollViewProxy?
    @State private var visibleRange: Range<Int> = 0..<5

    private let rowHeight: CGFloat = 44
    private let visibleRows: Int = 5
    private var maxSuggestionsHeight: CGFloat { CGFloat(visibleRows) * rowHeight }

    // Fixed height for 5 rows - used for positioning
    private var fixedPaletteHeight: CGFloat { 56 + 1 + maxSuggestionsHeight + 16 }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Transparent backdrop for tap-to-dismiss
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .ignoresSafeArea()

                // Calculate top offset based on FIXED 5-row height (for consistent positioning)
                let topOffset = (geometry.size.height - fixedPaletteHeight) / 2

                // Actual content height based on current suggestions
                let actualSuggestionsHeight = min(maxSuggestionsHeight, CGFloat(state.suggestions.count) * rowHeight)
                let showSuggestions = !state.suggestions.isEmpty

                VStack(spacing: 0) {
                    // Input field
                    AutocompleteTextField(
                        inputText: $state.inputText,
                        completionText: $state.completionText,
                        previewText: $state.previewText,
                        completionJustAccepted: $state.completionJustAccepted,
                        onTextChange: { newText in
                            state.handleTextChange(newDisplayText: newText)
                        },
                        selectAllOnAppear: state.mode == .navigate
                    )
                    .frame(height: 56)
                    .padding(.horizontal, 16)

                    if showSuggestions {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        suggestionsListView
                            .frame(height: actualSuggestionsHeight)
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
                scrollToSelectionIfNeeded()
                return nil
            case 0x7D: // Arrow Down
                state.moveSelection(by: 1)
                scrollToSelectionIfNeeded()
                return nil
            case 0x30: // Tab - accept completion/preview
                state.acceptCompletion()
                return nil
            case 0x7C: // Right Arrow - accept completion if at end
                if !state.completionText.isEmpty || !state.previewText.isEmpty {
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

    /// Only scroll if the selected item is outside the visible range
    private func scrollToSelectionIfNeeded() {
        guard let proxy = scrollProxy,
              state.selectedIndex < state.suggestions.count,
              state.suggestions.count > visibleRows else { return }

        let idx = state.selectedIndex

        // Only scroll if selection is outside visible range
        if idx < visibleRange.lowerBound || idx >= visibleRange.upperBound {
            // Determine anchor based on direction
            let anchor: UnitPoint
            if idx < visibleRange.lowerBound {
                anchor = .top
                visibleRange = idx..<(idx + visibleRows)
            } else {
                anchor = .bottom
                visibleRange = (idx - visibleRows + 1)..<(idx + 1)
            }

            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(state.suggestions[idx].id, anchor: anchor)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionRowView(suggestion: suggestion, isSelected: index == state.selectedIndex)
                            .id(suggestion.id)
                            .onTapGesture {
                                state.selectedIndex = index
                                handleSubmit()
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollProxy = proxy
                visibleRange = 0..<min(visibleRows, state.suggestions.count)
            }
            .onChange(of: state.suggestions.count) { _, newCount in
                visibleRange = 0..<min(visibleRows, newCount)
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

// MARK: - Autocomplete TextField with Selection and Preview
struct AutocompleteTextField: NSViewRepresentable {
    @Binding var inputText: String
    @Binding var completionText: String
    @Binding var previewText: String
    @Binding var completionJustAccepted: Bool
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
        let coordinator = context.coordinator

        // Avoid recursive updates
        guard !coordinator.isUpdating else { return }

        // Determine what text to display
        let displayText: String
        let selectionStart: Int
        let selectionLength: Int

        if !previewText.isEmpty {
            // Preview mode: show full preview text, cursor at end (no selection)
            displayText = previewText
            selectionStart = previewText.count
            selectionLength = 0
        } else {
            // Normal mode: input + completion (completion part is selected)
            displayText = inputText + completionText
            selectionStart = inputText.count
            selectionLength = completionText.count
        }

        // Check if we need to update
        let needsTextUpdate = textField.stringValue != displayText
        let needsCursorUpdate = completionJustAccepted

        if needsTextUpdate || needsCursorUpdate {
            coordinator.isUpdating = true

            if needsTextUpdate {
                textField.stringValue = displayText
            }

            if let fieldEditor = textField.currentEditor() as? NSTextView {
                if completionJustAccepted {
                    // Completion was accepted - move cursor to end
                    fieldEditor.setSelectedRange(NSRange(location: displayText.count, length: 0))
                    // Reset the flag synchronously
                    DispatchQueue.main.async {
                        self.completionJustAccepted = false
                    }
                } else if selectionLength > 0 {
                    // Set selection on completion part only
                    fieldEditor.setSelectedRange(NSRange(location: selectionStart, length: selectionLength))
                } else if isInitial && selectAllOnAppear && !inputText.isEmpty {
                    textField.selectText(nil)
                } else if needsTextUpdate && previewText.isEmpty && completionText.isEmpty {
                    // Text changed but no completion - keep cursor at end
                    fieldEditor.setSelectedRange(NSRange(location: displayText.count, length: 0))
                }
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

            // Process synchronously to avoid race conditions
            isUpdating = true
            let newText = textField.stringValue
            isUpdating = false

            parent.onTextChange(newText)
        }
    }
}
