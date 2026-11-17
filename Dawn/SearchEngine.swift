import Foundation

// A search engine: a name, a search-url template (with %s for the query), an optional suggestions-url
// template (same %s), and an optional bang/keyword to invoke it directly (stored now, wired later).
struct SearchEngine: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var searchURL: String
    var suggestURL: String?
    var bang: String?
    var bangEnabled: Bool
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, searchURL: String, suggestURL: String? = nil,
         bang: String? = nil, bangEnabled: Bool = true, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.searchURL = searchURL
        self.suggestURL = suggestURL
        self.bang = bang
        self.bangEnabled = bangEnabled
        self.isBuiltIn = isBuiltIn
    }

    // Accurate as of 2026-06; Kagi search + suggest need a logged-in Kagi session (it's a paid engine).
    static let presets: [SearchEngine] = [
        SearchEngine(name: "Google",
                     searchURL: "https://www.google.com/search?q=%s",
                     suggestURL: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s",
                     bang: "g", isBuiltIn: true),
        SearchEngine(name: "Kagi",
                     searchURL: "https://kagi.com/search?q=%s",
                     suggestURL: "https://kagi.com/api/autosuggest?q=%s",
                     bang: "k", isBuiltIn: true),
        SearchEngine(name: "DuckDuckGo",
                     searchURL: "https://duckduckgo.com/?q=%s",
                     suggestURL: "https://duckduckgo.com/ac/?q=%s&type=list",
                     bang: "d", isBuiltIn: true),
        SearchEngine(name: "Brave",
                     searchURL: "https://search.brave.com/search?q=%s",
                     suggestURL: "https://search.brave.com/api/suggest?q=%s",
                     bang: "br", isBuiltIn: true),
        SearchEngine(name: "Ecosia",
                     searchURL: "https://www.ecosia.org/search?q=%s",
                     suggestURL: "https://ac.ecosia.org/autocomplete?q=%s&type=list",
                     bang: "e", isBuiltIn: true),
        SearchEngine(name: "Bing",
                     searchURL: "https://www.bing.com/search?q=%s",
                     suggestURL: "https://api.bing.com/osjson.aspx?query=%s",
                     bang: "b", isBuiltIn: true),
    ]
}

// Persists the engine list + the chosen default to UserDefaults (Codable; it's compact config, not
// relational content). Seeds the presets on first launch.
final class SearchEngineStore {
    static let shared = SearchEngineStore()

    private let enginesKey = "searchEngines.v1"
    private let defaultKey = "searchEngines.defaultID"
    private let defaults = UserDefaults.standard

    private(set) var engines: [SearchEngine] = []

    private init() {
        if let data = defaults.data(forKey: enginesKey),
           let decoded = try? JSONDecoder().decode([SearchEngine].self, from: data), !decoded.isEmpty {
            engines = decoded
        } else {
            engines = SearchEngine.presets
            persist()
        }
    }

    var defaultEngineID: UUID {
        get {
            if let s = defaults.string(forKey: defaultKey), let id = UUID(uuidString: s),
               engines.contains(where: { $0.id == id }) { return id }
            return engines.first?.id ?? UUID()
        }
        set { defaults.set(newValue.uuidString, forKey: defaultKey) }
    }

    var defaultEngine: SearchEngine {
        engines.first(where: { $0.id == defaultEngineID }) ?? engines.first ?? SearchEngine.presets[0]
    }

    func setDefault(_ engine: SearchEngine) { defaultEngineID = engine.id }

    func add(_ engine: SearchEngine) { engines.append(engine); persist() }

    func update(_ engine: SearchEngine) {
        guard let i = engines.firstIndex(where: { $0.id == engine.id }) else { return }
        engines[i] = engine
        persist()
    }

    func remove(_ engine: SearchEngine) {
        let wasDefault = engine.id == defaultEngineID
        engines.removeAll { $0.id == engine.id }
        if engines.isEmpty { engines = SearchEngine.presets }
        if wasDefault, let first = engines.first { setDefault(first) }
        persist()
    }

    func restoreDefaults() {
        engines = SearchEngine.presets
        if let first = engines.first { setDefault(first) }
        persist()
    }

    func searchURL(for query: String) -> URL? { Self.makeURL(template: defaultEngine.searchURL, query: query) }

    func suggestURL(for query: String) -> URL? {
        guard let template = defaultEngine.suggestURL, !template.isEmpty else { return nil }
        return Self.makeURL(template: template, query: query)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(engines) { defaults.set(data, forKey: enginesKey) }
    }

    static func makeURL(template: String, query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}
