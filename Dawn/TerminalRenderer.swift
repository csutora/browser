import AppKit
import Metal
import QuartzCore
import WebKit

// shows a page in the terminal as kitty graphics by mirroring webkit's own layers.
//
// webkit keeps the page in this process as a tree of layers: the page itself as tiles it painted ahead of
// where it's scrolled to, fixed elements as layers of their own, and scrolling as nothing more than one
// layer's position changing. the terminal holds one image per layer and shows each where the layer is,
// so scrolling only moves images, and pixels are only sent when webkit paints something. a repaint is
// as small as what core animation reports damaged, and is sent as a patch over its tile until the
// patches would cost more than sending the whole tile again.
//
// whatever an image can't show the way core animation would (a layer that's rotating, translucent,
// masked, filtered, or animating) is composited here by core animation's own renderer, and that area of
// the composite is placed above everything else. content webkit hosts from its other processes, such as
// video, is snapshotted through webkit and placed above that.
final class TerminalRenderer: NSObject {
    private weak var webView: WKWebView?
    var output: ((Data) -> Void)?

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let copyPipeline: MTLComputePipelineState?
    private let hashPipeline: MTLComputePipelineState?
    private var hashes: MTLBuffer?
    private var composite: MTLTexture?
    private var staging: MTLBuffer?
    private var renderer: CARenderer?
    private let container = CALayer()

    private var runLoopObserver: CFRunLoopObserver?
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var timerDeadline = Double.infinity
    private var frameInterval = 1.0 / 60
    // a moment the display refreshed at, which frames are timed from; a display link gives one whenever
    // it's asked, then stops again
    private var displayLink: CADisplayLink?
    private var refreshedAt = 0.0
    private var lastSync = -Double.infinity
    private var lastFrame = 0.0
    private var activeUntil = 0.0
    private var stopped = false

    private var width = 0
    private var height = 0
    private var columns = 1
    private var rows = 1
    private var scale: CGFloat = 2

    // what the terminal holds: an image (and maybe a patch over it) for each layer, and shared memory it
    // hasn't acknowledged reading yet
    private var mirrors: [ObjectIdentifier: Mirror] = [:]
    private var scene: [Node] = []
    private var uploading = false
    // shared memory the terminal hasn't acknowledged reading yet, and how many bytes of pixels that is
    private var unacknowledged: [(name: String, bytes: Int)] = []
    private var unacknowledgedBytes = 0
    private var nextImageID = 1
    private var counter = 0
    private var lastEdges: Edges?
    private var unsentDamage = CGRect.null
    private var edgesStale = true

    private var hostedImages: [(id: Int, frame: CGRect)] = []
    private var hostedSnapshotPending = false
    private var hostedPixels: [UInt8] = []
    private var hostedInterval = 0.0
    private var nextHostedSnapshot = 0.0

    // the app group the sandbox lets shared memory be named under
    private static let sharedMemoryPrefix = "KKSNTMR4ML.dawn/"
    // composited areas stay above every mirrored layer, and hosted content above those
    private static let compositedLayer = 1 << 28
    private static let hostedLayer = 1 << 29
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let layerHostClass: AnyClass? = NSClassFromString("CALayerHost")

    // core animation's wrapper around the surfaces webkit paints layers into
    private typealias SurfaceGetter = @convention(c) (CFTypeRef) -> Unmanaged<IOSurfaceRef>?
    private typealias TypeIDGetter = @convention(c) () -> CFTypeID
    private static let surfaceOfContents: SurfaceGetter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CAIOSurfaceGetIOSurface")
        .map { unsafeBitCast($0, to: SurfaceGetter.self) }
    private static let contentsSurfaceType: CFTypeID? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CAIOSurfaceGetTypeID")
        .map { unsafeBitCast($0, to: TypeIDGetter.self)() }
    // 8-bit surfaces, including the gpu's losslessly compressed ones, which only the gpu can read
    private static let surfaceFormats: [OSType: MTLPixelFormat] = [
        0x4247_5241: .bgra8Unorm, // BGRA
        0x2642_4741: .bgra8Unorm, // &BGA
        0x5247_4241: .rgba8Unorm, // RGBA
    ]

    // copies a rectangle of a texture into a buffer as the straight-alpha rgba the terminal takes, and
    // hashes a texture's rows and columns
    private static let copySource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void copyRect(texture2d<float, access::read> source [[texture(0)]],
                         device uchar4 *out [[buffer(0)]],
                         constant uint4 &rect [[buffer(1)]],
                         uint2 p [[thread_position_in_grid]]) {
        if (p.x >= rect.z || p.y >= rect.w) return;
        float4 c = source.read(uint2(rect.x + p.x, rect.y + p.y));
        if (c.a > 0.0) c.rgb = min(c.rgb / c.a, 1.0);
        out[p.y * rect.z + p.x] = uchar4(round(saturate(c) * 255.0));
    }
    // one thread per row, then one per column, each hashing its pixels (fnv-1a)
    kernel void lineHashes(texture2d<float, access::read> source [[texture(0)]],
                           device ulong *out [[buffer(0)]],
                           uint i [[thread_position_in_grid]]) {
        uint w = source.get_width(), h = source.get_height();
        if (i >= w + h) return;
        bool row = i < h;
        uint count = row ? w : h;
        ulong hash = 1469598103934665603ul;
        for (uint k = 0; k < count; k++) {
            uint4 c = uint4(source.read(row ? uint2(k, i) : uint2(i - h, k)) * 255.0 + 0.5);
            hash = (hash ^ (c.r | c.g << 8 | c.b << 16 | c.a << 24)) * 1099511628211ul;
        }
        out[i] = hash;
    }
    """

    init(webView: WKWebView) {
        self.webView = webView
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        let library = try? device?.makeLibrary(source: Self.copySource, options: nil)
        copyPipeline = library?.makeFunction(name: "copyRect").flatMap { try? device?.makeComputePipelineState(function: $0) }
        hashPipeline = library?.makeFunction(name: "lineHashes").flatMap { try? device?.makeComputePipelineState(function: $0) }
        super.init()
        container.anchorPoint = .zero
        container.position = .zero
        container.isOpaque = true
        container.backgroundColor = .white
        timer.setEventHandler { [weak self] in
            self?.timerDeadline = .infinity
            self?.update()
        }
        timer.activate()
        // webkit commits its changes to the page's layers on the main thread, in step with the display, so
        // they're sent the moment a pass of the main run loop ends; holding one back to a frame boundary
        // could merge it with the next. a still page never wakes this.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { [weak self] _, _ in
            self?.update()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer
    }

    // MARK: Lifecycle

    func setScreen(_ screen: NSScreen) {
        frameInterval = 1 / Double(max(1, screen.maximumFramesPerSecond))
        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(displayRefreshed(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        refreshedAt = 0
        wake()
    }

    @objc private func displayRefreshed(_ link: CADisplayLink) {
        refreshedAt = link.timestamp
        if link.targetTimestamp > link.timestamp { frameInterval = link.targetTimestamp - link.timestamp }
        lastSync = CACurrentMediaTime()
        link.isPaused = true
    }

    // what webkit's scrolling thread moves (and what core animation animates) is looked at halfway
    // between refreshes. the scrolling thread moves the page right as the display refreshes, so by then
    // that frame's move has happened, and what's sent still reaches the terminal well before its next
    // refresh; looked at the same moment of every refresh, motion arrives as evenly as it was made. a
    // commit landing in between sees the same position, so it can't add a step of its own.
    private func nextFrameTime(after time: Double) -> Double {
        guard refreshedAt > 0 else { return time }
        let middle = refreshedAt + frameInterval / 2
        return middle + (((time - middle) / frameInterval).rounded(.down) + 1) * frameInterval
    }

    private func refreshTime(at time: Double) -> Double {
        guard refreshedAt > 0 else { return time }
        return refreshedAt + ((time - refreshedAt) / frameInterval).rounded(.down) * frameInterval
    }

    private func requestFrame() {
        schedule(nextFrameTime(after: CACurrentMediaTime()))
    }

    func resize(width: Int, height: Int, columns: Int, rows: Int, scale: CGFloat) {
        guard width != self.width || height != self.height || columns != self.columns || rows != self.rows || scale != self.scale,
              width > 0, height > 0, let device, let commandQueue else { return }
        self.width = width
        self.height = height
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scale = scale
        lastEdges = nil
        edgesStale = true
        unsentDamage = .null
        removeEverything()

        container.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // the page's points become terminal pixels, top down like the terminal and metal textures
        container.sublayerTransform = CATransform3DConcat(
            CATransform3DMakeScale(scale, -scale, 1), CATransform3DMakeTranslation(0, CGFloat(height), 0)
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        composite = device.makeTexture(descriptor: descriptor)
        if let composite {
            let renderer = CARenderer(mtlTexture: composite, options: [
                kCARendererMetalCommandQueue: commandQueue, kCARendererColorSpace: Self.colorSpace,
            ])
            renderer.layer = container
            renderer.bounds = container.bounds
            self.renderer = renderer
        }
        wake()
    }

    func stop() {
        stopped = true
        timer.cancel()
        displayLink?.invalidate()
        displayLink = nil
        if let runLoopObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes) }
        runLoopObserver = nil
        renderer = nil
        unacknowledged.forEach { shm_unlink($0.name) }
        unacknowledged.removeAll()
        unacknowledgedBytes = 0
    }

    func reply(ok: Bool) {
        trace("ack \(ok)")
        guard !unacknowledged.isEmpty else { return }
        let (name, bytes) = unacknowledged.removeFirst()
        unacknowledgedBytes -= bytes
        // the terminal unlinks what it read; an image it rejected is still ours to remove
        if !ok { shm_unlink(name) }
        requestFrame()
    }

    // input arrived, whose effect webkit's scrolling thread applies on its next frame without a pass of
    // the main run loop, so it's looked for over the next two frames
    func wake() {
        let now = CACurrentMediaTime()
        activeUntil = max(activeUntil, now + 2 * frameInterval)
        nextHostedSnapshot = 0
        requestFrame()
    }

    private func schedule(_ time: Double) {
        guard !stopped, time < timerDeadline else { return }
        timerDeadline = time
        timer.schedule(deadline: .now() + max(0, time - CACurrentMediaTime()), leeway: .microseconds(500))
    }

    // the terminal reads images in the order they're sent, about once per display frame, so more are sent
    // while it catches up as long as what it has yet to read is under a screenful: enough that a change
    // never waits on the one before it, never so much that the terminal falls behind
    private var canUpload: Bool {
        !uploading && unacknowledgedBytes < width * height * 4
    }

    private func removeEverything() {
        var command = ""
        for mirror in mirrors.values {
            for image in [mirror.base, mirror.patch].compactMap({ $0 }) { command += Self.delete(image.id) }
        }
        mirrors.removeAll()
        scene = []
        if !command.isEmpty { output?(Data(command.utf8)) }
    }

    // MARK: Frames

    // whenever webkit may have changed something: finds what core animation damaged, walks webkit's
    // layers, sends what changed and places everything where it now is. webkit's commits don't arrive
    // exactly a frame apart, so holding one back to keep to a frame's pace would merge it into the next
    // and make the page skip; each one is sent as it comes, and the terminal shows the latest.
    private func update() {
        guard !stopped, width > 0, let webView, let pageLayer = webView.layer, let renderer, let composite else { return }
        let now = CACurrentMediaTime()
        // appkit owns the view's layer and could hand it back to the invisible window; it belongs here
        if pageLayer.superlayer !== container {
            pageLayer.removeFromSuperlayer()
            container.addSublayer(pageLayer)
        }
        // animations are looked at as of the display's latest refresh, so however many times this runs
        // between two refreshes, an animation is drawn (and sent) once per refresh, a frame's step apart
        renderer.beginFrame(atTime: refreshTime(at: now), timeStamp: nil)
        let damage = renderer.updateBounds().intersection(container.bounds).integral
        let previous = scene
        scene = buildScene()
        // where a composited area is comes from its animations as of now, but it's drawn as of the latest
        // refresh; with nothing newly drawn, what it showed is still exactly right where it was
        if damage.isEmpty {
            let before = Dictionary(previous.filter(\.kind.isComposited).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            scene = scene.map { node in node.kind.isComposited ? before[node.key] ?? node : node }
        }
        let changed = !damage.isEmpty || scene.count != previous.count || zip(scene, previous).contains { !$0.sameGeometry(as: $1) }
        if changed {
            var kinds = (surfaces: 0, colors: 0, composited: 0, hosted: 0, waiting: 0, compositedArea: 0)
            for node in scene {
                switch node.kind {
                case .surface: kinds.surfaces += 1
                case .color: kinds.colors += 1
                case .composited:
                    kinds.composited += 1
                    kinds.compositedArea += Int(node.frame.width * node.frame.height)
                case .hosted: kinds.hosted += 1
                }
                if let mirror = mirrors[node.key], mirror.needsUpload(node), !node.visible.isEmpty { kinds.waiting += 1 }
            }
            let moved = zip(scene, previous).filter { $0.key == $1.key && $0.frame != $1.frame }.count
            func contentRoot(_ layer: CALayer) -> CALayer? {
                if layer.name == "content root" { return layer }
                for sublayer in layer.sublayers ?? [] { if let found = contentRoot(sublayer) { return found } }
                return nil
            }
            let tileY = webView.layer.flatMap(contentRoot).map { $0.convert(CGPoint.zero, to: nil).y } ?? .nan
            let phase = refreshedAt > 0 ? (now - refreshedAt).truncatingRemainder(dividingBy: frameInterval) * 1000 : -1
            trace("frame phase=\(String(format: "%.1f", phase)) synced=\(String(format: "%.1f", now - lastSync)) tileY=\(Int(tileY.isNaN ? -99999 : tileY)) damage=\(damage.isEmpty ? "-" : "\(Int(damage.width))x\(Int(damage.height))") surfaces=\(kinds.surfaces) colors=\(kinds.colors) composited=\(kinds.composited) compositedArea=\(kinds.compositedArea) hosted=\(kinds.hosted) moved=\(moved) waitingVisible=\(kinds.waiting) uploading=\(uploading) unacked=\(unacknowledgedBytes)")
        }
        if changed {
            lastFrame = now
            activeUntil = max(activeUntil, now + 2 * frameInterval)
            nextHostedSnapshot = 0
        }

        if !damage.isEmpty, !container.bounds.insetBy(dx: 1, dy: 1).contains(damage) { edgesStale = true }
        // core animation reports damage once, so what can't be sent yet is kept until it can
        unsentDamage = unsentDamage.union(damage)
        let canUpload = self.canUpload
        let jobs = uploadsNeeded(damage: unsentDamage)
        if canUpload { unsentDamage = .null }
        // core animation only composites what's needed: the areas being sent from the composite, and the
        // frame's edges, which say what color the terminal's padding should be
        let edges = canUpload && edgesStale
        var rendered = jobs.compactMap { $0.source.isComposite ? $0.copied : nil }
        if edges { rendered += edgeLines }
        for rect in rendered { renderer.addUpdate(rect) }
        if !rendered.isEmpty { renderer.render() }
        renderer.endFrame()

        place()
        if canUpload, !jobs.isEmpty || edges {
            edgesStale = false
            upload(jobs, edges: edges, from: composite)
        }
        if !hostedImages.isEmpty || scene.contains(where: { if case .hosted = $0.kind { true } else { false } }) { refreshHostedContent() }

        let animation = renderer.nextFrameTime()
        let pending = scene.contains { node in mirrors[node.key].map { $0.needsUpload(node) } ?? true }
        let hosting = !hostedImages.isEmpty || scene.contains { if case .hosted = $0.kind { true } else { false } }
        let active = now < activeUntil || ((pending || edgesStale) && canUpload)
        // the display link's clock and this one drift apart by a little each frame, so while frames keep
        // coming they're timed afresh from the display about once a second
        if active || animation.isFinite || hosting, now - lastSync > 1 { displayLink?.isPaused = false }
        if active {
            schedule(nextFrameTime(after: now))
        } else if animation.isFinite || hosting {
            schedule(nextFrameTime(after: max(now, min(animation, hosting ? nextHostedSnapshot : .infinity))))
        } else {
            #if DEBUG
            writeTruthWhenStill()
            #endif
        }
    }

    // MARK: Scene

    private struct Node {
        enum Kind {
            case surface(IOSurfaceRef, contents: AnyObject, format: MTLPixelFormat)
            case color(UInt32)
            // shown from the composite
            case composited
            case hosted

            var isComposited: Bool { if case .composited = self { true } else { false } }
        }

        let key: ObjectIdentifier
        weak var layer: CALayer?
        let kind: Kind
        // where the layer's image is, in terminal pixels, and the part of it that shows
        let frame: CGRect
        let visible: CGRect
        let z: Int

        func sameGeometry(as other: Node) -> Bool {
            key == other.key && frame == other.frame && visible == other.visible && z == other.z
        }
    }

    // webkit's layers in drawing order, each either mirrored as an image of its own or, along with
    // everything it contains, shown from the composite
    private func buildScene() -> [Node] {
        guard let root = webView?.layer else { return [] }
        var nodes: [Node] = []
        var order = 0
        var compositedOrder = 0

        func composited(_ layer: CALayer, clip: CGRect) {
            let region = Self.extent(of: layer).intersection(clip).integral.intersection(clip)
            guard !region.isEmpty else { return }
            nodes.append(Node(key: ObjectIdentifier(layer), layer: layer, kind: .composited, frame: region, visible: region, z: Self.compositedLayer + 2 * compositedOrder))
            compositedOrder += 1
            // the composite can't show hosted content, wherever it is in what's composited
            func findHosted(_ layer: CALayer, clip: CGRect) {
                guard !layer.isHidden else { return }
                if let host = Self.layerHostClass, layer.isKind(of: host) { return hosted(layer, clip: clip) }
                let inner = layer.masksToBounds ? clip.intersection(layer.convert(layer.bounds, to: nil)) : clip
                for sublayer in layer.sublayers ?? [] { findHosted(sublayer, clip: inner) }
            }
            findHosted(layer, clip: clip)
        }

        func hosted(_ layer: CALayer, clip: CGRect) {
            let frame = layer.convert(layer.bounds, to: nil).integral.intersection(clip)
            if !frame.isEmpty {
                nodes.append(Node(key: ObjectIdentifier(layer), layer: layer, kind: .hosted, frame: frame, visible: frame, z: Self.hostedLayer))
            }
        }

        func visit(_ layer: CALayer, clip: CGRect) {
            guard !layer.isHidden else { return }
            let animated = !(layer.animationKeys()?.isEmpty ?? true)
            guard layer.opacity > 0 || animated else { return }
            if let host = Self.layerHostClass, layer.isKind(of: host) { return hosted(layer, clip: clip) }
            guard !animated, layer.opacity == 1, Self.drawsOnlyContentsAndBackground(layer) else { return composited(layer, clip: clip) }
            // a layer that draws or clips has to be upright on whole pixels to be mirrored; one that does
            // neither only passes its geometry on, and what's in it is judged on its own
            let draws = layer.contents != nil || (layer.backgroundColor?.alpha ?? 0) > 0
            let origin = pixelOrigin(of: layer)
            if origin == nil, draws || layer.masksToBounds { return composited(layer, clip: clip) }
            let frame = origin.map {
                CGRect(x: $0.x, y: $0.y, width: (layer.bounds.width * scale).rounded(), height: (layer.bounds.height * scale).rounded())
            } ?? .null
            let visible = frame.intersection(clip)

            if let contents = layer.contents {
                guard Self.hasNoBackground(layer), let surface = Self.surface(of: contents), let format = Self.surfaceFormats[IOSurfaceGetPixelFormat(surface)],
                      abs(CGFloat(IOSurfaceGetWidth(surface)) - frame.width) <= 1, abs(CGFloat(IOSurfaceGetHeight(surface)) - frame.height) <= 1,
                      layer.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1)
                else { return composited(layer, clip: clip) }
                let imageFrame = CGRect(x: frame.minX, y: frame.minY, width: CGFloat(IOSurfaceGetWidth(surface)), height: CGFloat(IOSurfaceGetHeight(surface)))
                nodes.append(Node(key: ObjectIdentifier(layer), layer: layer, kind: .surface(surface, contents: contents as AnyObject, format: format),
                                  frame: imageFrame, visible: imageFrame.intersection(clip), z: 2 * order + 1))
                order += 1
            } else if let color = Self.solidColor(of: layer), !visible.isEmpty {
                // a color is the same everywhere, so any part of its image can show any part of the layer: it's
                // sent once as large as the layer could ever show, and the part that shows is cropped from it,
                // so a layer sliding in or out of view (as the page overscrolls) moves without being resent
                let size = CGSize(width: min(frame.width, container.bounds.width), height: min(frame.height, container.bounds.height))
                nodes.append(Node(key: ObjectIdentifier(layer), layer: layer, kind: .color(color), frame: CGRect(origin: visible.origin, size: size),
                                  visible: visible, z: 2 * order + 1))
                order += 1
            }

            let inner = layer.masksToBounds ? clip.intersection(frame) : clip
            guard !inner.isEmpty || !layer.masksToBounds, var sublayers = layer.sublayers else { return }
            if sublayers.contains(where: { $0.zPosition != 0 }) {
                sublayers = sublayers.enumerated().sorted { ($0.element.zPosition, $0.offset) < ($1.element.zPosition, $1.offset) }.map(\.element)
            }
            for sublayer in sublayers { visit(sublayer, clip: inner) }
        }

        visit(root, clip: container.bounds)
        return nodes
    }

    // where a layer's top left corner is in terminal pixels, if the layer is drawn upright at the
    // terminal's scale on whole pixels, which is when an image of its contents can stand in for it
    private func pixelOrigin(of layer: CALayer) -> CGPoint? {
        let bounds = layer.bounds
        let origin = layer.convert(bounds.origin, to: nil)
        let right = layer.convert(CGPoint(x: bounds.minX + 1, y: bounds.minY), to: nil)
        let down = layer.convert(CGPoint(x: bounds.minX, y: bounds.minY + 1), to: nil)
        let tolerance = scale / 1000
        guard abs(right.x - origin.x - scale) < tolerance, abs(right.y - origin.y) < tolerance,
              abs(down.y - origin.y - scale) < tolerance, abs(down.x - origin.x) < tolerance else { return nil }
        let rounded = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        guard abs(rounded.x - origin.x) < 0.01, abs(rounded.y - origin.y) < 0.01 else { return nil }
        return rounded
    }

    // whether a layer draws nothing but its contents and background color, with nothing applied to them
    private static func drawsOnlyContentsAndBackground(_ layer: CALayer) -> Bool {
        // a transform layer draws nothing and only differs from a plain one in three dimensions, which a
        // flat one (as webkit uses them to anchor fixed elements) never reaches
        let flatTransformLayer = layer is CATransformLayer && CATransform3DIsAffine(layer.transform) && CATransform3DIsAffine(layer.sublayerTransform)
            && (layer.sublayers ?? []).allSatisfy { CATransform3DIsAffine($0.transform) && $0.zPosition == 0 }
        guard flatTransformLayer || drawsLikeCALayer(type(of: layer)) else { return false }
        return layer.mask == nil && (layer.filters?.isEmpty ?? true) && (layer.backgroundFilters?.isEmpty ?? true)
            && layer.compositingFilter == nil && layer.borderWidth == 0 && layer.shadowOpacity == 0
            && (layer.cornerRadius == 0 || (layer.contents == nil && (layer.backgroundColor?.alpha ?? 0) == 0 && !layer.masksToBounds))
            && layer.contentsCenter == CGRect(x: 0, y: 0, width: 1, height: 1)
            && (layer.contents == nil || layer.contentsGravity == .resize)
    }

    // calayer itself, and webkit's and appkit's subclasses of it that add no drawing of their own. the
    // first class past theirs has to be calayer, since anything else (backdrops, shapes, gradients, text)
    // draws something an image of the contents wouldn't show.
    private static var classesDrawingLikeCALayer: [ObjectIdentifier: Bool] = [:]
    private static func drawsLikeCALayer(_ type: AnyClass) -> Bool {
        if let known = classesDrawingLikeCALayer[ObjectIdentifier(type)] { return known }
        var current: AnyClass? = type
        while let candidate = current, candidate != CALayer.self {
            let name = NSStringFromClass(candidate)
            guard name.hasPrefix("WK") || name == "NSViewBackingLayer" else { break }
            current = class_getSuperclass(candidate)
        }
        let result = current == CALayer.self
        classesDrawingLikeCALayer[ObjectIdentifier(type)] = result
        return result
    }

    private static func hasNoBackground(_ layer: CALayer) -> Bool {
        (layer.backgroundColor?.alpha ?? 0) == 0
    }

    private static func surface(of contents: Any) -> IOSurfaceRef? {
        let object = contents as CFTypeRef
        if CFGetTypeID(object) == IOSurfaceGetTypeID() { return unsafeBitCast(object, to: IOSurfaceRef.self) }
        guard let contentsSurfaceType, CFGetTypeID(object) == contentsSurfaceType else { return nil }
        return surfaceOfContents?(object)?.takeUnretainedValue()
    }

    // a background color as srgb with straight alpha, packed rgba
    private static func solidColor(of layer: CALayer) -> UInt32? {
        guard let color = layer.backgroundColor, color.alpha > 0,
              let srgb = color.converted(to: colorSpace, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 4 else { return nil }
        let bytes = c.prefix(4).map { UInt32((max(0, min(1, $0)) * 255).rounded()) }
        return bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
    }

    // the area a layer and everything in it covers as it's shown right now, animations included
    private static func extent(of layer: CALayer) -> CGRect {
        // the layer as it's shown, placed by its parent as the parent actually is
        let shown = layer.presentation() ?? layer
        var rect = shown.convert(shown.bounds, to: shown.superlayer)
        if let parent = layer.superlayer { rect = parent.convert(rect, to: nil) }
        if shown.shadowOpacity > 0 {
            // a shadow's blur fades out within three times its radius, past wherever it's offset to
            let reach = shown.shadowRadius * 3 + max(abs(shown.shadowOffset.width), abs(shown.shadowOffset.height))
            rect = rect.insetBy(dx: -reach, dy: -reach)
        }
        if !shown.masksToBounds {
            for sublayer in layer.sublayers ?? [] where !sublayer.isHidden { rect = rect.union(extent(of: sublayer)) }
        }
        return rect
    }

    // MARK: Mirrors

    private struct Image {
        let id: Int
        let size: CGSize
        var placement: String?
    }

    private final class Mirror {
        weak var layer: CALayer?
        var base: Image?
        // a later repaint of part of the base, at this rectangle of it
        var patch: Image?
        var patchRect = CGRect.null
        // what patches since the base have spent re-sending what hadn't changed
        var patchWaste = 0
        // what the images show: the surface (kept, so it can't be mistaken for a new one at the same
        // address) and a hash of each of its rows and columns, the color, or where a composited area was
        var contents: AnyObject?
        var lines: [UInt64] = []
        var color: UInt32?
        var frame = CGRect.null
        var uploading = false

        init(_ layer: CALayer?) { self.layer = layer }

        func needsUpload(_ node: Node) -> Bool {
            switch node.kind {
            case .surface(_, let contents, _):
                return base == nil || self.contents !== contents || base!.size != node.frame.size
            case .color(let color):
                return base == nil || self.color != color || base!.size != node.frame.size
            case .composited:
                return base == nil || frame != node.frame
            case .hosted:
                return false
            }
        }
    }

    private enum Source {
        case surface(IOSurfaceRef, format: MTLPixelFormat)
        case composite
        case color(UInt32)
        var isComposite: Bool { if case .composite = self { true } else { false } }
    }

    // one image's worth of work: a rectangle of the source copied into staging, which becomes all or
    // part of a mirror's image
    private struct Job {
        let key: ObjectIdentifier
        let source: Source
        // what's copied, in source pixels (for the composite, terminal pixels)
        let copied: CGRect
        // where the mirror's image is, in terminal pixels
        let frame: CGRect
        // for the composite, whether what's copied patches the image; a surface's changed rows and columns
        // decide that once they're hashed
        let asPatch: Bool
        let contents: AnyObject?
        let color: UInt32?
        var offset = 0
        var hashOffset = 0
        var bytes: Int { Int(copied.width) * Int(copied.height) * 4 }
    }

    private func uploadsNeeded(damage: CGRect) -> [Job] {
        // anything no longer in the scene goes
        let current = Set(scene.map(\.key))
        var command = ""
        for (key, mirror) in mirrors where !current.contains(key) || mirror.layer == nil {
            guard !mirror.uploading else { continue }
            for image in [mirror.base, mirror.patch].compactMap({ $0 }) { command += Self.delete(image.id) }
            mirrors[key] = nil
        }
        if !command.isEmpty { output?(Data(command.utf8)) }

        // no more than the terminal can keep up with
        guard canUpload else { return [] }
        var jobs: [Job] = []
        var offscreen: Job?
        for node in scene {
            let mirror: Mirror
            if let existing = mirrors[node.key], existing.layer === node.layer {
                mirror = existing
            } else {
                if let old = mirrors[node.key] {
                    output?(Data([old.base, old.patch].compactMap { $0 }.map { Self.delete($0.id) }.joined().utf8))
                }
                mirror = Mirror(node.layer)
                mirrors[node.key] = mirror
            }
            guard !mirror.uploading else { continue }
            let full = CGRect(origin: .zero, size: node.frame.size)
            switch node.kind {
            case .surface(let surface, let contents, let format):
                guard mirror.needsUpload(node) else { continue }
                let job = Job(key: node.key, source: .surface(surface, format: format), copied: full, frame: node.frame, asPatch: false,
                              contents: contents, color: nil)
                // layers out of view are sent ahead of time, one at a time, when nothing in view needs sending
                if node.visible.isEmpty {
                    if offscreen == nil { offscreen = job }
                } else {
                    jobs.append(job)
                }
            case .color(let color):
                guard mirror.needsUpload(node) else { continue }
                jobs.append(Job(key: node.key, source: .color(color), copied: full, frame: node.frame, asPatch: false, contents: nil, color: color))
            case .composited:
                if mirror.needsUpload(node) {
                    jobs.append(Job(key: node.key, source: .composite, copied: node.frame, frame: node.frame, asPatch: false, contents: nil, color: nil))
                    continue
                }
                // an area that stayed put only needs what core animation reports damaged
                let dirty = damage.intersection(node.frame).offsetBy(dx: -node.frame.minX, dy: -node.frame.minY)
                guard !dirty.isEmpty else { continue }
                let rect = patchOrWhole(mirror, dirty: dirty, size: node.frame.size)
                jobs.append(Job(key: node.key, source: .composite, copied: rect.offsetBy(dx: node.frame.minX, dy: node.frame.minY), frame: node.frame,
                                asPatch: rect != full, contents: nil, color: nil))
            case .hosted:
                continue
            }
        }
        if jobs.isEmpty, let offscreen { jobs.append(offscreen) }
        return jobs
    }

    // what to send of an image whose dirty part is known. a patch replaces the one before it, so it has to
    // cover that one too, and what it covers beyond what just changed is sent for nothing; sending the
    // whole image starts over with no patch. so patches go on until what they've sent for nothing would
    // pay for the whole image, which keeps the total within twice the best that could have been done
    // knowing what was coming. a box that changes over and over (a transition, a caret blinking in
    // place) wastes nothing and stays a patch.
    private func patchOrWhole(_ mirror: Mirror, dirty: CGRect, size: CGSize) -> CGRect {
        let patch = mirror.patchRect.isNull ? dirty : mirror.patchRect.union(dirty)
        let waste = Int(patch.width * patch.height - dirty.width * dirty.height) * 4
        guard mirror.patchWaste + waste < Int(size.width * size.height) * 4 else { return CGRect(origin: .zero, size: size) }
        mirror.patchWaste += waste
        return patch
    }

    // MARK: Sending

    private var edgeLines: [CGRect] {
        [CGRect(x: 0, y: 0, width: width, height: 1), CGRect(x: 0, y: height - 1, width: width, height: 1),
         CGRect(x: 0, y: 0, width: 1, height: height), CGRect(x: width - 1, y: 0, width: 1, height: height)]
    }

    // one gpu pass copies every image's pixels (and the frame's edges) into staging as rgba, and hashes
    // every row and column of each surface; once it's done, what changed goes to the terminal through
    // shared memory
    private func upload(_ jobs: [Job], edges: Bool, from composite: MTLTexture) {
        guard let device, let copyPipeline, let hashPipeline, let commands = commandQueue?.makeCommandBuffer() else { return }
        var jobs = jobs
        var length = 0
        var hashCount = 0
        for index in jobs.indices {
            jobs[index].offset = length
            jobs[index].hashOffset = hashCount
            switch jobs[index].source {
            case .color: continue
            case .surface: hashCount += Int(jobs[index].copied.width + jobs[index].copied.height)
            case .composite: break
            }
            length += jobs[index].bytes
        }
        let edgeOffset = length
        if edges { length += (2 * width + 2 * height) * 4 }
        if staging == nil || staging!.length < length {
            staging = device.makeBuffer(length: max(length, staging?.length ?? 0, width * height * 4), options: .storageModeShared)
        }
        if hashCount > 0, hashes == nil || hashes!.length < hashCount * 8 {
            hashes = device.makeBuffer(length: max(hashCount * 8, (hashes?.length ?? 0) * 2), options: .storageModeShared)
        }
        guard let staging, let encoder = commands.makeComputeCommandEncoder() else { return }

        func copy(_ texture: MTLTexture, _ rect: CGRect, to offset: Int) {
            var bounds = SIMD4<UInt32>(UInt32(rect.minX), UInt32(rect.minY), UInt32(rect.width), UInt32(rect.height))
            encoder.setComputePipelineState(copyPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(staging, offset: offset, index: 0)
            encoder.setBytes(&bounds, length: MemoryLayout<SIMD4<UInt32>>.size, index: 1)
            encoder.dispatchThreads(MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        for job in jobs {
            switch job.source {
            case .surface(let surface, let format):
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: IOSurfaceGetWidth(surface),
                                                                         height: IOSurfaceGetHeight(surface), mipmapped: false)
                descriptor.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { continue }
                copy(texture, job.copied, to: job.offset)
                encoder.setComputePipelineState(hashPipeline)
                encoder.setTexture(texture, index: 0)
                encoder.setBuffer(hashes, offset: job.hashOffset * 8, index: 0)
                encoder.dispatchThreads(MTLSize(width: texture.width + texture.height, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: min(256, hashPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            case .composite:
                copy(composite, job.copied, to: job.offset)
            case .color:
                continue
            }
        }
        if edges {
            var offset = edgeOffset
            for line in edgeLines {
                copy(composite, line, to: offset)
                offset += Int(line.width * line.height) * 4
            }
        }
        encoder.endEncoding()

        for job in jobs { mirrors[job.key]?.uploading = true }
        trace("batch jobs=\(jobs.count) copied=\(jobs.reduce(0) { $0 + $1.bytes })")
        uploading = true
        commands.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.uploading = false
                self.send(jobs, edges: edges ? self.edges(at: edgeOffset) : nil)
                self.requestFrame()
            }
        }
        commands.commit()
    }

    private func send(_ jobs: [Job], edges: Edges?) {
        var command = ""
        if let edges, edges != lastEdges {
            command += Self.edgeFill(edges, previous: lastEdges, columns: columns, rows: rows)
            lastEdges = edges
        }
        let source = staging!.contents()
        for job in jobs {
            // a mirror replaced or removed while its pixels were being copied keeps nothing of them
            guard let mirror = mirrors[job.key], mirror.uploading else { continue }
            mirror.uploading = false
            let size = job.frame.size
            let whole = CGRect(origin: .zero, size: size)
            // the rectangle of the image to send, and where staging holds it
            var rect = whole
            var asPatch = false
            var copiedInImage = job.copied
            switch job.source {
            case .surface:
                // the rows and columns whose hashes changed bound exactly what the repaint changed
                let w = Int(job.copied.width), h = Int(job.copied.height)
                let lines = Array(UnsafeBufferPointer(start: hashes!.contents().assumingMemoryBound(to: UInt64.self) + job.hashOffset, count: w + h))
                defer { mirror.lines = lines }
                mirror.contents = job.contents
                if mirror.base?.size == size, mirror.lines.count == lines.count {
                    let rows = (0..<h).filter { lines[$0] != mirror.lines[$0] }
                    let columns = (0..<w).filter { lines[h + $0] != mirror.lines[h + $0] }
                    guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else { continue }
                    rect = patchOrWhole(mirror, dirty: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1), size: size)
                    asPatch = rect != whole
                }
            case .composite:
                copiedInImage = job.copied.offsetBy(dx: -job.frame.minX, dy: -job.frame.minY)
                rect = copiedInImage
                asPatch = job.asPatch
            case .color:
                break
            }

            let w = Int(rect.width), h = Int(rect.height)
            trace("transmit \(job.source.isComposite ? "composite" : (job.color != nil ? "color" : "surface")) \(w)x\(h) patch=\(asPatch)")
            let name = nextSharedMemoryName()
            guard let memory = Self.createSharedMemory(name, byteCount: w * h * 4) else { continue }
            if case .color(let color) = job.source {
                var pixel = color.bigEndian
                memset_pattern4(memory, &pixel, w * h * 4)
            } else {
                let stride = Int(copiedInImage.width) * 4
                let start = source + job.offset + (Int(rect.minY - copiedInImage.minY) * Int(copiedInImage.width) + Int(rect.minX - copiedInImage.minX)) * 4
                for row in 0..<h { memory.advanced(by: row * w * 4).copyMemory(from: start + row * stride, byteCount: w * 4) }
            }
            munmap(memory, w * h * 4)
            let image = Image(id: nextImageID, size: rect.size)
            nextImageID += 1
            command += "\u{1b}_Ga=t,f=32,t=s,s=\(w),v=\(h),S=\(w * h * 4),i=\(image.id),q=0;\(Data(name.utf8).base64EncodedString())\u{1b}\\"
            unacknowledged.append((name, w * h * 4))
            unacknowledgedBytes += w * h * 4
            if asPatch {
                if let old = mirror.patch { command += Self.delete(old.id) }
                mirror.patch = image
                mirror.patchRect = rect
            } else {
                for old in [mirror.base, mirror.patch].compactMap({ $0 }) { command += Self.delete(old.id) }
                mirror.base = image
                mirror.patch = nil
                mirror.patchRect = .null
                mirror.patchWaste = 0
            }
            mirror.color = job.color
            mirror.frame = job.frame
        }
        command += placements()
        if !command.isEmpty { output?(Data(("\u{1b}[?2026h" + command + "\u{1b}[?2026l").utf8)) }
    }

    // places every image where its layer now is, sending only what moved
    private func place() {
        let command = placements()
        if !command.isEmpty { trace("place bytes=\(command.utf8.count)") }
        if !command.isEmpty { output?(Data(("\u{1b}[?2026h" + command + "\u{1b}[?2026l").utf8)) }
    }

    private func placements() -> String {
        var command = ""
        for node in scene {
            guard let mirror = mirrors[node.key] else { continue }
            // a composited area shows where it was taken from until its replacement arrives
            let frame = node.kind.isComposited ? mirror.frame : node.frame
            let visible = node.kind.isComposited ? mirror.frame : node.visible
            if var base = mirror.base {
                command += placement(of: &base, at: frame, visible: visible, z: node.z)
                mirror.base = base
            }
            if var patch = mirror.patch {
                let patchFrame = mirror.patchRect.offsetBy(dx: frame.minX, dy: frame.minY)
                command += placement(of: &patch, at: patchFrame, visible: visible.intersection(patchFrame), z: node.z + 1)
                mirror.patch = patch
            }
        }
        return command
    }

    // an image is placed at the cell holding the top left corner of the part of it that shows, offset
    // within that cell, and cropped to that part
    private func placement(of image: inout Image, at position: CGRect, visible: CGRect, z: Int) -> String {
        // an image waiting to be replaced by one of a new size shows as much of itself as it has
        let frame = CGRect(origin: position.origin, size: image.size)
        let shown = visible.intersection(frame).intersection(container.bounds)
        guard !shown.isEmpty else {
            guard image.placement != nil else { return "" }
            image.placement = nil
            return "\u{1b}_Ga=d,d=i,i=\(image.id),q=2\u{1b}\\"
        }
        let cellWidth = max(1, width / columns)
        let cellHeight = max(1, height / rows)
        let x = Int(shown.minX), y = Int(shown.minY)
        let command = "\u{1b}[\(y / cellHeight + 1);\(x / cellWidth + 1)H\u{1b}_Ga=p,i=\(image.id),p=1,"
            + "x=\(x - Int(frame.minX)),y=\(y - Int(frame.minY)),w=\(Int(shown.width)),h=\(Int(shown.height)),"
            + "X=\(x % cellWidth),Y=\(y % cellHeight),z=\(z),C=1,q=2\u{1b}\\"
        guard command != image.placement else { return "" }
        image.placement = command
        return command
    }

    private static func delete(_ id: Int) -> String {
        "\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\"
    }

    private func nextSharedMemoryName() -> String {
        counter += 1
        return Self.sharedMemoryPrefix + String(getpid(), radix: 36) + "-" + String(counter, radix: 36)
    }

    private static func createSharedMemory(_ name: String, byteCount: Int) -> UnsafeMutableRawPointer? {
        let fd = dawn_shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, off_t(byteCount)) == 0,
              let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED
        else {
            shm_unlink(name)
            return nil
        }
        return mapped
    }

    // MARK: Hosted content

    // webkit's snapshots include hosted content, so a hosted region is refreshed from one, one at a time,
    // every frame while it changes. each snapshot that shows no change doubles the wait for the next, up
    // to a second, and any change on the page or input brings it back to every frame, since that's what
    // starts and stops video.
    private func refreshHostedContent() {
        guard !hostedSnapshotPending, CACurrentMediaTime() >= nextHostedSnapshot, let webView else { return }
        let regions = scene.compactMap { node -> CGRect? in if case .hosted = node.kind { node.frame } else { nil } }
        let stale = hostedImages.filter { !regions.contains($0.frame) }
        if !stale.isEmpty {
            output?(Data(stale.map { Self.delete($0.id) }.joined().utf8))
            hostedImages.removeAll { image in stale.contains { $0.id == image.id } }
        }
        guard let region = regions.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: region.minX / scale, y: region.minY / scale, width: region.width / scale, height: region.height / scale)
        configuration.snapshotWidth = NSNumber(value: Double(region.width) / Double(webView.window?.backingScaleFactor ?? scale))
        hostedSnapshotPending = true
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            self.hostedSnapshotPending = false
            guard !self.stopped, let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let w = Int(region.width), h = Int(region.height)
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Self.colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) else { return }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            if self.hostedImages.contains(where: { $0.frame == region }), pixels == self.hostedPixels {
                self.hostedInterval = min(1, max(self.frameInterval, self.hostedInterval * 2))
                self.nextHostedSnapshot = CACurrentMediaTime() + self.hostedInterval
                return
            }
            self.hostedInterval = self.frameInterval
            self.hostedPixels = pixels
            let name = self.nextSharedMemoryName()
            guard let memory = Self.createSharedMemory(name, byteCount: w * h * 4) else { return }
            pixels.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: w * h * 4) }
            munmap(memory, w * h * 4)
            var image = Image(id: self.nextImageID, size: region.size)
            self.nextImageID += 1
            var command = "\u{1b}[?2026h\u{1b}_Ga=t,f=32,t=s,s=\(w),v=\(h),S=\(w * h * 4),i=\(image.id),q=0;\(Data(name.utf8).base64EncodedString())\u{1b}\\"
            command += self.placement(of: &image, at: region, visible: region, z: Self.hostedLayer + image.id % (1 << 20))
            for old in self.hostedImages where region.contains(old.frame) { command += Self.delete(old.id) }
            self.hostedImages.removeAll { region.contains($0.frame) }
            self.hostedImages.append((image.id, region))
            command += "\u{1b}[?2026l"
            self.unacknowledged.append((name, w * h * 4))
            self.unacknowledgedBytes += w * h * 4
            self.output?(Data(command.utf8))
        }
    }

    // MARK: Edges

    struct Edges: Equatable {
        var top: [UInt32]
        var bottom: [UInt32]
        var left: [UInt32]
        var right: [UInt32]
        var dominant: UInt32
    }

    // the frame's outermost rows and columns, copied into staging after the images, say what color the
    // terminal's padding should be
    private func edges(at offset: Int) -> Edges? {
        guard let staging else { return nil }
        let pixels = staging.contents().advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        let lines = [width, width, height, height]
        var starts: [Int] = []
        var position = 0
        for count in lines {
            starts.append(position)
            position += count
        }
        func average(_ line: Int, _ start: Int, _ span: Int) -> UInt32 {
            let points = [start + span / 4, start + span / 2, start + span * 3 / 4].map { (starts[line] + min($0, lines[line] - 1)) * 4 }
            let r = points.reduce(0) { $0 + Int(pixels[$1]) } / 3
            let g = points.reduce(0) { $0 + Int(pixels[$1 + 1]) } / 3
            let b = points.reduce(0) { $0 + Int(pixels[$1 + 2]) } / 3
            return UInt32(r << 16 | g << 8 | b)
        }
        let cellWidth = max(1, width / columns)
        let cellHeight = max(1, height / rows)
        var edges = Edges(
            top: (0..<columns).map { average(0, $0 * cellWidth, cellWidth) },
            bottom: (0..<columns).map { average(1, $0 * cellWidth, cellWidth) },
            left: (0..<rows).map { average(2, $0 * cellHeight, cellHeight) },
            right: (0..<rows).map { average(3, $0 * cellHeight, cellHeight) },
            dominant: 0
        )
        var counts: [UInt32: Int] = [:]
        for color in edges.top + edges.bottom + edges.left + edges.right { counts[color, default: 0] += 1 }
        edges.dominant = counts.max { $0.value < $1.value }?.key ?? 0
        return edges
    }

    // the terminal pads its text area, and the cells along the edges are what that padding takes its
    // color from, so they get the page's edge colors; the page's frame lies over the cells themselves.
    // the default background follows the page too, for terminals that pad with that instead.
    private static func edgeFill(_ edges: Edges, previous: Edges?, columns: Int, rows: Int) -> String {
        var out = ""
        func cell(_ row: Int, _ column: Int, _ color: UInt32) {
            out += "\u{1b}[\(row + 1);\(column + 1)H\u{1b}[48;2;\(color >> 16 & 0xFF);\(color >> 8 & 0xFF);\(color & 0xFF)m "
        }
        for column in 0..<columns {
            if previous?.top[column] != edges.top[column] { cell(0, column, edges.top[column]) }
            if previous?.bottom[column] != edges.bottom[column] { cell(rows - 1, column, edges.bottom[column]) }
        }
        for row in 0..<rows {
            if previous?.left[row] != edges.left[row] { cell(row, 0, edges.left[row]) }
            if previous?.right[row] != edges.right[row] { cell(row, columns - 1, edges.right[row]) }
        }
        out += "\u{1b}[0m"
        if previous?.dominant != edges.dominant {
            let color = edges.dominant
            out += String(format: "\u{1b}]11;rgb:%02x/%02x/%02x\u{1b}\\", color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF)
        }
        return out
    }

    // MARK: Testing

    #if DEBUG
    // once the page is still, the full composite core animation would show is written next to the
    // container's other files, for comparing with what the terminal shows
    private var truthWrittenFor = -1.0
    private func writeTruthWhenStill() {
        guard truthWrittenFor != lastFrame, let renderer, let composite, let device, let commands = commandQueue?.makeCommandBuffer() else { return }
        truthWrittenFor = lastFrame
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        _ = renderer.updateBounds()
        renderer.addUpdate(container.bounds)
        renderer.render()
        renderer.endFrame()
        let w = width, h = height
        guard let buffer = device.makeBuffer(length: w * h * 4, options: .storageModeShared), let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: composite, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        commands.addCompletedHandler { _ in
            guard let context = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Self.colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: NSHomeDirectory() + "/tmp/terminal-truth.png") as CFURL,
                                                                    "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        commands.commit()
    }
    #endif
}

// a timestamped log of what the renderer does, for finding what makes it stutter
nonisolated(unsafe) private var traceHandle: FileHandle? = {
    let path = NSHomeDirectory() + "/tmp/trace.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func trace(_ message: String) {
    traceHandle?.write(Data(String(format: "%.4f %@\n", CACurrentMediaTime(), message).utf8))
}
