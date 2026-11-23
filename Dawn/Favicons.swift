import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// MARK: - Favicon

// a site's icon, decoded once and drawn sharp at whatever size and scale it's shown at. each pixel size
// it's drawn at is rendered once: a bitmap icon from the smallest of the site's renditions that's at least
// that large (downscaled carefully), or its largest one scaled up; a vector icon afresh at that size.
nonisolated final class Favicon: @unchecked Sendable {
    let key: String
    // how much detail it holds, for picking the better of two: its largest rendition's pixel size, or
    // as much as there can be for a vector
    let detail: Int

    private struct Frame {
        let index: Int
        let side: Int
    }

    private enum Source {
        case bitmap(CGImageSource, frames: [Frame])
        case vector(NSImage)
    }

    private let source: Source
    private let lock = NSLock()
    private var renditions: [Int: CGImage] = [:]

    init?(key: String, data: Data) {
        self.key = key
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            var frames: [Frame] = []
            for index in 0..<CGImageSourceGetCount(source) {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { continue }
                frames.append(Frame(index: index, side: max(width, height)))
            }
            guard let largest = frames.map(\.side).max() else { return nil }
            // stable, so of equal renditions (an animation's frames) the first is used
            self.source = .bitmap(source, frames: frames.enumerated().sorted { ($0.element.side, $0.offset) < ($1.element.side, $1.offset) }.map(\.element))
            self.detail = largest
        } else if let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
                  image.representations.contains(where: { !($0 is NSBitmapImageRep) }) {
            // svg (and pdf), which imageio doesn't read
            self.source = .vector(image)
            self.detail = .max
        } else {
            return nil
        }
    }

    // the icon as an image of the given size in points, which draws itself from a rendition made for
    // exactly the pixels it covers, on any screen
    func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { [self] rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let device = context.convertToDeviceSpace(rect)
            let side = Int(max(abs(device.width), abs(device.height)).rounded())
            guard side > 0, let rendition = rendition(side: side) else { return false }
            // centered in the square on whole pixels, keeping its shape
            let points = rect.width / CGFloat(side)
            let x = ((CGFloat(side) - CGFloat(rendition.width)) / 2).rounded(.down)
            let y = ((CGFloat(side) - CGFloat(rendition.height)) / 2).rounded(.down)
            context.interpolationQuality = .high
            context.draw(rendition, in: CGRect(x: rect.minX + x * points, y: rect.minY + y * points,
                                                width: CGFloat(rendition.width) * points, height: CGFloat(rendition.height) * points))
            return true
        }
    }

    // the icon fit within a square of this many pixels
    func rendition(side: Int) -> CGImage? {
        lock.lock()
        if let rendition = renditions[side] {
            lock.unlock()
            return rendition
        }
        lock.unlock()
        let rendition = render(side: side)
        lock.lock()
        renditions[side] = rendition
        lock.unlock()
        return rendition
    }

    private func render(side: Int) -> CGImage? {
        switch source {
        case .bitmap(let source, let frames):
            guard let frame = frames.first(where: { $0.side >= side }) ?? frames.last else { return nil }
            guard let decoded = Self.decode(source, frame.index, side: min(side, frame.side)) else { return nil }
            guard frame.side < side else { return decoded }
            // too small for the space: a whole multiple keeps its pixels square and sharp, anything else
            // is smoothed rather than left uneven
            let scale = CGFloat(side) / CGFloat(frame.side)
            let whole = side % frame.side == 0
            return Self.draw(width: Int((CGFloat(decoded.width) * scale).rounded()), height: Int((CGFloat(decoded.height) * scale).rounded()),
                             colorSpace: decoded.colorSpace) { context, rect in
                context.interpolationQuality = whole ? .none : .high
                context.draw(decoded, in: rect)
            }
        case .vector(let image):
            let fit = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
            let width = max(1, Int((image.size.width * fit).rounded())), height = max(1, Int((image.size.height * fit).rounded()))
            return Self.draw(width: width, height: height, colorSpace: nil) { context, rect in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    // a rendition at most this large, in its own orientation; imageio downsamples with care, and decodes
    // no more of a large image than that takes
    private static func decode(_ source: CGImageSource, _ index: Int, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func draw(width: Int, height: Int, colorSpace: CGColorSpace?, _ body: (CGContext, CGRect) -> Void) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context = colorSpace.flatMap({ $0.model == .rgb ? context($0) : nil }) ?? context(srgb) else { return nil }
        body(context, CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Icon Store

// icons kept on disk under the sha-256 of their bytes, so a site's icon is stored once however many tabs
// and history entries show it. what's stored only ever decides what's drawn: whether an icon is
// requested is left to the page's own (partitioned) http cache, so these files can't be probed to
// recognize a visitor, the way favicon caches have been used to track people.
final class IconStore {
    static let shared = IconStore()

    // the largest rendition kept of an icon: twice the largest size dawn shows one at in points, on a
    // retina screen. a site's larger icon (a 512 pixel app icon, say) is stored downscaled to this.
    nonisolated static let largestStoredSide = 256

    // every icon something still shows (tabs, history, recently closed tabs); the rest are deleted
    var referencedKeys: (() -> Set<String>)?

    private let directory: URL
    private let cache = NSCache<NSString, Favicon>()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // the icon with this key, decoded (from disk the first time); nil when there's none
    func favicon(for key: String?) -> Favicon? {
        guard let key else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key)), let favicon = Favicon(key: key, data: data) else { return nil }
        cache.setObject(favicon, forKey: key as NSString)
        return favicon
    }

    struct Prepared: Sendable {
        let favicon: Favicon
        let data: Data
    }

    // decodes icon bytes a page loaded, off the main thread. a bitmap larger than the largest stored size
    // is kept downscaled to it, and a vector is kept as it is unless such a bitmap would be smaller.
    nonisolated static func prepare(_ data: Data) -> Prepared? {
        guard let decoded = Favicon(key: hash(data), data: data) else { return nil }
        guard decoded.detail > largestStoredSide, let rendition = decoded.rendition(side: largestStoredSide), let png = png(rendition),
              decoded.detail != .max || png.count < data.count else { return Prepared(favicon: decoded, data: data) }
        guard let favicon = Favicon(key: hash(png), data: png) else { return nil }
        return Prepared(favicon: favicon, data: png)
    }

    // keeps a prepared icon, returning its key
    func store(_ prepared: Prepared) -> String {
        let key = prepared.favicon.key
        let file = directory.appendingPathComponent(key)
        if !FileManager.default.fileExists(atPath: file.path) { try? prepared.data.write(to: file, options: .atomic) }
        cache.setObject(prepared.favicon, forKey: key as NSString)
        return key
    }

    // deletes every stored icon nothing shows anymore
    func collectGarbage() {
        guard let referencedKeys else { return }
        let keep = referencedKeys()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in files where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            cache.removeObject(forKey: name as NSString)
        }
    }

    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - Icon Loading

// webkit finds a page's icons once it has loaded (its link elements, or /favicon.ico when it names
// none) and asks whether to load each. it loads them the way the page loads its images, through the
// page's network session and partitioned cache under its content security policy, but without cookies
// or credentials, and hands over the bytes. this is the private hook safari uses; without it, pages
// simply show no icon.
final class IconLoadingBridge: NSObject {
    // asked for each of the page's icons: its favicons, and its touch icons (the larger ones made for
    // home screens) when `touch` is set; returns what receives its bytes, or nil when they're unwanted
    private let offered: (_ touch: Bool) -> ((Data?) -> Void)?

    init(offered: @escaping (_ touch: Bool) -> ((Data?) -> Void)?) {
        self.offered = offered
    }

    func attach(to webView: WKWebView) {
        let selector = NSSelectorFromString("_setIconLoadingDelegate:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, self)
    }

    @objc(webView:shouldLoadIconWithParameters:completionHandler:)
    func webView(_ webView: WKWebView, shouldLoadIconWithParameters parameters: NSObject,
                 completionHandler: @escaping (((Data?) -> Void)?) -> Void) {
        // WKLinkIconType: favicon, touch icon, precomposed touch icon
        let faviconType = 0, touchIconTypes = [1, 2]
        let type = parameters.value(forKey: "iconType") as? Int
        guard type == faviconType || touchIconTypes.contains(type ?? -1),
              let receive = offered(type != faviconType) else { return completionHandler(nil) }
        completionHandler(receive)
    }
}
