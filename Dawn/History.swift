import SwiftData
import Foundation
import Combine

// MARK: - History Entry Model
@Model
final class HistoryEntry: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var url: String
    var visitedAt: Date
    var visitCount: Int
    // the page's icon in the icon store
    var iconKey: String?

    /// Frecency score: balances frequency (visit count) with recency
    /// Higher scores for frequently visited and recently visited pages
    var frecencyScore: Double {
        let daysSinceVisit = Date().timeIntervalSince(visitedAt) / (24 * 60 * 60)
        // Recency weight decays over 30 days from 1.0 to 0.5
        let recencyWeight = max(0.5, 1.0 - (daysSinceVisit / 60.0))
        return Double(visitCount) * recencyWeight
    }

    init(title: String, url: String) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.visitedAt = Date()
        self.visitCount = 1
    }
}

// MARK: - History Manager
class HistoryManager: ObservableObject {
    var modelContext: ModelContext?

    // Normalize URL (remove trailing slash for consistency)
    private static func normalized(_ url: String) -> String {
        url.hasSuffix("/") && url.count > 1 ? String(url.dropLast()) : url
    }

    private func entry(for url: String) -> HistoryEntry? {
        let normalizedURL = Self.normalized(url)
        return try? modelContext?.fetch(FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.url == normalizedURL })).first
    }

    /// Records a page visit, updating existing entry or creating new one
    func recordVisit(title: String, url: String, iconKey: String?) {
        guard let context = modelContext else { return }

        if let existing = entry(for: url) {
            existing.visitCount += 1
            existing.visitedAt = Date()
            if !title.isEmpty && title != existing.title {
                existing.title = title
            }
            if let iconKey { existing.iconKey = iconKey }
        } else {
            let entry = HistoryEntry(title: title, url: Self.normalized(url))
            entry.iconKey = iconKey
            context.insert(entry)
        }

        try? context.save()
    }

    // the icon a page was last seen with
    func iconKey(for url: String) -> String? {
        entry(for: url)?.iconKey
    }

    func setIconKey(_ iconKey: String?, for url: String) {
        guard let entry = entry(for: url), entry.iconKey != iconKey else { return }
        entry.iconKey = iconKey
        try? modelContext?.save()
    }

    func iconKeys() -> Set<String> {
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.iconKey != nil })
        descriptor.propertiesToFetch = [\.iconKey]
        return Set(((try? modelContext?.fetch(descriptor)) ?? []).compactMap(\.iconKey))
    }

    /// Searches history by title or URL, returning results sorted by relevance
    /// Prioritizes prefix matches over contains matches
    func search(query: String, limit: Int = 20) -> [HistoryEntry] {
        guard let context = modelContext, !query.isEmpty else { return [] }
        let queryLower = query.lowercased()

        let descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )

        guard let all = try? context.fetch(descriptor) else { return [] }

        // Filter and score entries
        let scored = all.compactMap { entry -> (HistoryEntry, Double)? in
            let titleLower = entry.title.lowercased()
            let urlLower = entry.url.lowercased()
            // Clean URL for matching (remove protocol)
            let cleanedURL = urlLower
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")

            var matchScore: Double = 0

            // Prefix matches get highest priority (10x boost)
            if cleanedURL.hasPrefix(queryLower) || urlLower.hasPrefix(queryLower) {
                matchScore = 10.0
            } else if titleLower.hasPrefix(queryLower) {
                matchScore = 8.0
            }
            // Contains matches get lower priority
            else if cleanedURL.contains(queryLower) || urlLower.contains(queryLower) {
                matchScore = 1.0
            } else if titleLower.contains(queryLower) {
                matchScore = 0.5
            } else {
                return nil // No match
            }

            // Combine match score with frecency
            let totalScore = matchScore * entry.frecencyScore
            return (entry, totalScore)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Fetches all history entries, optionally filtered by date range
    func fetchAll(from startDate: Date? = nil, to endDate: Date? = nil) -> [HistoryEntry] {
        guard let context = modelContext else { return [] }

        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )

        if let start = startDate, let end = endDate {
            descriptor.predicate = #Predicate {
                $0.visitedAt >= start && $0.visitedAt <= end
            }
        } else if let start = startDate {
            descriptor.predicate = #Predicate { $0.visitedAt >= start }
        } else if let end = endDate {
            descriptor.predicate = #Predicate { $0.visitedAt <= end }
        }

        return (try? context.fetch(descriptor)) ?? []
    }

    /// Deletes specific history entries
    func deleteEntries(_ entries: [HistoryEntry]) {
        guard let context = modelContext else { return }
        for entry in entries {
            context.delete(entry)
        }
        try? context.save()
        IconStore.shared.collectGarbage()
    }

    /// Deletes entries by their IDs
    func deleteEntries(withIds ids: Set<UUID>) {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<HistoryEntry>()
        guard let all = try? context.fetch(descriptor) else { return }

        for entry in all where ids.contains(entry.id) {
            context.delete(entry)
        }
        try? context.save()
        IconStore.shared.collectGarbage()
    }

    /// Deletes all history entries within a date range
    func deleteEntriesInRange(from startDate: Date, to endDate: Date) {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate {
                $0.visitedAt >= startDate && $0.visitedAt <= endDate
            }
        )

        guard let entries = try? context.fetch(descriptor) else { return }

        for entry in entries {
            context.delete(entry)
        }
        try? context.save()
        IconStore.shared.collectGarbage()
    }

    /// Clears all browsing history
    func clearAllHistory() {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<HistoryEntry>()
        guard let all = try? context.fetch(descriptor) else { return }

        for entry in all {
            context.delete(entry)
        }
        try? context.save()
        IconStore.shared.collectGarbage()
    }
}
