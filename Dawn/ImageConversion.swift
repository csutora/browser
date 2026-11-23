import AppKit
import ImageIO
import UniformTypeIdentifiers

// Turns an image from the web into something Photos imports. Formats Photos takes are passed through;
// animated images become gifs (keeping their timing, looping and transparency), and every other still
// image becomes a png, which keeps transparency too.
nonisolated enum ImageConversion {
    private static let importableTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier,
        UTType.gif.identifier, UTType.tiff.identifier,
    ]

    // writes any converted copy next to the original and returns it, or the original when it's fine as is
    static func photosImportable(_ file: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return renderedPNG(file) }
        let type = CGImageSourceGetType(source) as String?
        if let animation = animation(of: source), type != UTType.gif.identifier {
            return writeGIF(source, animation, near: file)
        }
        if let type, importableTypes.contains(type) { return file }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return renderedPNG(file) }
        return writePNG(image, near: file)
    }

    // MARK: Animation

    private struct Animation {
        var delays: [Double]
        var loopCount: Int
    }

    // an image counts as animated when it has several frames with timing. that excludes multi-page
    // tiffs, and covers every animated format imageio reads (apng, webp, avif, heic sequences, ...)
    // without naming each one's property dictionary.
    private static func animation(of source: CGImageSource) -> Animation? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var delays: [Double] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            guard let delay = frameDelay(in: properties) else { return nil }
            delays.append(delay)
        }
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        return Animation(delays: delays, loopCount: loopCount(in: container))
    }

    private static func frameDelay(in properties: [CFString: Any]) -> Double? {
        for case let format as [String: Any] in properties.values {
            let unclamped = format.first { $0.key.hasSuffix("UnclampedDelayTime") }?.value as? Double
            let clamped = format.first { $0.key.hasSuffix("DelayTime") && !$0.key.hasSuffix("UnclampedDelayTime") }?.value as? Double
            if let delay = (unclamped.flatMap { $0 > 0 ? $0 : nil }) ?? clamped { return delay }
        }
        return nil
    }

    private static func loopCount(in properties: [CFString: Any]) -> Int {
        for case let format as [String: Any] in properties.values {
            if let loops = format.first(where: { $0.key.hasSuffix("LoopCount") })?.value as? Int { return loops }
        }
        return 0
    }

    private static func writeGIF(_ source: CGImageSource, _ animation: Animation, near file: URL) -> URL? {
        let out = sibling(of: file, extension: "gif")
        guard let destination = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.gif.identifier as CFString, animation.delays.count, nil
        ) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: animation.loopCount],
        ] as CFDictionary)
        for (index, delay) in animation.delays.enumerated() {
            let added: Bool = autoreleasepool {
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return false }
                // gif timing is in hundredths of a second
                let timing = max(0.02, (delay * 100).rounded() / 100)
                CGImageDestinationAddImage(destination, frame, [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: timing,
                        kCGImagePropertyGIFUnclampedDelayTime: timing,
                    ],
                ] as CFDictionary)
                return true
            }
            guard added else { return nil }
        }
        return CGImageDestinationFinalize(destination) ? out : nil
    }

    // MARK: Stills

    // vector formats imageio can't decode (svg) render through nsimage
    private static func renderedPNG(_ file: URL) -> URL? {
        guard let image = NSImage(contentsOf: file), image.size.width > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return writePNG(cg, near: file)
    }

    private static func writePNG(_ image: CGImage, near file: URL) -> URL? {
        let out = sibling(of: file, extension: "png")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out : nil
    }

    private static func sibling(of file: URL, extension ext: String) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        var out = file.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(ext)
        if out == file { out = file.deletingLastPathComponent().appendingPathComponent(base + " converted").appendingPathExtension(ext) }
        return out
    }
}
