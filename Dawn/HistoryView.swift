import SwiftUI
import SwiftData

// MARK: - Date Category
enum HistoryDateCategory: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case lastWeek = "Last Week"
    case thisMonth = "This Month"
    case older = "Older"

    static func category(for date: Date) -> HistoryDateCategory {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            return .today
        } else if calendar.isDateInYesterday(date) {
            return .yesterday
        } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                  date >= weekAgo {
            return .thisWeek
        } else if let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: now),
                  date >= twoWeeksAgo {
            return .lastWeek
        } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
                  date >= monthAgo {
            return .thisMonth
        } else {
            return .older
        }
    }

    var sortOrder: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .thisWeek: return 2
        case .lastWeek: return 3
        case .thisMonth: return 4
        case .older: return 5
        }
    }
}

// MARK: - History Row View
struct HistoryRowView: View {
    let entry: HistoryEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var isHovered = false

    private var displayTitle: String {
        entry.title.isEmpty ? cleanURLForDisplay(entry.url) : entry.title
    }

    private func cleanURLForDisplay(_ url: String) -> String {
        var cleaned = url
        if cleaned.hasPrefix("https://") { cleaned = String(cleaned.dropFirst(8)) }
        else if cleaned.hasPrefix("http://") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("www.") { cleaned = String(cleaned.dropFirst(4)) }
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        return cleaned
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: entry.visitedAt)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0 : 0.2), lineWidth: 1)
                )

            // Favicon placeholder
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)

            // Title and URL
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(cleanURLForDisplay(entry.url))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Visit count badge (if > 1)
            if entry.visitCount > 1 {
                Text("\(entry.visitCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }

            // Time
            Text(timeString)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.white.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            // Check for modifier keys
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                onSelect()
            } else {
                onOpen()
            }
        }
    }
}

// MARK: - History Section View
struct HistorySectionView: View {
    let category: HistoryDateCategory
    let entries: [HistoryEntry]
    let selectedIds: Set<UUID>
    let onSelect: (HistoryEntry) -> Void
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            Text(category.rawValue.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            // Entries
            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    HistoryRowView(
                        entry: entry,
                        isSelected: selectedIds.contains(entry.id),
                        onSelect: { onSelect(entry) },
                        onOpen: { onOpen(entry.url) }
                    )
                }
            }
        }
    }
}

// MARK: - History View
struct HistoryView: View {
    @ObservedObject var historyManager: HistoryManager
    let onBack: () -> Void
    let onOpenURL: (String) -> Void

    @State private var searchText = ""
    @State private var selectedIds: Set<UUID> = []
    @State private var lastSelectedEntry: HistoryEntry?
    @State private var allEntries: [HistoryEntry] = []
    @State private var showClearConfirmation = false

    private var filteredEntries: [HistoryEntry] {
        if searchText.isEmpty {
            return allEntries
        }
        let query = searchText.lowercased()
        return allEntries.filter {
            $0.title.lowercased().contains(query) ||
            $0.url.lowercased().contains(query)
        }
    }

    private var groupedEntries: [(HistoryDateCategory, [HistoryEntry])] {
        let grouped = Dictionary(grouping: filteredEntries) { entry in
            HistoryDateCategory.category(for: entry.visitedAt)
        }
        return grouped
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value.sorted { $0.visitedAt > $1.visitedAt }) }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    historyHeader

                    // Search bar
                    searchBar

                    // Content
                    if filteredEntries.isEmpty {
                        emptyState
                    } else {
                        historyList
                    }

                    Spacer(minLength: 80) // Room for selection bar
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 120)
                .padding(.bottom, 32)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
            }

            // Selection actions bar
            if !selectedIds.isEmpty {
                selectionBar
            }
        }
        .onAppear {
            loadEntries()
        }
        .alert("Clear All History", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                historyManager.clearAllHistory()
                loadEntries()
                selectedIds.removeAll()
            }
        } message: {
            Text("This will permanently delete all browsing history. This action cannot be undone.")
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text("Browsing History")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primary)

            Spacer()

            Button(action: { showClearConfirmation = true }) {
                Text("Clear All")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            TextField("Search history...", text: $searchText)
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
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groupedEntries, id: \.0) { category, entries in
                HistorySectionView(
                    category: category,
                    entries: entries,
                    selectedIds: selectedIds,
                    onSelect: { entry in handleSelect(entry) },
                    onOpen: { url in
                        selectedIds.removeAll()
                        onOpenURL(url)
                    }
                )
            }
        }
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text(searchText.isEmpty ? "No browsing history" : "No results found")
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            if !searchText.isEmpty {
                Text("Try a different search term")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var selectionBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                Text("\(selectedIds.count) selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: {
                    selectedIds.removeAll()
                }) {
                    Text("Deselect All")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: {
                    deleteSelected()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("Delete")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
        }
    }

    private func loadEntries() {
        allEntries = historyManager.fetchAll()
    }

    private func handleSelect(_ entry: HistoryEntry) {
        let modifiers = NSEvent.modifierFlags

        if modifiers.contains(.command) {
            // Cmd+click: toggle individual
            if selectedIds.contains(entry.id) {
                selectedIds.remove(entry.id)
            } else {
                selectedIds.insert(entry.id)
            }
            lastSelectedEntry = entry
        } else if modifiers.contains(.shift), let lastEntry = lastSelectedEntry {
            // Shift+click: select range
            guard let lastIndex = filteredEntries.firstIndex(where: { $0.id == lastEntry.id }),
                  let currentIndex = filteredEntries.firstIndex(where: { $0.id == entry.id }) else {
                selectedIds.insert(entry.id)
                lastSelectedEntry = entry
                return
            }

            let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
            for i in range {
                selectedIds.insert(filteredEntries[i].id)
            }
        } else {
            // Regular click with modifier: start selection
            selectedIds = [entry.id]
            lastSelectedEntry = entry
        }
    }

    private func deleteSelected() {
        historyManager.deleteEntries(withIds: selectedIds)
        selectedIds.removeAll()
        lastSelectedEntry = nil
        loadEntries()
    }
}
