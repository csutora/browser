import AVFoundation
import CoreMedia
import VideoToolbox

nonisolated enum VideoConversionError: LocalizedError {
    case unsupportedFormat
    case unsupportedVideoCodec(String)
    case unsupportedAudioCodec(String)
    case damaged
    case failed(Error?)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Photos can't import this video, and its format can't be converted."
        case .unsupportedVideoCodec(let codec):
            return "This video is encoded as \(codec), which this Mac can't decode, so it can't be converted for Photos."
        case .unsupportedAudioCodec(let codec):
            return "This video's sound is encoded as \(codec), which this Mac can't decode, so it can't be converted for Photos."
        case .damaged:
            return "This video file appears to be damaged."
        case .failed(let error):
            return error?.localizedDescription ?? "The video couldn't be converted."
        }
    }
}

// Turns a video from the web into something Photos imports. Movies AVFoundation plays already are
// passed through (or re-exported when their container isn't one Photos takes); WebM and Matroska files,
// which AVFoundation can't open at all, are decoded with the system's own decoders and re-encoded as
// HEVC with AAC sound in an mp4.
nonisolated enum VideoConversion {
    static func photosImportable(_ file: URL) async throws -> URL {
        let asset = AVURLAsset(url: file)
        if (try? await asset.load(.isPlayable)) == true {
            if ["mp4", "m4v", "mov"].contains(file.pathExtension.lowercased()) { return file }
            let out = sibling(of: file)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
                throw VideoConversionError.unsupportedFormat
            }
            do {
                try await session.export(to: out, as: .mp4)
            } catch {
                throw VideoConversionError.failed(error)
            }
            return out
        }
        guard MatroskaFile.looksLikeMatroska(file) else { throw VideoConversionError.unsupportedFormat }
        let matroska: MatroskaFile
        do {
            matroska = try MatroskaFile(url: file)
        } catch MatroskaFile.ParseError.notMatroska {
            throw VideoConversionError.unsupportedFormat
        } catch {
            throw VideoConversionError.damaged
        }
        let out = sibling(of: file)
        try await MatroskaTranscoder(matroska, output: out).run()
        return out
    }

    private static func sibling(of file: URL) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent().appendingPathComponent(base + " converted").appendingPathExtension("mp4")
    }
}

// MARK: - Transcoder

nonisolated private final class MatroskaTranscoder {
    private let output: URL
    private let video: VideoSource
    private let audio: AudioSource?
    private let origin: Int64

    init(_ file: MatroskaFile, output: URL) throws {
        self.output = output
        guard let videoTrack = file.tracks.first(where: { $0.isVideo && !(file.frames[$0.number] ?? []).isEmpty }) else {
            throw VideoConversionError.unsupportedFormat
        }
        video = try VideoSource(file, videoTrack)
        if let audioTrack = file.tracks.first(where: { $0.isAudio && !(file.frames[$0.number] ?? []).isEmpty }) {
            audio = try AudioSource(file, audioTrack)
        } else {
            audio = nil
        }
        origin = min(video.startTime, audio?.startTime ?? .max)
    }

    func run() async throws {
        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw VideoConversionError.failed(error)
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video.outputSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw VideoConversionError.failed(nil) }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio.outputSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw VideoConversionError.failed(nil) }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw VideoConversionError.failed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let failure = FailureBox()
        await withTaskGroup(of: Void.self) { group in
            let video = self.video
            let origin = self.origin
            group.addTask {
                await Self.drain(videoInput, label: "video") {
                    guard writer.status == .writing, let frame = video.next() else { return false }
                    let time = CMTime(value: frame.time - origin, timescale: 1_000_000_000)
                    if !adaptor.append(frame.buffer, withPresentationTime: time) {
                        failure.set(writer.error)
                        return false
                    }
                    return true
                }
            }
            if let audio, let audioInput {
                group.addTask {
                    await Self.drain(audioInput, label: "audio") {
                        do {
                            guard writer.status == .writing, let sample = try audio.next(origin: origin) else { return false }
                            if !audioInput.append(sample) {
                                failure.set(writer.error)
                                return false
                            }
                            return true
                        } catch {
                            failure.set(error)
                            return false
                        }
                    }
                }
            }
        }

        if let error = failure.error ?? video.error {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw (error as? VideoConversionError) ?? VideoConversionError.failed(error)
        }
        guard video.producedFrames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw VideoConversionError.unsupportedVideoCodec(video.codec)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw VideoConversionError.failed(writer.error)
        }
    }

    // feeds an input whenever the writer asks for more, until the producer runs out or fails
    private static func drain(_ input: AVAssetWriterInput, label: String, _ produce: @escaping () -> Bool) async {
        let queue = DispatchQueue(label: "dawn.transcode.\(label)")
        // only ever touched on its own serial queue, which is how avfoundation asks inputs to be fed
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if !produce() {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}

nonisolated private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    private var isSet = false

    var error: Error? {
        lock.withLock { isSet ? (stored ?? VideoConversionError.failed(nil)) : nil }
    }

    func set(_ error: Error?) {
        lock.withLock {
            guard !isSet else { return }
            isSet = true
            stored = error
        }
    }
}

// MARK: - Video

nonisolated private final class VideoSource: @unchecked Sendable {
    struct DecodedFrame {
        let buffer: CVPixelBuffer
        let time: Int64
    }

    private let file: MatroskaFile
    private let frames: [MatroskaFile.Frame]
    private let session: VTDecompressionSession
    private let format: CMVideoFormatDescription
    private let reorderDepth: Int
    private var index = 0
    private var pending: [DecodedFrame] = []
    private var lastTime: Int64 = .min
    private var failedDecodes = 0
    private(set) var producedFrames = 0
    private(set) var error: Error?
    let codec: String
    let startTime: Int64
    let outputSettings: [String: Any]

    init(_ file: MatroskaFile, _ track: MatroskaFile.Track) throws {
        self.file = file
        codec = Self.codecName(track.codecID)
        guard !track.isEncoded else { throw VideoConversionError.unsupportedFormat }
        let all = file.frames[track.number] ?? []
        guard let firstKey = all.firstIndex(where: \.keyframe) else { throw VideoConversionError.damaged }
        frames = Array(all[firstKey...])
        startTime = frames.map(\.time).min() ?? 0
        guard track.width > 0, track.height > 0 else { throw VideoConversionError.damaged }

        var colour = track.colour
        let codec: CMVideoCodecType
        let atom: (String, Data)
        switch track.codecID {
        case "V_VP9":
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            let header = VP9Header(file.data(of: frames[0]))
            colour.bitsPerChannel = colour.bitsPerChannel ?? header?.bitDepth
            colour.range = colour.range ?? (header?.fullRange == true ? 2 : nil)
            if colour.matrix == nil, let space = header?.colorSpace { colour.matrix = VP9Header.matrix(forColorSpace: space) }
            codec = kCMVideoCodecType_VP9
            atom = ("vpcC", VP9Header.configurationRecord(header, colour: colour))
            reorderDepth = 0
        case "V_AV1":
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
            guard let config = track.codecPrivate, !config.isEmpty else { throw VideoConversionError.damaged }
            codec = kCMVideoCodecType_AV1
            atom = ("av1C", config)
            reorderDepth = 0
        case "V_MPEG4/ISO/AVC":
            guard let config = track.codecPrivate, !config.isEmpty else { throw VideoConversionError.damaged }
            codec = kCMVideoCodecType_H264
            atom = ("avcC", config)
            reorderDepth = 8
        case "V_MPEGH/ISO/HEVC":
            guard let config = track.codecPrivate, !config.isEmpty else { throw VideoConversionError.damaged }
            codec = kCMVideoCodecType_HEVC
            atom = ("hvcC", config)
            reorderDepth = 8
        default:
            throw VideoConversionError.unsupportedVideoCodec(Self.codecName(track.codecID))
        }

        let colors = ColorProperties(colour, height: track.height)
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom.0: atom.1],
            kCMFormatDescriptionExtension_ColorPrimaries: colors.primaries,
            kCMFormatDescriptionExtension_TransferFunction: colors.transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix: colors.matrix,
        ]
        if colour.range == 2 { extensions[kCMFormatDescriptionExtension_FullRangeVideo] = true }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: codec, width: Int32(track.width), height: Int32(track.height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &description
        ) == noErr, let description else { throw VideoConversionError.damaged }
        format = description

        let tenBit = (colour.bitsPerChannel ?? 8) > 8
        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created
        ) == noErr, let created else {
            throw VideoConversionError.unsupportedVideoCodec(Self.codecName(track.codecID))
        }
        session = created

        let seconds = max(0.001, Double((frames.map(\.time).max() ?? 0) - startTime) / 1e9)
        let frameRate = track.defaultDuration > 0 ? 1e9 / Double(track.defaultDuration) : Double(frames.count) / seconds
        var compression: [String: Any] = [
            // constant quality rather than the source's bitrate: re-encoding at the source rate stacks a
            // second generation of loss, and 0.65 measures visually transparent against the decoded source
            AVVideoQualityKey: 0.65,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
        ]
        if tenBit { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: track.width,
            AVVideoHeightKey: track.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: colors.primaries,
                AVVideoTransferFunctionKey: colors.transfer,
                AVVideoYCbCrMatrixKey: colors.matrix,
            ],
        ]
        if track.displayWidth > 0, track.displayHeight > 0,
           track.displayWidth * track.height != track.displayHeight * track.width {
            settings[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: track.displayWidth * track.height,
                AVVideoPixelAspectRatioVerticalSpacingKey: track.displayHeight * track.width,
            ]
        }
        outputSettings = settings
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    // the next frame in presentation order. frames are stored in decode order, which for h.264 and hevc
    // differs, so a few decoded frames are held back and the earliest is released first.
    func next() -> DecodedFrame? {
        while true {
            while pending.count <= reorderDepth, index < frames.count {
                decode(frames[index])
                index += 1
                if error != nil { return nil }
            }
            guard let earliest = pending.indices.min(by: { pending[$0].time < pending[$1].time }) else { return nil }
            let frame = pending.remove(at: earliest)
            // the writer needs strictly increasing times
            guard frame.time > lastTime else { continue }
            lastTime = frame.time
            producedFrames += 1
            return frame
        }
    }

    private func decode(_ frame: MatroskaFile.Frame) {
        let data = file.data(of: frame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block, CMBlockBufferReplaceDataBytes(
            with: data.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count
        ) == noErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: frame.time, timescale: 1_000_000_000), decodeTimeStamp: .invalid
        )
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        // written by the decoder's callback and read only after waiting for the decoder to finish
        nonisolated(unsafe) var decoded: CVImageBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { decoded = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status == noErr, let decoded {
            pending.append(DecodedFrame(buffer: decoded, time: frame.time))
        } else {
            // a few bad frames are skipped; a stream that won't decode at all is an error
            failedDecodes += 1
            if failedDecodes > 30, producedFrames == 0, pending.isEmpty { error = VideoConversionError.unsupportedVideoCodec(codec) }
        }
    }

    static func codecName(_ codecID: String) -> String {
        switch codecID {
        case "V_VP8": return "VP8"
        case "V_VP9": return "VP9"
        case "V_AV1": return "AV1"
        case "V_THEORA": return "Theora"
        case "V_MPEG4/ISO/AVC": return "H.264"
        case "V_MPEGH/ISO/HEVC": return "HEVC"
        default: return codecID.hasPrefix("V_") ? String(codecID.dropFirst(2)) : codecID
        }
    }
}

// colour code points (itu-t h.273, which matroska and vp9 both use) as core video's names
nonisolated private struct ColorProperties {
    let primaries: String
    let transfer: String
    let matrix: String

    // untagged video gets what players assume: bt.601 for standard definition, bt.709 above it
    init(_ colour: MatroskaFile.Colour, height: Int) {
        let standardDefinition = height <= 576
        switch colour.primaries {
        case 9: primaries = AVVideoColorPrimaries_ITU_R_2020
        case 12: primaries = AVVideoColorPrimaries_P3_D65
        case 6, 7: primaries = AVVideoColorPrimaries_SMPTE_C
        default: primaries = AVVideoColorPrimaries_ITU_R_709_2
        }
        switch colour.transfer {
        case 16: transfer = AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case 18: transfer = AVVideoTransferFunction_ITU_R_2100_HLG
        default: transfer = AVVideoTransferFunction_ITU_R_709_2
        }
        switch colour.matrix {
        case 9, 10: matrix = AVVideoYCbCrMatrix_ITU_R_2020
        case 5, 6: matrix = AVVideoYCbCrMatrix_ITU_R_601_4
        case 1: matrix = AVVideoYCbCrMatrix_ITU_R_709_2
        default: matrix = standardDefinition ? AVVideoYCbCrMatrix_ITU_R_601_4 : AVVideoYCbCrMatrix_ITU_R_709_2
        }
    }
}

// the parts of a vp9 keyframe's uncompressed header that describe its pixel format, which videotoolbox
// needs up front (webm usually doesn't carry them anywhere else)
nonisolated private struct VP9Header {
    let profile: Int
    let bitDepth: Int
    let colorSpace: Int
    let fullRange: Bool
    let subsamplingX: Bool
    let subsamplingY: Bool

    init?(_ data: UnsafeBufferPointer<UInt8>) {
        var bit = 0
        func read(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard bit / 8 < data.count else { return nil }
                value = value << 1 | Int((data[bit / 8] >> (7 - UInt8(bit % 8))) & 1)
                bit += 1
            }
            return value
        }
        guard read(2) == 2, let low = read(1), let high = read(1) else { return nil }
        profile = high << 1 | low
        if profile == 3 { _ = read(1) }
        guard read(1) == 0, read(1) == 0, read(2) != nil, read(24) == 0x498342 else { return nil }
        var depth = 8
        if profile >= 2 {
            guard let twelve = read(1) else { return nil }
            depth = twelve == 1 ? 12 : 10
        }
        bitDepth = depth
        guard let space = read(3) else { return nil }
        colorSpace = space
        if space != 7 {
            fullRange = read(1) == 1
            if profile == 1 || profile == 3 {
                subsamplingX = read(1) == 1
                subsamplingY = read(1) == 1
            } else {
                subsamplingX = true
                subsamplingY = true
            }
        } else {
            fullRange = true
            subsamplingX = false
            subsamplingY = false
        }
    }

    static func matrix(forColorSpace space: Int) -> Int? {
        switch space {
        case 1, 3: return 6
        case 2: return 1
        case 4: return 7
        case 5: return 9
        default: return nil
        }
    }

    // a vp codec configuration record (the vpcC box), version 1
    static func configurationRecord(_ header: VP9Header?, colour: MatroskaFile.Colour) -> Data {
        let subsampling: UInt8
        switch (header?.subsamplingX ?? true, header?.subsamplingY ?? true) {
        case (true, true): subsampling = 1
        case (true, false): subsampling = 2
        default: subsampling = 3
        }
        let depth = UInt8(colour.bitsPerChannel ?? header?.bitDepth ?? 8)
        let fullRange: UInt8 = colour.range == 2 ? 1 : 0
        return Data([
            1, 0, 0, 0,
            UInt8(header?.profile ?? 0), 0,
            depth << 4 | subsampling << 1 | fullRange,
            UInt8(colour.primaries ?? 1), UInt8(colour.transfer ?? 1), UInt8(colour.matrix ?? 1),
            0, 0,
        ])
    }
}

// MARK: - Audio

// decodes with audio toolbox's converter directly: avaudioconverter stalls on vorbis after a couple of
// packets, while the converter underneath it decodes every codec here, and resamples and downmixes in the
// same pass
nonisolated private final class AudioSource: @unchecked Sendable {
    private let feed: PacketFeed
    private let converter: AudioConverterRef
    private let sampleFormat: CMAudioFormatDescription
    private let rate: Double
    private let channels: Int
    private let name: String
    private var framesEmitted: Int64 = 0
    private var discard: Int
    // the exact length when the packets say it (opus), so the encoder's padding at the end is dropped too
    private var remaining: Int64?
    private var finished = false
    let startTime: Int64
    let outputSettings: [String: Any]

    private static let aacRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

    init(_ file: MatroskaFile, _ track: MatroskaFile.Track) throws {
        guard !track.isEncoded else { throw VideoConversionError.unsupportedFormat }
        let packets = file.frames[track.number] ?? []
        startTime = packets.first?.time ?? 0
        let name = Self.codecName(track.codecID)
        self.name = name

        var description = AudioStreamBasicDescription()
        description.mChannelsPerFrame = UInt32(max(1, track.channels))
        description.mSampleRate = track.sampleRate
        var cookie: Data?
        switch track.codecID {
        case "A_OPUS":
            description.mFormatID = kAudioFormatOpus
            description.mSampleRate = 48000
            description.mFramesPerPacket = 960
            cookie = track.codecPrivate
        case "A_VORBIS":
            // 'vorb': the system has a vorbis decoder, but the sdk names no constant for it
            description.mFormatID = 0x766F_7262
            cookie = track.codecPrivate
        case let id where id.hasPrefix("A_AAC"):
            description.mFormatID = kAudioFormatMPEG4AAC
            description.mFramesPerPacket = 1024
            cookie = track.codecPrivate.map(Self.esds)
        case "A_MPEG/L3":
            description.mFormatID = kAudioFormatMPEGLayer3
            description.mFramesPerPacket = 1152
        case "A_PCM/INT/LIT", "A_PCM/FLOAT/IEEE":
            let float = track.codecID.hasSuffix("IEEE")
            let bits = UInt32(track.bitDepth > 0 ? track.bitDepth : (float ? 32 : 16))
            description.mFormatID = kAudioFormatLinearPCM
            description.mFormatFlags = float ? kAudioFormatFlagIsFloat : (bits > 8 ? kAudioFormatFlagIsSignedInteger : 0)
            description.mFormatFlags |= kAudioFormatFlagIsPacked
            description.mBitsPerChannel = bits
            description.mFramesPerPacket = 1
            description.mBytesPerFrame = bits / 8 * description.mChannelsPerFrame
            description.mBytesPerPacket = description.mBytesPerFrame
        default:
            throw VideoConversionError.unsupportedAudioCodec(name)
        }
        // the cookie knows the stream's real parameters (vorbis's block sizes come from it), so the
        // decoder fills them in where it can
        if let cookie {
            var filled = description
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = cookie.withUnsafeBytes {
                AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), $0.baseAddress, &size, &filled)
            }
            if status == noErr, filled.mSampleRate > 0, filled.mChannelsPerFrame > 0 { description = filled }
        }

        rate = Self.aacRates.contains(description.mSampleRate) ? description.mSampleRate : 48000
        channels = Int(min(2, description.mChannelsPerFrame))
        let frameBytes = UInt32(4 * channels)
        var output = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        guard let created = Self.makeConverter(description, output, cookie: cookie) else {
            throw VideoConversionError.unsupportedAudioCodec(name)
        }
        converter = created
        feed = PacketFeed(file, packets, channels: description.mChannelsPerFrame,
                          bytesPerFrame: description.mFormatID == kAudioFormatLinearPCM ? Int(description.mBytesPerFrame) : 0)

        var sampleFormat: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &output, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &sampleFormat
        ) == noErr, let sampleFormat else {
            AudioConverterDispose(created)
            throw VideoConversionError.unsupportedAudioCodec(name)
        }
        self.sampleFormat = sampleFormat

        // matroska's codec delay is encoder priming at the start that isn't part of the sound. apple's
        // vorbis decoder already leaves it out, and its opus decoder drops part of it by itself.
        let delay = Int((Double(track.codecDelay) / 1e9 * rate).rounded())
        switch track.codecID {
        case "A_VORBIS":
            discard = 0
        case "A_OPUS":
            let total = packets.reduce(Int64(0)) { $0 + Int64(Self.opusSamples(file.data(of: $1))) }
            let padding = Int64((Double(packets.reduce(Int64(0)) { $0 + $1.discardPadding }) / 1e9 * rate).rounded())
            remaining = max(0, total - Int64(delay) - padding)
            let trimmed = Self.decoderTrim(description, output, cookie: cookie, file, Array(packets.prefix(8)))
            discard = max(0, delay - trimmed)
        default:
            discard = delay
        }

        outputSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 192_000 : 96_000,
        ]
    }

    deinit {
        AudioConverterDispose(converter)
    }

    // the next chunk of decoded sound, or nil once the track is done
    func next(origin: Int64) throws -> CMSampleBuffer? {
        let capacity = 4096
        let byteCount = capacity * channels * 4
        let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { storage.deallocate() }
        while !finished {
            var frames = UInt32(capacity)
            var list = AudioBufferList(
                mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(byteCount), mData: storage)
            )
            let status = AudioConverterFillComplexBuffer(converter, PacketFeed.supply, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
            guard status == noErr else {
                throw VideoConversionError.failed(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
            }
            guard frames > 0 else {
                finished = true
                break
            }
            var start = 0
            var count = Int(frames)
            if discard > 0 {
                start = min(discard, count)
                discard -= start
                count -= start
            }
            if let left = remaining {
                count = Int(min(Int64(count), left))
                remaining = left - Int64(count)
                if remaining == 0 { finished = true }
            }
            guard count > 0 else { continue }
            let time = CMTime(value: startTime - origin, timescale: 1_000_000_000)
                + CMTime(value: framesEmitted, timescale: CMTimeScale(rate))
            framesEmitted += Int64(count)
            return try sampleBuffer(storage + start * channels * 4, frames: count, at: time)
        }
        // a track with packets that decodes to nothing is a codec the decoder doesn't really handle
        if framesEmitted == 0, feed.hasPackets { throw VideoConversionError.unsupportedAudioCodec(name) }
        return nil
    }

    private func sampleBuffer(_ data: UnsafeMutableRawPointer, frames: Int, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: time, decodeTimeStamp: .invalid
        )
        var list = AudioBufferList(
            mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: data)
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: sampleFormat, sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ) == noErr, let sample, CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: &list
        ) == noErr else { throw VideoConversionError.failed(nil) }
        return sample
    }

    private static func makeConverter(
        _ input: AudioStreamBasicDescription, _ output: AudioStreamBasicDescription, cookie: Data?
    ) -> AudioConverterRef? {
        var input = input
        var output = output
        var created: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &created) == noErr, let created else { return nil }
        if let cookie, cookie.withUnsafeBytes({
            AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
        }) != noErr {
            AudioConverterDispose(created)
            return nil
        }
        if input.mChannelsPerFrame != output.mChannelsPerFrame {
            var mix: UInt32 = 1
            AudioConverterSetProperty(created, kAudioConverterPropertyPerformDownmix, UInt32(MemoryLayout<UInt32>.size), &mix)
        }
        return created
    }

    // how many samples apple's opus decoder drops from the start by itself, found by decoding the first
    // few packets to the end and comparing against what they hold. measured rather than assumed, so a
    // decoder that changes this keeps the sound in sync.
    private static func decoderTrim(
        _ input: AudioStreamBasicDescription, _ output: AudioStreamBasicDescription, cookie: Data?,
        _ file: MatroskaFile, _ packets: [MatroskaFile.Frame]
    ) -> Int {
        guard let converter = makeConverter(input, output, cookie: cookie) else { return 0 }
        defer { AudioConverterDispose(converter) }
        let held = packets.reduce(0) { $0 + opusSamples(file.data(of: $1)) }
        let feed = PacketFeed(file, packets, channels: input.mChannelsPerFrame, bytesPerFrame: 0)
        let capacity = held + 4096
        let byteCount = capacity * Int(output.mBytesPerFrame)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { storage.deallocate() }
        var decoded = 0
        while true {
            var frames = UInt32(capacity - decoded)
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: output.mChannelsPerFrame, mDataByteSize: UInt32(byteCount - decoded * Int(output.mBytesPerFrame)), mData: storage)
            )
            guard AudioConverterFillComplexBuffer(converter, PacketFeed.supply, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil) == noErr,
                  frames > 0 else { break }
            decoded += Int(frames)
        }
        return max(0, held - decoded)
    }

    // how many 48 khz samples an opus packet holds, from its table-of-contents byte (rfc 6716, 3.1)
    private static func opusSamples(_ packet: UnsafeBufferPointer<UInt8>) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let tenthsOfMs: Int
        switch config {
        case 0..<12: tenthsOfMs = [100, 200, 400, 600][config & 3]
        case 12..<16: tenthsOfMs = [100, 200][config & 1]
        default: tenthsOfMs = [25, 50, 100, 200][config & 3]
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[1] & 0x3F) : 0
        }
        return frames * tenthsOfMs * 48 / 10
    }

    // apple's aac decoder takes its configuration as an mpeg-4 elementary stream descriptor, while
    // matroska stores just the audio specific config inside it
    private static func esds(_ config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            var out = Data([tag])
            var length = body.count
            var encoded: [UInt8] = []
            repeat {
                encoded.insert(UInt8(length & 0x7F), at: 0)
                length >>= 7
            } while length > 0
            for index in 0..<(encoded.count - 1) { encoded[index] |= 0x80 }
            out.append(contentsOf: encoded)
            out.append(body)
            return out
        }
        let decoderSpecific = descriptor(0x05, config)
        let decoderConfig = descriptor(0x04, Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + decoderSpecific)
        let slConfig = descriptor(0x06, Data([0x02]))
        return descriptor(0x03, Data([0, 0, 0]) + decoderConfig + slConfig)
    }

    fileprivate static func codecName(_ codecID: String) -> String {
        switch codecID {
        case "A_OPUS": return "Opus"
        case "A_VORBIS": return "Vorbis"
        case "A_FLAC": return "FLAC"
        case "A_MPEG/L3": return "MP3"
        default: return codecID.hasPrefix("A_AAC") ? "AAC" : (codecID.hasPrefix("A_") ? String(codecID.dropFirst(2)) : codecID)
        }
    }
}

// hands packets to the converter one at a time. the converter reads a packet after its callback returns,
// so each one is copied into storage that stays valid until the next callback.
nonisolated private final class PacketFeed {
    private let file: MatroskaFile
    private let packets: [MatroskaFile.Frame]
    private let channels: UInt32
    private let bytesPerFrame: Int
    private var index = 0
    private var current: UnsafeMutableRawPointer?
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    var hasPackets: Bool { !packets.isEmpty }
    var consumed: Int { index }

    init(_ file: MatroskaFile, _ packets: [MatroskaFile.Frame], channels: UInt32, bytesPerFrame: Int) {
        self.file = file
        self.packets = packets
        self.channels = channels
        self.bytesPerFrame = bytesPerFrame
    }

    deinit {
        current?.deallocate()
        description.deallocate()
    }

    static let supply: AudioConverterComplexInputDataProc = { _, packetCount, data, descriptions, context in
        let feed = Unmanaged<PacketFeed>.fromOpaque(context!).takeUnretainedValue()
        feed.current?.deallocate()
        feed.current = nil
        guard feed.index < feed.packets.count else {
            packetCount.pointee = 0
            data.pointee.mBuffers.mData = nil
            data.pointee.mBuffers.mDataByteSize = 0
            return noErr
        }
        let packet = feed.packets[feed.index]
        feed.index += 1
        let bytes = feed.file.data(of: packet)
        let copy = UnsafeMutableRawPointer.allocate(byteCount: max(1, bytes.count), alignment: 16)
        copy.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        feed.current = copy

        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mData = copy
        data.pointee.mBuffers.mDataByteSize = UInt32(bytes.count)
        data.pointee.mBuffers.mNumberChannels = feed.channels
        if feed.bytesPerFrame > 0 {
            packetCount.pointee = UInt32(bytes.count / feed.bytesPerFrame)
        } else {
            feed.description.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count)
            )
            descriptions?.pointee = feed.description
            packetCount.pointee = 1
        }
        return noErr
    }
}
