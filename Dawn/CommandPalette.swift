import AppKit
import Combine

// MARK: - Command Palette Mode
enum CommandPaletteMode {
    case newTab
    case navigate
}

// MARK: - Input Classification
enum InputType {
    case url
    case search
    case singleWord
}

// MARK: - Suggestion Types
enum SuggestionType: Equatable {
    case recentTab(Tab)
    case searchSuggestion(String)
    case historyEntry(String, String)
    case directURL(String)
    case dnsResolved(String)
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
    @Published var inputText: String = ""
    @Published var completionText: String = ""
    @Published var previewText: String = ""
    @Published var selectedIndex: Int = 0
    @Published var suggestions: [Suggestion] = []

    private var includeSearchSuggestions: Bool {
        UserDefaults.standard.bool(forKey: "includeSearchSuggestions")
    }

    private var includeHistorySuggestions: Bool {
        UserDefaults.standard.bool(forKey: "includeHistorySuggestions")
    }

    var displayText: String {
        if !previewText.isEmpty { return previewText }
        return inputText + completionText
    }

    private var lastNewTabText: String = ""
    private var lastNewTabTime: Date?
    private let textRetentionDuration: TimeInterval = 30

    private var googleSuggestions: [String] = []
    private var googleSuggestionsQuery: String = ""
    private var searchTask: Task<Void, Never>?

    var historyManager: HistoryManager?
    private var historyResults: [HistoryEntry] = []

    private var dnsResolvedHost: String?
    private var pendingDNSQuery: String?

    private var isTypingForward: Bool = true

    // true once the user arrows through the list: the selection then previews as regular
    // text in the field, and the ghost completion no longer applies
    private var isNavigatingSuggestions: Bool = false

    @Published var completionJustAccepted: Bool = false

    var recentTabs: [Tab] = []

    // MARK: - Input Classification

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

        if hasScheme(input) {
            return .url
        }

        if let firstStructural = input.firstIndex(where: { ".:/".contains($0) }) {
            let prefix = input[..<firstStructural]
            if prefix.contains(" ") || prefix.contains("\"") || prefix.contains("'") {
                return .search
            }
        } else if input.contains(" ") {
            return .search
        }

        if input.hasPrefix("?") { return .search }

        let lower = input.lowercased()
        if lower.hasPrefix("localhost") { return .url }

        if input.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) != nil {
            return .url
        }

        if input.hasPrefix("[") && input.contains("]") { return .url }

        if let colonIdx = input.lastIndex(of: ":") {
            let afterColon = input[input.index(after: colonIdx)...]
            if !afterColon.isEmpty && afterColon.allSatisfy({ $0.isNumber }) { return .url }
        }

        if input.hasSuffix("/") && input.contains(".") { return .url }

        guard input.contains(".") else { return .singleWord }

        let hostPart = String(input.split(separator: "/").first ?? Substring(input))
        let parts = hostPart.split(separator: ".")
        guard parts.count >= 2 else { return .search }

        let lastPart = String(parts.last!).lowercased()
        if PublicSuffixList.shared.isValidSuffix(lastPart) {
            return .url
        }

        if parts.count >= 2 {
            let twoPartTLD = "\(parts[parts.count - 2]).\(parts[parts.count - 1])".lowercased()
            if PublicSuffixList.shared.isValidSuffix(twoPartTLD) {
                return .url
            }
        }

        if PublicSuffixList.shared.hasValidTLD(hostPart) {
            return .url
        }

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
        self.isNavigatingSuggestions = false

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

    private func suggestionsAreRelevant() -> Bool {
        guard !googleSuggestions.isEmpty, !inputText.isEmpty else { return false }
        let inputLower = inputText.lowercased()
        let queryLower = googleSuggestionsQuery.lowercased()
        return inputLower.hasPrefix(queryLower) || queryLower.hasPrefix(inputLower)
    }

    func handleTextChange(newDisplayText: String) {
        isNavigatingSuggestions = false
        if !previewText.isEmpty {
            inputText = previewText
            previewText = ""
        }

        let oldInput = inputText
        let oldCompletion = completionText

        completionJustAccepted = false

        if newDisplayText == oldInput && !oldCompletion.isEmpty {
            completionText = ""
            isTypingForward = false
            selectedIndex = 0
            rebuildSuggestions()
            return
        }

        if newDisplayText.count < oldInput.count {
            inputText = newDisplayText
            completionText = ""
            previewText = ""
            isTypingForward = false
            selectedIndex = 0

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

        if newDisplayText.count > oldInput.count || (newDisplayText != oldInput && newDisplayText.count == oldInput.count) {
            inputText = newDisplayText
            completionText = ""
            previewText = ""
            isTypingForward = true
            selectedIndex = 0

            if !suggestionsAreRelevant() {
                googleSuggestions = []
                googleSuggestionsQuery = ""
            }

            rebuildSuggestions()

            let matchingCount = googleSuggestions.filter {
                $0.lowercased().hasPrefix(newDisplayText.lowercased()) && $0.lowercased() != newDisplayText.lowercased()
            }.count
            if matchingCount < 5 {
                fetchGoogleSuggestionsDebounced(for: newDisplayText)
            }

            checkDNSResolution(for: newDisplayText)
            fetchHistoryResults(for: newDisplayText)
            return
        }

        if newDisplayText.isEmpty {
            inputText = ""
            completionText = ""
            previewText = ""
            googleSuggestions = []
            googleSuggestionsQuery = ""
            historyResults = []
            isTypingForward = true
            selectedIndex = 0
            dnsResolvedHost = nil
            rebuildSuggestions()
        }
    }

    func acceptCompletion() {
        if !previewText.isEmpty {
            inputText = previewText
            previewText = ""
            completionText = ""
            completionJustAccepted = true
            isTypingForward = false
            isNavigatingSuggestions = false
            rebuildSuggestions()
        } else if !completionText.isEmpty {
            inputText = inputText + completionText
            completionText = ""
            completionJustAccepted = true
            isTypingForward = false
            isNavigatingSuggestions = false
            rebuildSuggestions()
        }
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        isNavigatingSuggestions = true
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
        updateDisplayForSelection()
    }

    func selectCurrent() -> SuggestionType? {
        if !previewText.isEmpty {
            if let suggestion = suggestions.first(where: { $0.displayText == previewText }) {
                return suggestion.type
            }
        }
        if !completionText.isEmpty {
            // an unaccepted ghost completion is not real text: submit what was typed,
            // not the suggestion the ghost came from
            let lower = inputText.lowercased()
            if let exact = suggestions.first(where: { $0.displayText.lowercased() == lower }) {
                return exact.type
            }
            return classifyInput(inputText) == .url ? .directURL(inputText) : .searchSuggestion(inputText)
        }
        guard selectedIndex < suggestions.count else { return nil }
        return suggestions[selectedIndex].type
    }

    // MARK: - DNS Resolution

    private func checkDNSResolution(for query: String) {
        // Resolve only the host (strip any path and port), so intranet golinks like "go/nix/firefox"
        // or "go:8080/nix" resolve via their host "go", not the whole string (which CFHost can't look
        // up). The full query stays the thing we navigate to.
        let beforePath = query.split(separator: "/", maxSplits: 1).first ?? Substring(query)
        let host = String(beforePath.split(separator: ":", maxSplits: 1).first ?? beforePath)
        guard !host.contains("."), !host.contains(" "), host.count >= 2 else {
            return
        }

        if dnsResolvedHost == query {
            return
        }

        pendingDNSQuery = query

        DNSResolver.resolveInBackground(host, timeout: 2.0) { [weak self] resolved, _ in
            guard let self = self else { return }
            guard self.pendingDNSQuery == query, self.inputText == query else { return }

            if resolved {
                self.dnsResolvedHost = query
                self.rebuildSuggestions()
            }
        }
    }

    // MARK: - Suggestions Logic

    private func rebuildSuggestions() {
        completionText = ""
        previewText = ""

        if inputText.isEmpty {
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

        if inputType == .url {
            newSuggestions.append(Suggestion(
                type: .directURL(query),
                displayText: query,
                secondaryText: "Go to website"
            ))

            if includeHistorySuggestions {
                let urlHistoryMatches = historyResults
                    .filter { entry in
                        let entryURL = entry.url.lowercased()
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

            if selectedIndex >= suggestions.count {
                selectedIndex = 0
            }
            return
        }

        if inputType == .singleWord {
            if dnsResolvedHost == query {
                newSuggestions.append(Suggestion(
                    type: .dnsResolved(query),
                    displayText: query,
                    secondaryText: "Go to \(query)"
                ))
            }
        }

        let continuations = includeSearchSuggestions ? googleSuggestions.filter { suggestion in
            let lower = suggestion.lowercased()
            return lower.hasPrefix(queryLower) && lower != queryLower
        } : []

        newSuggestions.append(Suggestion(
            type: .searchSuggestion(query),
            displayText: query,
            secondaryText: nil
        ))

        if includeHistorySuggestions && !historyResults.isEmpty {
            var scoredSuggestions: [(Suggestion, Double)] = []

            for entry in historyResults {
                let suggestion = Suggestion(
                    type: .historyEntry(entry.title, entry.url),
                    displayText: entry.title.isEmpty ? cleanURLForDisplay(entry.url) : entry.title,
                    secondaryText: cleanURLForDisplay(entry.url)
                )
                scoredSuggestions.append((suggestion, entry.frecencyScore))
            }

            for text in continuations {
                let suggestion = Suggestion(
                    type: .searchSuggestion(text),
                    displayText: text,
                    secondaryText: nil
                )
                scoredSuggestions.append((suggestion, 1.0))
            }

            scoredSuggestions.sort { $0.1 > $1.1 }
            let mergedSuggestions = scoredSuggestions.prefix(20).map { $0.0 }
            newSuggestions.append(contentsOf: mergedSuggestions)
        } else {
            for suggestion in continuations {
                newSuggestions.append(Suggestion(
                    type: .searchSuggestion(suggestion),
                    displayText: suggestion,
                    secondaryText: nil
                ))
            }
        }

        suggestions = newSuggestions

        if selectedIndex >= suggestions.count {
            selectedIndex = max(0, suggestions.count - 1)
        }

        if isTypingForward && selectedIndex < suggestions.count {
            updateDisplayForSelection()
        }
    }

    private func updateDisplayForSelection() {
        completionText = ""
        previewText = ""
        guard !inputText.isEmpty, selectedIndex < suggestions.count else { return }

        let inputLower = inputText.lowercased()

        if isNavigatingSuggestions {
            // arrowing through the list shows the suggestion as regular text in the field
            let suggestion = suggestions[selectedIndex]
            if case .historyEntry = suggestion.type { return }
            if suggestion.displayText.lowercased() != inputLower {
                previewText = suggestion.displayText
            }
            return
        }

        // typing forward: ghost the first actual suggestion below the exact-text row,
        // when it continues what was typed
        guard let next = suggestions.first(where: { $0.displayText.lowercased() != inputLower }) else { return }
        if case .historyEntry = next.type { return }
        if next.displayText.lowercased().hasPrefix(inputLower) {
            completionText = String(next.displayText.dropFirst(inputText.count))
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
            try? await Task.sleep(nanoseconds: 50_000_000)

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

    // Suggestions come from the default engine's suggest endpoint. Google (firefox client), DuckDuckGo
    // (type=list), Bing (osjson) and Ecosia all return the same OpenSearch shape `[query, [sug, ...]]`,
    // so one parser covers them; engines without a suggest url (or a non-matching one) just yield none.
    private func fetchFromGoogle(query: String) async throws -> [String] {
        guard let url = SearchEngineStore.shared.suggestURL(for: query) else { return [] }

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
