import AppKit
import WebKit

struct ContextMenuActions {
    let webView: WKWebView
    let openInNewTab: (URL) -> Void
    let openInNewWindow: (URL) -> Void
}

// Builds Dawn's page context menus from webkit's proposed menu, in Safari's shape. Webkit's own items are
// kept wherever they exist (copy link, copy image, share, inspect element, media playback), so they bring
// their icons and native behavior; the rest are Dawn's.
enum ContextMenuBuilder {
    private enum WK {
        static let copyLink = "WKMenuItemIdentifierCopyLink"
        static let copyImage = "WKMenuItemIdentifierCopyImage"
        static let share = "WKMenuItemIdentifierShareMenu"
        static let inspect = "WKMenuItemIdentifierInspectElement"
        static let mediaControls = "WKMenuItemIdentifierShowHideMediaControls"
        static let pictureInPicture = "WKMenuItemIdentifierTogglePictureInPicture"
        static let fullScreen = "WKMenuItemIdentifierToggleFullScreen"
        static let videoViewer = "WKMenuItemIdentifierToggleVideoViewer"

        // items Dawn replaces with its own versions
        static let replaced: Set<String> = [
            "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenMediaInNewWindow",
            "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierCopyMediaLink",
        ]
    }

    private struct Target {
        var link: URL?
        var linkFilename: String?
        var image: URL?
        var imageFilename: String?
        var media: URL?
        var isVideo = false
    }

    static func menu(from proposed: NSMenu, element: NSObject, actions: ContextMenuActions) -> NSMenu {
        let target = readTarget(element)
        guard target.link != nil || target.image != nil || target.media != nil else { return proposed }

        var proposedItems: [String: NSMenuItem] = [:]
        for item in proposed.items {
            if let id = item.identifier?.rawValue { proposedItems[id] = item }
        }
        var used = Set<String>()
        func take(_ id: String) -> NSMenuItem? {
            guard let item = proposedItems[id] else { return nil }
            used.insert(id)
            proposed.removeItem(item)
            return item
        }

        let manager = DownloadManager.shared
        let webView = actions.webView
        var sections: [[NSMenuItem]] = []

        // every target gets the same shape: open, download (plus photos for images and video), copy
        func open(_ noun: String, _ url: URL) -> [NSMenuItem] {
            [
                item("Open \(noun) in New Tab") { actions.openInNewTab(url) },
                item("Open \(noun) in New Window") { actions.openInNewWindow(url) },
            ]
        }
        func download(_ noun: String, _ url: URL, _ name: String?, photos: PhotoSaver.Kind?) -> [NSMenuItem] {
            guard isFetchable(url) else { return [] }
            var items = [
                item("Download \(noun)") { manager.startDownload(url, from: webView) },
                item("Download \(noun) As\u{2026}") { manager.saveAs(url, suggestedName: name, from: webView) },
            ]
            if let photos {
                items.append(item("Add to Photos") { PhotoSaver.shared.add(url, kind: photos, from: webView) })
            }
            return items
        }

        if let link = target.link {
            sections.append(open("Link", link))
            sections.append(download("Linked File", link, target.linkFilename, photos: nil))
            sections.append([take(WK.copyLink) ?? item("Copy Link") { copy(link) }])
        }

        if let image = target.image {
            sections.append(open("Image", image))
            sections.append(download("Image", image, target.imageFilename, photos: .image))
            sections.append([item("Copy Image Address") { copy(image) }] + [take(WK.copyImage)].compactMap { $0 })
        }

        if let media = target.media {
            let noun = target.isVideo ? "Video" : "Audio"
            let playback = [WK.mediaControls, WK.pictureInPicture, WK.videoViewer, WK.fullScreen].compactMap { take($0) }
            sections.append(playback)
            sections.append(open(noun, media))
            sections.append(download(noun, media, nil, photos: target.isVideo ? .video : nil))
            sections.append([item("Copy \(noun) Address") { copy(media) }])
        }

        // whatever else webkit proposed for this element (look up, translate, text items when the link
        // is selected, and so on), in its original order
        let share = take(WK.share)
        let inspect = take(WK.inspect)
        let rest = proposed.items.filter { item in
            guard !item.isSeparatorItem else { return false }
            if let id = item.identifier?.rawValue, WK.replaced.contains(id) || used.contains(id) { return false }
            return true
        }
        rest.forEach { proposed.removeItem($0) }
        if !rest.isEmpty { sections.append(rest) }
        if let share { sections.append([share]) }
        if let inspect { sections.append([inspect]) }

        let menu = NSMenu()
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach { menu.addItem($0) }
        }
        return menu
    }

    // the hit test is private webkit api, so every property is checked before it's read; a missing
    // one just leaves that part of the menu out instead of crashing on an unknown key
    private static func readTarget(_ element: NSObject) -> Target {
        var target = Target()
        guard let hit = value(element, "hitTestResult") as? NSObject else { return target }
        target.link = value(hit, "absoluteLinkURL") as? URL
        target.linkFilename = value(hit, "linkSuggestedFilename") as? String
        target.image = value(hit, "absoluteImageURL") as? URL
        target.imageFilename = value(hit, "imageSuggestedFilename") as? String
        target.media = value(hit, "absoluteMediaURL") as? URL
        let elementType = (value(hit, "elementType") as? Int) ?? 0
        target.isVideo = elementType == 2 || (elementType == 0 && target.media != nil)
        if target.link?.absoluteString.isEmpty == true { target.link = nil }
        if target.image?.absoluteString.isEmpty == true { target.image = nil }
        if target.media?.absoluteString.isEmpty == true { target.media = nil }
        return target
    }

    private static func value(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    // blob urls only exist inside the page, so they can't be fetched again from outside it
    private static func isFetchable(_ url: URL) -> Bool {
        url.scheme.map { ["http", "https", "data", "file"].contains($0.lowercased()) } ?? false
    }

    private static func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: handler)
    }

    private static func copy(_ url: URL) {
        let entry = NSPasteboardItem()
        entry.setString(url.absoluteString, forType: .URL)
        entry.setString(url.absoluteString, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([entry])
    }
}
