import AppKit
import Photos
import WebKit

// "Add to Photos" from the page context menu. The file is fetched through the web view (so it carries the
// page's cookies), quietly: it isn't a download, so there's no flight and no entry in the downloads list.
// Formats Photos can't import are converted first. Saving needs only add-only access to the library.
final class PhotoSaver: NSObject {
    static let shared = PhotoSaver()

    enum Kind {
        case image
        case video
    }

    private struct Fetch {
        let kind: Kind
        var file: URL?
        var suggestedName: String
    }

    private var fetches: [ObjectIdentifier: Fetch] = [:]

    func add(_ url: URL, kind: Kind, from webView: WKWebView) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            self.fetches[ObjectIdentifier(download)] = Fetch(kind: kind, file: nil, suggestedName: url.lastPathComponent)
        }
    }

    private func save(_ file: URL, kind: Kind) {
        Task {
            defer { Self.cleanUp(file) }
            do {
                let prepared = try await Self.importable(file, kind: kind)
                try await Self.addToLibrary(prepared, kind: kind, originalName: file.lastPathComponent)
            } catch {
                Self.report(error.localizedDescription)
            }
        }
    }

    private static func importable(_ file: URL, kind: Kind) async throws -> URL {
        switch kind {
        case .video:
            return try await VideoConversion.photosImportable(file)
        case .image:
            let converted = await Task.detached(priority: .userInitiated) { ImageConversion.photosImportable(file) }.value
            guard let converted else { throw SaveError.unreadableImage }
            return converted
        }
    }

    private static func addToLibrary(_ file: URL, kind: Kind, originalName: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAllowed }
        // the converted copy keeps the original's name, with the extension of what it now is
        let name = (originalName as NSString).deletingPathExtension + "." + file.pathExtension
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                options.originalFilename = name
                request.addResource(with: kind == .image ? .photo : .video, fileURL: file, options: options)
            }
        } catch {
            throw kind == .video ? SaveError.videoRejected : SaveError.imageRejected
        }
    }

    private enum SaveError: LocalizedError {
        case unreadableImage
        case notAllowed
        case imageRejected
        case videoRejected

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                return "This image couldn't be read."
            case .notAllowed:
                return "Dawn doesn't have access to add to Photos. You can allow it in System Settings, under Privacy & Security, Photos."
            case .imageRejected:
                return "Photos couldn't import this image."
            case .videoRejected:
                return "Photos couldn't import this video."
            }
        }
    }

    // every fetch lives in its own temp folder, alongside any converted copy
    private static func cleanUp(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't add to Photos"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension PhotoSaver: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard var fetch = fetches[key] else {
            completionHandler(nil)
            return
        }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? fetch.suggestedName : suggestedFilename
        let file = folder.appendingPathComponent(name.isEmpty ? "media" : name)
        fetch.file = file
        fetches[key] = fetch
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let fetch = fetches.removeValue(forKey: ObjectIdentifier(download)), let file = fetch.file else { return }
        save(file, kind: fetch.kind)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let fetch = fetches.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if let file = fetch.file { Self.cleanUp(file) }
        Self.report(error.localizedDescription)
    }
}
