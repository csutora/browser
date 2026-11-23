import Foundation

// A reader for Matroska and WebM files, which AVFoundation can't open. It indexes every frame of every
// track up front, reading from a memory-mapped copy of the file, so a transcoder can pull frames in any
// order without copying the file into memory. Truncated files keep whatever was complete.
nonisolated final class MatroskaFile {
    struct Colour {
        var matrix: Int?
        var range: Int?
        var transfer: Int?
        var primaries: Int?
        var bitsPerChannel: Int?
    }

    struct Track {
        var number = 0
        var type = 0
        var codecID = ""
        var codecPrivate: Data?
        var width = 0
        var height = 0
        var displayWidth = 0
        var displayHeight = 0
        var colour = Colour()
        var sampleRate = 8000.0
        var channels = 1
        var bitDepth = 0
        var codecDelay: Int64 = 0
        var defaultDuration: Int64 = 0
        var isEncoded = false

        var isVideo: Bool { type == 1 }
        var isAudio: Bool { type == 2 }
    }

    struct Frame {
        let time: Int64
        let offset: Int
        let size: Int
        let keyframe: Bool
        // nanoseconds of decoded audio at the end of this frame that are padding, not sound
        var discardPadding: Int64 = 0
    }

    enum ParseError: Error {
        case notMatroska
        case damaged
    }

    private let storage: NSData
    let bytes: UnsafePointer<UInt8>
    let length: Int
    private(set) var tracks: [Track] = []
    private(set) var frames: [Int: [Frame]] = [:]
    private var timecodeScale: Int64 = 1_000_000

    private enum ID {
        static let ebml: UInt32 = 0x1A45DFA3
        static let docType: UInt32 = 0x4282
        static let segment: UInt32 = 0x18538067
        static let info: UInt32 = 0x1549A966
        static let timecodeScale: UInt32 = 0x2AD7B1
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let cluster: UInt32 = 0x1F43B675
        static let clusterTime: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let referenceBlock: UInt32 = 0xFB
        static let discardPadding: UInt32 = 0x75A2

        // anything that can follow a cluster, which is how a cluster of unknown size ends
        static let segmentLevel: Set<UInt32> = [
            cluster, info, tracks, 0x1C53BB6B, 0x1254C367, 0x1043A770, 0x1941A469, 0x114D9B74, ebml, segment,
        ]
    }

    static func looksLikeMatroska(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x1A, 0x45, 0xDF, 0xA3])
    }

    init(url: URL) throws {
        storage = try NSData(contentsOf: url, options: .alwaysMapped)
        bytes = storage.bytes.assumingMemoryBound(to: UInt8.self)
        length = storage.length

        var pos = 0
        guard readID(&pos) == ID.ebml, let headerSize = readSize(&pos) ?? nil else { throw ParseError.notMatroska }
        var docType = "matroska"
        children(pos, min(pos + headerSize, length)) { id, start, size in
            if id == ID.docType { docType = string(start, size) }
        }
        guard docType == "webm" || docType == "matroska" else { throw ParseError.notMatroska }
        pos += headerSize

        while pos < length {
            guard let id = readID(&pos), let size = readSize(&pos) else { throw ParseError.damaged }
            if id == ID.segment {
                parseSegment(pos, size.map { min(pos + $0, length) } ?? length)
                break
            }
            guard let size else { throw ParseError.damaged }
            pos += size
        }
        guard !tracks.isEmpty else { throw ParseError.damaged }
    }

    func data(of frame: Frame) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: bytes + frame.offset, count: frame.size)
    }

    // MARK: Segment

    private func parseSegment(_ start: Int, _ end: Int) {
        var pos = start
        while pos < end {
            guard let id = readID(&pos), let size = readSize(&pos) else { return }
            if id == ID.cluster {
                pos = parseCluster(pos, size.map { min(pos + $0, end) }, segmentEnd: end)
                continue
            }
            guard let size else { return }
            let elementEnd = min(pos + size, end)
            switch id {
            case ID.info:
                children(pos, elementEnd) { id, start, size in
                    if id == ID.timecodeScale { timecodeScale = Int64(uint(start, size)) }
                }
            case ID.tracks:
                children(pos, elementEnd) { id, start, size in
                    if id == ID.trackEntry { tracks.append(parseTrack(start, start + size)) }
                }
            default:
                break
            }
            pos = elementEnd
        }
    }

    private func parseTrack(_ start: Int, _ end: Int) -> Track {
        var track = Track()
        children(start, end) { id, start, size in
            switch id {
            case 0xD7: track.number = Int(uint(start, size))
            case 0x83: track.type = Int(uint(start, size))
            case 0x86: track.codecID = string(start, size)
            case 0x63A2: track.codecPrivate = Data(bytes: bytes + start, count: size)
            case 0x56AA: track.codecDelay = Int64(uint(start, size))
            case 0x23E383: track.defaultDuration = Int64(uint(start, size))
            case 0x6D80: track.isEncoded = true
            case 0xE0:
                children(start, start + size) { id, start, size in
                    switch id {
                    case 0xB0: track.width = Int(uint(start, size))
                    case 0xBA: track.height = Int(uint(start, size))
                    case 0x54B0: track.displayWidth = Int(uint(start, size))
                    case 0x54BA: track.displayHeight = Int(uint(start, size))
                    case 0x55B0:
                        children(start, start + size) { id, start, size in
                            let value = Int(uint(start, size))
                            switch id {
                            case 0x55B1: track.colour.matrix = value
                            case 0x55B2: track.colour.bitsPerChannel = value
                            case 0x55B9: track.colour.range = value
                            case 0x55BA: track.colour.transfer = value
                            case 0x55BB: track.colour.primaries = value
                            default: break
                            }
                        }
                    default: break
                    }
                }
            case 0xE1:
                children(start, start + size) { id, start, size in
                    switch id {
                    case 0xB5: track.sampleRate = float(start, size)
                    case 0x9F: track.channels = Int(uint(start, size))
                    case 0x6264: track.bitDepth = Int(uint(start, size))
                    default: break
                    }
                }
            default:
                break
            }
        }
        return track
    }

    // MARK: Clusters and blocks

    // returns where parsing should continue after this cluster
    private func parseCluster(_ start: Int, _ end: Int?, segmentEnd: Int) -> Int {
        let limit = end ?? segmentEnd
        var pos = start
        var clusterTime: Int64 = 0
        while pos < limit {
            let elementStart = pos
            guard let id = readID(&pos) else { return limit }
            if end == nil, ID.segmentLevel.contains(id) { return elementStart }
            guard let size = readSize(&pos) ?? nil, pos + size <= length else { return length }
            switch id {
            case ID.clusterTime:
                clusterTime = Int64(uint(pos, size))
            case ID.simpleBlock:
                addBlock(pos, pos + size, clusterTime: clusterTime, groupKeyframe: nil)
            case ID.blockGroup:
                var block: (Int, Int)?
                var referenced = false
                var padding: Int64 = 0
                children(pos, pos + size) { id, start, size in
                    if id == ID.block { block = (start, start + size) }
                    if id == ID.referenceBlock { referenced = true }
                    if id == ID.discardPadding { padding = int(start, size) }
                }
                if let block {
                    addBlock(block.0, block.1, clusterTime: clusterTime, groupKeyframe: !referenced, discardPadding: padding)
                }
            default:
                break
            }
            pos += size
        }
        return limit
    }

    private func addBlock(_ start: Int, _ end: Int, clusterTime: Int64, groupKeyframe: Bool?, discardPadding: Int64 = 0) {
        var pos = start
        guard let number = readVint(&pos).map({ Int($0.value) }), pos + 3 <= end else { return }
        let relative = Int16(bitPattern: UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1]))
        let flags = bytes[pos + 2]
        pos += 3
        let keyframe = groupKeyframe ?? (flags & 0x80 != 0)
        let time = (clusterTime + Int64(relative)) * timecodeScale

        guard let sizes = laceSizes(lacing: (flags >> 1) & 3, &pos, end) else { return }
        let defaultDuration = tracks.first { $0.number == number }?.defaultDuration ?? 0
        var offset = pos
        var list = frames[number] ?? []
        for (index, size) in sizes.enumerated() {
            var frame = Frame(time: time + Int64(index) * defaultDuration, offset: offset, size: size, keyframe: keyframe)
            if index == sizes.count - 1 { frame.discardPadding = max(0, discardPadding) }
            list.append(frame)
            offset += size
        }
        frames[number] = list
    }

    private func laceSizes(lacing: UInt8, _ pos: inout Int, _ end: Int) -> [Int]? {
        if lacing == 0 { return [end - pos] }
        guard pos < end else { return nil }
        let count = Int(bytes[pos]) + 1
        pos += 1
        var sizes: [Int] = []
        switch lacing {
        case 1:
            for _ in 0..<(count - 1) {
                var size = 0
                var byte: UInt8 = 255
                while byte == 255 {
                    guard pos < end else { return nil }
                    byte = bytes[pos]
                    size += Int(byte)
                    pos += 1
                }
                sizes.append(size)
            }
        case 2:
            let each = (end - pos) / count
            return each > 0 ? Array(repeating: each, count: count) : nil
        default:
            guard let first = readVint(&pos) else { return nil }
            sizes.append(Int(first.value))
            for _ in 0..<max(0, count - 2) {
                guard let raw = readVint(&pos) else { return nil }
                let bias = (Int64(1) << (7 * raw.length - 1)) - 1
                sizes.append(sizes[sizes.count - 1] + Int(Int64(raw.value) - bias))
            }
        }
        let last = end - pos - sizes.reduce(0, +)
        guard last >= 0, sizes.allSatisfy({ $0 >= 0 }) else { return nil }
        return sizes + [last]
    }

    // MARK: EBML primitives

    private func children(_ start: Int, _ end: Int, _ body: (UInt32, Int, Int) -> Void) {
        var pos = start
        let end = min(end, length)
        while pos < end {
            guard let id = readID(&pos), let size = readSize(&pos) ?? nil, pos + size <= end else { return }
            body(id, pos, size)
            pos += size
        }
    }

    private func readID(_ pos: inout Int) -> UInt32? {
        guard pos < length, bytes[pos] != 0 else { return nil }
        let count = bytes[pos].leadingZeroBitCount + 1
        guard count <= 4, pos + count <= length else { return nil }
        var value: UInt32 = 0
        for index in 0..<count { value = value << 8 | UInt32(bytes[pos + index]) }
        pos += count
        return value
    }

    // the outer optional is a read failure; the inner one is an element of unknown size
    private func readSize(_ pos: inout Int) -> Int?? {
        guard let vint = readVint(&pos) else { return nil }
        let unknown = (UInt64(1) << (7 * vint.length)) - 1
        if vint.value == unknown { return .some(nil) }
        guard vint.value < UInt64(Int.max) else { return nil }
        return .some(Int(vint.value))
    }

    private func readVint(_ pos: inout Int) -> (value: UInt64, length: Int)? {
        guard pos < length, bytes[pos] != 0 else { return nil }
        let count = bytes[pos].leadingZeroBitCount + 1
        guard pos + count <= length else { return nil }
        var value = UInt64(bytes[pos] & (0xFF >> count))
        for index in 1..<count { value = value << 8 | UInt64(bytes[pos + index]) }
        pos += count
        return (value, count)
    }

    private func uint(_ start: Int, _ size: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<min(size, 8) { value = value << 8 | UInt64(bytes[start + index]) }
        return value
    }

    private func int(_ start: Int, _ size: Int) -> Int64 {
        guard size > 0, size <= 8 else { return 0 }
        let shift = UInt64(64 - 8 * size)
        return Int64(bitPattern: uint(start, size) << shift) >> Int64(shift)
    }

    private func float(_ start: Int, _ size: Int) -> Double {
        let raw = uint(start, size)
        switch size {
        case 4: return Double(Float(bitPattern: UInt32(raw)))
        case 8: return Double(bitPattern: raw)
        default: return 0
        }
    }

    private func string(_ start: Int, _ size: Int) -> String {
        let buffer = UnsafeBufferPointer(start: bytes + start, count: size)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
