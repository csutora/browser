import Foundation

// the sandbox lets the app read a file picked in the open panel only until it quits. a
// security-scoped bookmark taken at pick time re-grants that access on later launches, so restored
// file tabs (and history entries) keep loading. keyed by path rather than by tab, since a grant
// belongs to the file and several tabs or history entries can point at it.
final class FileAccessStore {
    static let shared = FileAccessStore()

    private struct Entry: Codable {
        var bookmark: Data
        var lastUsed: Date
    }

    private let defaultsKey = "fileAccessBookmarks"
    private let maxEntries = 500
    private var entries: [String: Entry] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func remember(_ url: URL) {
        guard url.isFileURL, let bookmark = makeBookmark(url) else { return }
        entries[key(url)] = Entry(bookmark: bookmark, lastUsed: Date())
        save()
    }

    // starts security-scoped access to a remembered file and returns its current location (bookmarks
    // follow moves and renames), which the caller must eventually stop accessing. nil when there is
    // no grant for the file.
    func startAccess(_ url: URL) -> URL? {
        let oldKey = key(url)
        guard var entry = entries[oldKey] else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: entry.bookmark, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale
        ) else {
            entries[oldKey] = nil
            save()
            return nil
        }
        guard resolved.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = makeBookmark(resolved) { entry.bookmark = fresh }
        entry.lastUsed = Date()
        entries[oldKey] = nil
        entries[key(resolved)] = entry
        save()
        return resolved
    }

    private func makeBookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func save() {
        if entries.count > maxEntries {
            let keep = entries.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
