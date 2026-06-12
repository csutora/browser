import AppKit
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
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= weekAgo { return .thisWeek }
        if let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: now), date >= twoWeeksAgo { return .lastWeek }
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now), date >= monthAgo { return .thisMonth }
        return .older
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

// MARK: - List Item
private enum HistoryListItem {
    case sectionHeader(String, Int)
    case entry(HistoryEntry)
}

// MARK: - History View Controller
class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let historyManager: HistoryManager
    var onBack: (() -> Void)?
    var onOpenURL: ((String) -> Void)?

    private var allEntries: [HistoryEntry] = []
    private var listItems: [HistoryListItem] = []
    private var selectedIds: Set<UUID> = []
    private var searchText = ""

    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var searchField: NSTextField!
    private var searchContainer: NSView!
    private var backButton: NSButton!
    private var deselectButton: NSButton!
    private var clearButton: NSButton!
    private var columnHeader: NSView!
    private var tableView: HistoryTableView!
    private var tableScrollView: NSScrollView!
    private var emptyLabel: NSTextField!

    private let padH: CGFloat = 24
    private let headerH: CGFloat = 40
    private let columnHeaderH: CGFloat = 28

    init(historyManager: HistoryManager) {
        self.historyManager = historyManager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0).cgColor
        self.view = container

        buildHeader()
        buildTable()
        loadEntries()
    }

    private func buildHeader() {
        headerView = NSView()
        view.addSubview(headerView)

        backButton = NSButton()
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        backButton.contentTintColor = .secondaryLabelColor
        backButton.wantsLayer = true
        backButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        backButton.layer?.cornerRadius = 14
        backButton.target = self
        backButton.action = #selector(backClicked)
        headerView.addSubview(backButton)

        titleLabel = NSTextField(labelWithString: "History")
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .labelColor
        headerView.addSubview(titleLabel)

        // Search field in a rounded container
        searchContainer = NSView()
        searchContainer.wantsLayer = true
        searchContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        searchContainer.layer?.cornerRadius = 8
        searchContainer.layer?.cornerCurve = .continuous
        headerView.addSubview(searchContainer)

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.identifier = NSUserInterfaceItemIdentifier("searchIcon")
        searchContainer.addSubview(searchIcon)

        searchField = NSTextField()
        let searchCell = VerticallyCenteredTextFieldCell()
        searchCell.isEditable = true
        searchCell.isSelectable = true
        searchCell.wraps = false
        searchCell.isScrollable = true
        searchField.cell = searchCell
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = .labelColor
        searchField.stringValue = ""  // a bare NSTextFieldCell() seeds a default "Field" string
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchContainer.addSubview(searchField)

        deselectButton = makeToolbarButton(title: "Deselect", action: #selector(deselectAllClicked))
        headerView.addSubview(deselectButton)

        // Morphs: "Clear All" (no selection → clears all history) / "Clear (N)" (deletes selected).
        clearButton = makeToolbarButton(title: "Clear All", action: #selector(clearButtonClicked), destructive: true)
        headerView.addSubview(clearButton)

        // Column header row (Website | Address)
        columnHeader = NSView()
        let websiteHeader = makeColumnLabel("Website")
        websiteHeader.identifier = NSUserInterfaceItemIdentifier("colWebsite")
        columnHeader.addSubview(websiteHeader)
        let addressHeader = makeColumnLabel("Address")
        addressHeader.identifier = NSUserInterfaceItemIdentifier("colAddress")
        columnHeader.addSubview(addressHeader)
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        sep.identifier = NSUserInterfaceItemIdentifier("colSep")
        columnHeader.addSubview(sep)
        view.addSubview(columnHeader)

        updateSelectionButtons()
    }

    private func buildTable() {
        tableScrollView = NSScrollView()
        tableScrollView.hasVerticalScroller = true
        tableScrollView.scrollerStyle = .overlay
        tableScrollView.drawsBackground = false
        tableScrollView.autohidesScrollers = true
        view.addSubview(tableScrollView)

        tableView = HistoryTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.rowHeight = 36
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)

        let website = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("website"))
        website.isEditable = false
        website.resizingMask = .autoresizingMask
        tableView.addTableColumn(website)
        let address = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("address"))
        address.isEditable = false
        address.resizingMask = .autoresizingMask
        tableView.addTableColumn(address)

        tableScrollView.documentView = tableView

        tableView.onDeleteKey = { [weak self] in self?.deleteSelected() }
        tableView.onReturnKey = { [weak self] in self?.openSelectedEntries() }
        tableView.onEscapeKey = { [weak self] in self?.deselectAll() }
        tableView.onSelectAllKey = { [weak self] in self?.selectAllEntries() }
        tableView.onCopyKey = { [weak self] in self?.copySelectedToClipboard() }

        emptyLabel = NSTextField(labelWithString: "No browsing history")
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)
    }

    // MARK: - Layout

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width
        let h = view.bounds.height
        let contentW = w - padH * 2

        // Single header row, top inset equal to the side inset (padH).
        let headerY = h - padH - headerH
        headerView.frame = NSRect(x: padH, y: headerY, width: contentW, height: headerH)
        let hb = headerView.bounds

        // Back button + title on the left, vertically centered.
        let backSize: CGFloat = 28
        backButton.frame = NSRect(x: 0, y: (hb.height - backSize) / 2, width: backSize, height: backSize)
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: backSize + 12, y: (hb.height - 34) / 2, width: 300, height: 34)

        // Right side: search (rightmost), then Clear, then Deselect.
        let searchW: CGFloat = 260
        let fieldH: CGFloat = 32
        searchContainer.frame = NSRect(x: hb.width - searchW, y: (hb.height - fieldH) / 2, width: searchW, height: fieldH)
        if let icon = searchContainer.subviews.first(where: { $0.identifier?.rawValue == "searchIcon" }) {
            icon.frame = NSRect(x: 10, y: (fieldH - 16) / 2, width: 16, height: 16)
        }
        searchField.frame = NSRect(x: 34, y: 0, width: searchW - 44, height: fieldH)

        let btnH: CGFloat = 30
        let btnY = (hb.height - btnH) / 2
        clearButton.sizeToFit()
        deselectButton.sizeToFit()
        let clearW = clearButton.frame.width + 24
        let deselW = deselectButton.frame.width + 24
        let gap: CGFloat = 8
        let clearX = searchContainer.frame.minX - gap - clearW
        clearButton.frame = NSRect(x: clearX, y: btnY, width: clearW, height: btnH)
        deselectButton.frame = NSRect(x: clearX - gap - deselW, y: btnY, width: deselW, height: btnH)

        // Column header
        let colY = headerY - 16 - columnHeaderH
        columnHeader.frame = NSRect(x: padH, y: colY, width: contentW, height: columnHeaderH)
        let websiteColW = (contentW * 0.45).rounded()
        if let wl = columnHeader.subviews.first(where: { $0.identifier?.rawValue == "colWebsite" }) {
            wl.frame = NSRect(x: 12, y: 4, width: websiteColW - 12, height: 18)
        }
        if let al = columnHeader.subviews.first(where: { $0.identifier?.rawValue == "colAddress" }) {
            al.frame = NSRect(x: websiteColW + 12, y: 4, width: contentW - websiteColW - 12, height: 18)
        }
        if let sep = columnHeader.subviews.first(where: { $0.identifier?.rawValue == "colSep" }) {
            sep.frame = NSRect(x: 0, y: 0, width: contentW, height: 1)
        }

        // Table fills the rest
        tableScrollView.frame = NSRect(x: padH, y: 0, width: contentW, height: max(0, colY))
        if tableView.tableColumns.count == 2 {
            tableView.tableColumns[0].width = websiteColW
            tableView.tableColumns[1].width = contentW - websiteColW
        }

        emptyLabel.sizeToFit()
        emptyLabel.frame = NSRect(x: padH, y: colY / 2, width: contentW, height: 20)
    }

    // MARK: - Data

    private func loadEntries() {
        let words = searchText.lowercased().split(separator: " ").map(String.init)
        if words.isEmpty {
            allEntries = historyManager.fetchAll()
        } else {
            // Each space-separated word must appear in the title OR the address; all words must
            // match. "launch time element" keeps entries containing all three across both fields.
            allEntries = historyManager.fetchAll().filter { entry in
                let haystack = (entry.title + " " + entry.url).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
        }

        let grouped = Dictionary(grouping: allEntries) { HistoryDateCategory.category(for: $0.visitedAt) }
        let sortedGroups = grouped
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value.sorted { $0.visitedAt > $1.visitedAt }) }

        listItems = []
        for (category, entries) in sortedGroups {
            listItems.append(.sectionHeader(category.rawValue, entries.count))
            for entry in entries { listItems.append(.entry(entry)) }
        }

        let isEmpty = allEntries.isEmpty
        tableScrollView.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
        emptyLabel.stringValue = searchText.isEmpty ? "No browsing history" : "No results found"

        tableView.reloadData()
        selectedIds.removeAll()
        updateSelectionButtons()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { listItems.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch listItems[row] {
        case .sectionHeader: return 34
        case .entry: return 36
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .sectionHeader = listItems[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry = listItems[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return HistoryRowView()
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let hr = rowView as? HistoryRowView else { return }
        hr.row = row
        hr.table = tableView
        hr.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch listItems[row] {
        case .sectionHeader(let title, let count):
            return makeSectionHeaderCell(title, count: count)
        case .entry(let entry):
            let colId = tableColumn?.identifier.rawValue ?? "website"
            return colId == "website" ? makeWebsiteCell(entry) : makeAddressCell(entry)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIds.removeAll()
        tableView.selectedRowIndexes.forEach { row in
            if case .entry(let entry) = listItems[row] { selectedIds.insert(entry.id) }
        }
        updateSelectionButtons()
        // Redraw all visible rows so each block's outer corners recompute immediately.
        tableView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    // MARK: - Cells

    private func makeSectionHeaderCell(_ title: String, count: Int) -> NSView {
        let cell = NSView()
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 12, y: 11, width: 300, height: 14)
        cell.addSubview(label)

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = .systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        countLabel.sizeToFit()
        countLabel.identifier = NSUserInterfaceItemIdentifier("count")
        cell.addSubview(countLabel)

        cell.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: cell, queue: .main) { [weak cell] _ in
            guard let cell = cell, let cl = cell.subviews.first(where: { $0.identifier?.rawValue == "count" }) else { return }
            cl.frame.origin = NSPoint(x: cell.frame.width - cl.frame.width - 12, y: 11)
        }
        return cell
    }

    private func makeWebsiteCell(_ entry: HistoryEntry) -> NSView {
        let cell = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 12, y: 9, width: 18, height: 18)
        cell.addSubview(icon)

        let title = entry.title.isEmpty ? cleanURL(entry.url) : entry.title
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.identifier = NSUserInterfaceItemIdentifier("title")
        cell.addSubview(label)

        cell.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: cell, queue: .main) { [weak cell] _ in
            guard let cell = cell, let l = cell.subviews.first(where: { $0.identifier?.rawValue == "title" }) else { return }
            l.frame = NSRect(x: 40, y: (cell.frame.height - 16) / 2, width: max(20, cell.frame.width - 52), height: 16)
        }
        return cell
    }

    private func makeAddressCell(_ entry: HistoryEntry) -> NSView {
        let cell = NSView()
        let label = NSTextField(labelWithString: entry.url)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.identifier = NSUserInterfaceItemIdentifier("url")
        cell.addSubview(label)

        cell.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: cell, queue: .main) { [weak cell] _ in
            guard let cell = cell, let l = cell.subviews.first(where: { $0.identifier?.rawValue == "url" }) else { return }
            l.frame = NSRect(x: 12, y: (cell.frame.height - 16) / 2, width: max(20, cell.frame.width - 24), height: 16)
        }
        return cell
    }

    // MARK: - Header helpers

    private func makeToolbarButton(title: String, action: Selector, destructive: Bool = false) -> NSButton {
        let btn = NSButton()
        btn.isBordered = false
        btn.title = title
        btn.font = .systemFont(ofSize: 12, weight: .medium)
        btn.contentTintColor = destructive ? .systemRed : .secondaryLabelColor
        btn.wantsLayer = true
        btn.layer?.backgroundColor = (destructive ? NSColor.systemRed : NSColor.white).withAlphaComponent(destructive ? 0.12 : 0.08).cgColor
        btn.layer?.cornerRadius = 7
        btn.layer?.cornerCurve = .continuous
        btn.target = self
        btn.action = action
        return btn
    }

    private func makeColumnLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func updateSelectionButtons() {
        let has = !selectedIds.isEmpty
        deselectButton.isEnabled = has
        deselectButton.alphaValue = has ? 1.0 : 0.4
        clearButton.title = has ? "Clear (\(selectedIds.count))" : "Clear All"
        view.needsLayout = true
    }

    // MARK: - Actions

    @objc private func backClicked() { onBack?() }

    @objc private func clearButtonClicked() {
        if selectedIds.isEmpty {
            clearAll()
        } else {
            deleteSelected()
        }
    }

    private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear All History"
        alert.informativeText = "This will permanently delete all browsing history. This action cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear All")
        alert.alertStyle = .warning
        if alert.runModal() == .alertSecondButtonReturn {
            historyManager.clearAllHistory()
            selectedIds.removeAll()
            loadEntries()
        }
    }

    @objc private func deselectAllClicked() { deselectAll() }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, case .entry(let entry) = listItems[row] else { return }
        onOpenURL?(entry.url)
    }

    private func openSelectedEntries() {
        guard !selectedIds.isEmpty else { return }
        for item in listItems {
            if case .entry(let entry) = item, selectedIds.contains(entry.id) { onOpenURL?(entry.url) }
        }
        deselectAll()
    }

    private func selectAllEntries() {
        let indexes = NSMutableIndexSet()
        for (i, item) in listItems.enumerated() {
            if case .entry = item { indexes.add(i) }
        }
        tableView.selectRowIndexes(indexes as IndexSet, byExtendingSelection: false)
    }

    private func deselectAll() {
        selectedIds.removeAll()
        tableView.deselectAll(nil)
        updateSelectionButtons()
    }

    private func deleteSelected() {
        guard !selectedIds.isEmpty else { return }
        historyManager.deleteEntries(withIds: selectedIds)
        selectedIds.removeAll()
        loadEntries()
    }

    /// Copy selected entries to the clipboard as newline-separated markdown links, in list order.
    private func copySelectedToClipboard() {
        guard !selectedIds.isEmpty else { return }
        var lines: [String] = []
        for item in listItems {
            if case .entry(let entry) = item, selectedIds.contains(entry.id) {
                let title = entry.title.isEmpty ? entry.url : entry.title
                lines.append("[\(title)](\(entry.url))")
            }
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        searchText = searchField.stringValue
        selectedIds.removeAll()
        loadEntries()
    }

    // MARK: - Helpers

    private func cleanURL(_ url: String) -> String {
        var cleaned = url
        if cleaned.hasPrefix("https://") { cleaned = String(cleaned.dropFirst(8)) }
        else if cleaned.hasPrefix("http://") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("www.") { cleaned = String(cleaned.dropFirst(4)) }
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        return cleaned
    }
}

// MARK: - Custom Table View (key handling)
private class HistoryTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    var onEscapeKey: (() -> Void)?
    var onSelectAllKey: (() -> Void)?
    var onCopyKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDeleteKey?()
        case 36: onReturnKey?()
        case 53: onEscapeKey?()
        case 0 where event.modifierFlags.contains(.command): onSelectAllKey?()
        case 8 where event.modifierFlags.contains(.command): onCopyKey?()
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Custom Row View (block-rounded selection)
private class HistoryRowView: NSTableRowView {
    var row = -1
    weak var table: NSTableView?

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, let table = table, row >= 0 else { return }
        // Compute block position live (from the current selection) so rounding is correct
        // immediately and survives scrolling/row reuse.
        let isTop = !table.isRowSelected(row - 1)
        let isBottom = !table.isRowSelected(row + 1)

        let radius: CGFloat = 6
        var rect = bounds
        // Extend past the bounds on the connecting sides so that rounding gets clipped, giving a
        // continuous block whose only rounded corners are the block's outer top/bottom.
        if !isTop { rect.size.height += radius; rect.origin.y -= radius }
        if !isBottom { rect.size.height += radius }

        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set { }
    }
}
