import AppKit
import Combine
import WebKit

// MARK: - Download Item

final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case preparing
        case downloading
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool { self == .preparing || self == .downloading }
    }

    let id = UUID()
    let sourceURL: URL?
    let pageURL: URL?
    let startedAt = Date()

    @Published fileprivate(set) var state: State = .preparing
    @Published fileprivate(set) var filename: String
    @Published fileprivate(set) var receivedBytes: Int64 = 0
    @Published fileprivate(set) var totalBytes: Int64 = -1
    @Published fileprivate(set) var bytesPerSecond: Double = 0
    @Published fileprivate(set) var finalURL: URL?

    fileprivate var download: WKDownload?
    fileprivate var partialURL: URL?
    // a destination picked in a save panel, which replaces the automatic downloads-folder naming
    fileprivate var chosenURL: URL?
    fileprivate var resumeData: Data?
    fileprivate var userCancelled = false
    fileprivate var lastSampleBytes: Int64 = 0
    fileprivate var lastSampleTime: CFTimeInterval = 0

    fileprivate init(sourceURL: URL?, pageURL: URL?, filename: String) {
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.filename = filename
    }

    var hasKnownSize: Bool { totalBytes > 0 }

    var fractionCompleted: Double {
        guard hasKnownSize else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var secondsRemaining: Double? {
        guard state == .downloading, hasKnownSize, bytesPerSecond > 1 else { return nil }
        return Double(max(0, totalBytes - receivedBytes)) / bytesPerSecond
    }

    var canRetry: Bool {
        switch state {
        case .failed, .cancelled: return sourceURL != nil || resumeData != nil
        default: return false
        }
    }

    var fileExists: Bool {
        guard let finalURL else { return false }
        return FileManager.default.fileExists(atPath: finalURL.path)
    }
}

// MARK: - Download Manager

// app-wide owner of every download in this session. the list is deliberately session-only: the
// sidebar indicator appears with the first download and hides again after a relaunch.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    enum Event {
        // the web view that started it; a window claims the flight by owning that web view, since the
        // view isn't always in a window (background tabs, mid-transition)
        case started(DownloadItem, sourceWebView: WKWebView?)
        case finished(DownloadItem)
        case failed(DownloadItem)
    }

    struct Aggregate: Equatable {
        var activeCount = 0
        // nil while every active download has an unknown size
        var fraction: Double?
    }

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var hasSessionDownloads = false
    @Published private(set) var hasUnseenCompletion = false
    @Published private(set) var hasUnseenFailure = false
    @Published private(set) var aggregate = Aggregate()

    let events = PassthroughSubject<Event, Never>()

    private var itemsByDownload: [ObjectIdentifier: DownloadItem] = [:]
    private var pendingRestarts: [ObjectIdentifier: DownloadItem] = [:]
    private var chosenDestinations: [ObjectIdentifier: URL] = [:]
    private var progressTimer: Timer?
    private lazy var restartWebView = WKWebView(frame: .zero, configuration: BrowserState.makeConfiguration())

    var activeItems: [DownloadItem] { items.filter { $0.state.isActive } }

    // MARK: Registration

    func register(_ download: WKDownload, from webView: WKWebView?) {
        download.delegate = self
        if let item = pendingRestarts.removeValue(forKey: ObjectIdentifier(download)) {
            attach(download, to: item)
            return
        }
        let source = download.originalRequest?.url
        // a download never commits its navigation, so the page it came from is still the current
        // back/forward entry (webView.url may already point at the file)
        let item = DownloadItem(
            sourceURL: source,
            pageURL: webView?.backForwardList.currentItem?.url ?? webView?.url,
            filename: source.map { Self.fallbackFilename(for: $0) } ?? "Download"
        )
        item.chosenURL = chosenDestinations.removeValue(forKey: ObjectIdentifier(download))
        attach(download, to: item)
        items.insert(item, at: 0)
        // announce before publishing state: a window launching a flight must register it with its
        // indicator first, so the button reacts when the badge lands rather than ahead of it
        events.send(.started(item, sourceWebView: webView))
        hasSessionDownloads = true
        refreshAggregate()
    }

    private func attach(_ download: WKDownload, to item: DownloadItem) {
        item.download = download
        item.userCancelled = false
        item.state = .preparing
        item.lastSampleBytes = item.receivedBytes
        item.lastSampleTime = CACurrentMediaTime()
        itemsByDownload[ObjectIdentifier(download)] = item
        startProgressTimer()
    }

    // MARK: Starting downloads

    // downloads started from the browser itself (context menus), rather than by a page navigation
    func startDownload(_ url: URL, from webView: WKWebView, to destination: URL? = nil) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self, weak webView] download in
            guard let self else { return }
            if let destination { self.chosenDestinations[ObjectIdentifier(download)] = destination }
            self.register(download, from: webView)
        }
    }

    func saveAs(_ url: URL, suggestedName: String?, from webView: WKWebView) {
        let panel = NSSavePanel()
        let fallback = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? (url.host ?? "Download") : url.lastPathComponent
        panel.nameFieldStringValue = Self.sanitized(suggestedName?.isEmpty == false ? suggestedName! : fallback)
        panel.directoryURL = Self.downloadsDirectory
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self, weak webView] response in
            guard response == .OK, let destination = panel.url, let self, let webView else { return }
            self.startDownload(url, from: webView, to: destination)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: User actions

    func cancel(_ item: DownloadItem) {
        guard item.state.isActive, let download = item.download else { return }
        item.userCancelled = true
        download.cancel { [weak self, weak item] data in
            DispatchQueue.main.async {
                guard let self, let item else { return }
                item.resumeData = data
                self.finishCancel(item)
            }
        }
    }

    private func finishCancel(_ item: DownloadItem) {
        guard item.state.isActive else { return }
        if let download = item.download { itemsByDownload[ObjectIdentifier(download)] = nil }
        item.download = nil
        item.state = .cancelled
        item.bytesPerSecond = 0
        refreshAggregate()
    }

    func retry(_ item: DownloadItem) {
        guard item.canRetry else { return }
        item.state = .preparing
        refreshAggregate()
        if let data = item.resumeData {
            item.resumeData = nil
            restartWebView.resumeDownload(fromResumeData: data) { [weak self] download in
                self?.adoptRestart(download, for: item)
            }
        } else if let source = item.sourceURL {
            removePartial(of: item)
            item.receivedBytes = 0
            item.totalBytes = -1
            restartWebView.startDownload(using: URLRequest(url: source)) { [weak self] download in
                self?.adoptRestart(download, for: item)
            }
        }
    }

    private func adoptRestart(_ download: WKDownload, for item: DownloadItem) {
        download.delegate = self
        attach(download, to: item)
        item.state = .downloading
        refreshAggregate()
    }

    func remove(_ item: DownloadItem) {
        guard !item.state.isActive else { return }
        removePartial(of: item)
        items.removeAll { $0 === item }
    }

    func clearInactive() {
        for item in items where !item.state.isActive { removePartial(of: item) }
        items.removeAll { !$0.state.isActive }
    }

    func markSeen() {
        hasUnseenCompletion = false
        hasUnseenFailure = false
    }

    // a cleared list ends the session: the sidebar button goes away until the next download
    func endSessionIfEmpty() {
        guard items.isEmpty, hasSessionDownloads else { return }
        hasSessionDownloads = false
    }

    func open(_ item: DownloadItem) {
        guard item.state == .finished, let url = item.finalURL, item.fileExists else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: DownloadItem) {
        if let url = item.finalURL, item.fileExists {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openDownloadsFolder()
        }
    }

    func openDownloadsFolder() {
        if let dir = Self.downloadsDirectory { NSWorkspace.shared.open(dir) }
    }

    // partial files only make sense while this session can still resume them
    func discardPartialFiles() {
        for item in items where item.state != .finished { removePartial(of: item) }
    }

    private func removePartial(of item: DownloadItem) {
        guard item.state != .finished, let partial = item.partialURL else { return }
        try? FileManager.default.removeItem(at: partial)
        item.partialURL = nil
        item.resumeData = nil
    }

    // MARK: Progress

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func sampleProgress() {
        let now = CACurrentMediaTime()
        for item in items where item.state.isActive {
            guard let progress = item.download?.progress else { continue }
            let total = progress.totalUnitCount
            let received = progress.completedUnitCount
            if total > 0, item.totalBytes != total { item.totalBytes = total }
            if received != item.receivedBytes { item.receivedBytes = received }
            if received > 0, item.state == .preparing { item.state = .downloading }

            let dt = now - item.lastSampleTime
            if dt >= 0.5 {
                let rate = Double(received - item.lastSampleBytes) / dt
                item.bytesPerSecond = item.bytesPerSecond == 0 ? rate : item.bytesPerSecond * 0.7 + rate * 0.3
                item.lastSampleBytes = received
                item.lastSampleTime = now
            }
        }
        refreshAggregate()
        if activeItems.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func refreshAggregate() {
        let active = activeItems
        let known = active.filter { $0.hasKnownSize }
        var next = Aggregate(activeCount: active.count, fraction: nil)
        if !known.isEmpty {
            let total = known.reduce(Int64(0)) { $0 + $1.totalBytes }
            let received = known.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
            next.fraction = total > 0 ? Double(received) / Double(total) : 0
        }
        if next != aggregate { aggregate = next }
    }

    // MARK: Files

    static var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private static func fallbackFilename(for url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? "Download") : last
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "Download" : trimmed
    }

    // a free name in the folder, also keeping clear of names reserved by other in-flight downloads
    private func uniqueURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let reserved = Set(items.compactMap { item -> String? in
            guard item.state.isActive, item.partialURL != nil else { return nil }
            return item.finalURL?.lastPathComponent
        })
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = filename
        var counter = 1
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path)
            || fm.fileExists(atPath: directory.appendingPathComponent(candidate + ".part").path)
            || reserved.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    private func finalize(_ item: DownloadItem) {
        guard let partial = item.partialURL, let planned = item.finalURL else { return }
        let fm = FileManager.default
        var destination = planned
        if item.chosenURL != nil {
            // the save panel already asked about replacing an existing file
            try? fm.removeItem(at: destination)
        } else if fm.fileExists(atPath: destination.path) {
            item.finalURL = nil
            destination = uniqueURL(for: planned.lastPathComponent, in: planned.deletingLastPathComponent())
        }
        do {
            try fm.moveItem(at: partial, to: destination)
            item.finalURL = destination
            item.partialURL = nil
            item.filename = destination.lastPathComponent
        } catch {
            item.finalURL = partial
            item.partialURL = nil
        }
        if let url = item.finalURL {
            Self.recordOrigin(of: url, source: item.sourceURL, page: item.pageURL)
            // lets the downloads stack in the dock do its finish bounce, like other browsers
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: url.path
            )
        }
    }

    // a few words that fit the panel's status line; system descriptions are full sentences
    private static func shortReason(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return "Failed" }
        switch nsError.code {
        case NSURLErrorNetworkConnectionLost: return "Connection lost"
        case NSURLErrorNotConnectedToInternet: return "No internet connection"
        case NSURLErrorTimedOut: return "Timed out"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Server not found"
        case NSURLErrorCannotConnectToHost: return "Couldn't connect"
        case NSURLErrorBadServerResponse: return "Bad server response"
        case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile: return "Couldn't save the file"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot: return "Secure connection failed"
        default: return "Failed"
        }
    }

    // finder's "where from" metadata
    private static func recordOrigin(of file: URL, source: URL?, page: URL?) {
        var origins: [String] = []
        for url in [source, page].compactMap({ $0?.absoluteString })
        where !url.hasPrefix("blob:") && !url.hasPrefix("data:") && !origins.contains(url) {
            origins.append(url)
        }
        guard !origins.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: origins, format: .binary, options: 0)
        else { return }
        _ = data.withUnsafeBytes { buffer in
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", buffer.baseAddress, buffer.count, 0, 0)
        }
    }
}

// MARK: - WKDownloadDelegate

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let item = itemsByDownload[ObjectIdentifier(download)], let dir = Self.downloadsDirectory else {
            completionHandler(nil)
            return
        }
        let finalURL: URL
        let partialURL: URL
        if let chosen = item.chosenURL {
            // the save panel grants exactly the chosen file, so the partial goes in the app's temp dir
            finalURL = chosen
            partialURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("part")
        } else {
            finalURL = uniqueURL(for: Self.sanitized(suggestedFilename), in: dir)
            partialURL = finalURL.appendingPathExtension("part")
        }
        item.filename = finalURL.lastPathComponent
        item.finalURL = finalURL
        item.partialURL = partialURL
        if response.expectedContentLength > 0 { item.totalBytes = response.expectedContentLength }
        item.state = .downloading
        refreshAggregate()
        completionHandler(partialURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = itemsByDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if item.hasKnownSize { item.receivedBytes = item.totalBytes }
        finalize(item)
        item.download = nil
        item.bytesPerSecond = 0
        item.state = .finished
        hasUnseenCompletion = true
        refreshAggregate()
        events.send(.finished(item))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = itemsByDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.download = nil
        item.bytesPerSecond = 0
        if let resumeData { item.resumeData = resumeData }
        if item.userCancelled || (error as NSError).code == NSURLErrorCancelled {
            item.state = .cancelled
            refreshAggregate()
            return
        }
        item.state = .failed(Self.shortReason(for: error))
        hasUnseenFailure = true
        refreshAggregate()
        events.send(.failed(item))
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(.allow)
    }
}

// MARK: - Formatting

enum DownloadFormat {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ value: Int64) -> String { bytes.string(fromByteCount: value) }

    static func remaining(_ seconds: Double) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "\(Int(seconds.rounded())) sec left" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min left" }
        let hours = seconds / 3600
        return hours < 10 ? String(format: "%.1f hr left", hours) : "\(Int(hours.rounded())) hr left"
    }

    static func status(for item: DownloadItem) -> String {
        switch item.state {
        case .preparing:
            return "Starting..."
        case .downloading:
            var parts: [String] = []
            if item.hasKnownSize {
                parts.append("\(size(item.receivedBytes)) of \(size(item.totalBytes))")
                if let left = item.secondsRemaining { parts.append(remaining(left)) }
            } else {
                parts.append(size(item.receivedBytes))
                if item.bytesPerSecond > 1 { parts.append("\(size(Int64(item.bytesPerSecond)))/s") }
            }
            return parts.joined(separator: " \u{00B7} ")
        case .finished:
            if !item.fileExists { return "Moved or deleted" }
            var parts = [size(item.hasKnownSize ? item.totalBytes : item.receivedBytes)]
            if let host = (item.pageURL ?? item.sourceURL)?.host { parts.append(host) }
            return parts.joined(separator: " \u{00B7} ")
        case .failed(let reason):
            guard item.receivedBytes > 0 else { return reason }
            let progress = item.hasKnownSize
                ? "\(size(item.receivedBytes)) of \(size(item.totalBytes))"
                : size(item.receivedBytes)
            return "\(reason) \u{00B7} \(progress)"
        case .cancelled:
            return item.receivedBytes > 0 ? "Stopped at \(size(item.receivedBytes))" : "Stopped"
        }
    }
}
