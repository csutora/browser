import Foundation

/// Parses and queries the Public Suffix List for URL detection.
/// Downloads the PSL on first launch and updates weekly.
/// See: https://publicsuffix.org/
class PublicSuffixList {
    static let shared = PublicSuffixList()

    /// Direct suffix matches (e.g., "com", "co.uk")
    private var suffixes: Set<String> = []

    /// Wildcard rules (e.g., "*.kawasaki.jp" stored as "kawasaki.jp")
    private var wildcards: Set<String> = []

    /// Exception rules that override wildcards (e.g., "!city.kawasaki.jp" stored as "city.kawasaki.jp")
    private var exceptions: Set<String> = []

    /// Whether the list has been loaded (either from cache or download)
    private(set) var isLoaded = false

    /// Common TLDs for fallback when PSL isn't loaded yet
    private let fallbackTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int",
        "co", "io", "ai", "app", "dev", "me", "tv", "cc", "info", "biz", "name", "pro",
        "uk", "de", "fr", "it", "es", "nl", "be", "at", "ch", "pl", "ru", "jp", "cn", "kr", "au", "nz", "ca", "br", "mx", "in",
        "co.uk", "com.au", "co.nz", "co.jp", "com.br", "com.mx"
    ]

    private let pslURL = URL(string: "https://publicsuffix.org/list/public_suffix_list.dat")!
    private let cacheFileName = "public_suffix_list.dat"
    private let updateInterval: TimeInterval = 7 * 24 * 60 * 60 // 1 week

    private var cacheFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("Dawn", isDirectory: true)
        return appDir.appendingPathComponent(cacheFileName)
    }

    private var lastUpdateKey = "PSLLastUpdateDate"

    init() {
        loadAsync()
    }

    /// Load PSL asynchronously - from cache if fresh, otherwise download
    private func loadAsync() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.loadOrUpdate()
        }
    }

    private func loadOrUpdate() async {
        // Try to load from cache first
        if let cachedContent = loadFromCache() {
            await parseContent(cachedContent)
            await MainActor.run { self.isLoaded = true }

            // Check if update needed
            if shouldUpdate() {
                await downloadAndUpdate()
            }
        } else {
            // No cache, download immediately
            await downloadAndUpdate()
        }
    }

    private func loadFromCache() -> String? {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else {
            return nil
        }
        return try? String(contentsOf: cacheFileURL, encoding: .utf8)
    }

    private func shouldUpdate() -> Bool {
        guard let lastUpdate = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastUpdate) > updateInterval
    }

    private func downloadAndUpdate() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: pslURL)
            guard let content = String(data: data, encoding: .utf8) else { return }

            // Save to cache
            try? saveToCache(content)

            // Parse
            await parseContent(content)
            await MainActor.run { self.isLoaded = true }

            // Update timestamp
            UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
        } catch {
            // Download failed, will try again next launch
            print("PublicSuffixList: Failed to download - \(error.localizedDescription)")
        }
    }

    private func saveToCache(_ content: String) throws {
        let directory = cacheFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: cacheFileURL, atomically: true, encoding: .utf8)
    }

    private func parseContent(_ content: String) async {
        var newSuffixes: Set<String> = []
        var newWildcards: Set<String> = []
        var newExceptions: Set<String> = []

        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                continue
            }

            // Handle different rule types
            if trimmed.hasPrefix("*.") {
                // Wildcard rule
                let suffix = String(trimmed.dropFirst(2)).lowercased()
                newWildcards.insert(suffix)
            } else if trimmed.hasPrefix("!") {
                // Exception rule
                let suffix = String(trimmed.dropFirst(1)).lowercased()
                newExceptions.insert(suffix)
            } else {
                // Regular suffix
                newSuffixes.insert(trimmed.lowercased())
            }
        }

        // Thread-safe assignment on main thread
        await MainActor.run {
            self.suffixes = newSuffixes
            self.wildcards = newWildcards
            self.exceptions = newExceptions
        }
    }

    /// Checks if the given string is a valid public suffix.
    func isValidSuffix(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()

        // If not loaded, use fallback
        if !isLoaded {
            return fallbackTLDs.contains(lower)
        }

        // Direct match
        if suffixes.contains(lower) {
            return true
        }

        // Check wildcard rules
        let parts = lower.split(separator: ".")
        if parts.count >= 2 {
            let parent = parts.dropFirst().joined(separator: ".")
            if wildcards.contains(parent) {
                // Check for exception
                if exceptions.contains(lower) {
                    return false
                }
                return true
            }
        }

        return false
    }

    /// Returns true if the domain has a valid TLD according to the PSL.
    func hasValidTLD(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        let parts = lower.split(separator: ".").map(String.init)

        guard parts.count >= 2 else {
            return false
        }

        // If not loaded, use fallback
        if !isLoaded {
            let lastPart = parts.last!
            let twoPartTLD = "\(parts[parts.count - 2]).\(lastPart)"
            return fallbackTLDs.contains(lastPart) || fallbackTLDs.contains(twoPartTLD)
        }

        // Check suffixes from 1-part up to 4-part (covers virtually all TLDs)
        for length in 1...min(parts.count - 1, 4) {
            let suffix = parts.suffix(length).joined(separator: ".")
            if isValidSuffix(suffix) {
                return true
            }
        }

        return false
    }
}
