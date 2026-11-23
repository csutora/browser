import AppKit

// MARK: - Click Tracking

// remembers the last click in each window, so a download's badge launches from where it was triggered
final class DownloadClickTracker {
    static let shared = DownloadClickTracker()

    private var monitor: Any?
    private var lastClicks: [Int: (point: NSPoint, time: CFTimeInterval)] = [:]

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let window = event.window {
                self?.lastClicks[window.windowNumber] = (event.locationInWindow, CACurrentMediaTime())
            }
            return event
        }
    }

    func recentClick(in window: NSWindow, within seconds: CFTimeInterval = 6) -> NSPoint? {
        guard let click = lastClicks[window.windowNumber], CACurrentMediaTime() - click.time <= seconds else { return nil }
        return click.point
    }
}

// MARK: - Flight

enum DownloadFlight {
    // Flies a badge along an arc from `start` to `end` (both in `root`'s coordinates) and calls
    // `onLand` just before it vanishes, so the receiver's bump overlaps the badge shrinking into it.
    static func launch(in root: NSView, from start: NSPoint, to end: NSPoint, onLand: @escaping () -> Void) {
        let overlay = FlightOverlayView(frame: root.bounds)
        root.addSubview(overlay)
        overlay.fly(from: start, to: end, onLand: onLand, completion: { overlay.removeFromSuperview() })
    }

    // When the sidebar is hidden, a small tile slides in from the leading edge to catch the badge,
    // then slides back out.
    static func launchToCatcher(in root: NSView, from start: NSPoint, onLand: (() -> Void)? = nil) {
        let overlay = FlightOverlayView(frame: root.bounds)
        root.addSubview(overlay)
        overlay.flyToCatcher(from: start, onLand: onLand, completion: { overlay.removeFromSuperview() })
    }

    static func arrowPath(in rect: CGRect, scale s: CGFloat = 1) -> CGPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + 4.9 * s))
        p.addLine(to: CGPoint(x: c.x, y: c.y - 2.3 * s))
        p.move(to: CGPoint(x: c.x - 3.5 * s, y: c.y + 1.1 * s))
        p.addLine(to: CGPoint(x: c.x, y: c.y - 2.4 * s))
        p.addLine(to: CGPoint(x: c.x + 3.5 * s, y: c.y + 1.1 * s))
        p.move(to: CGPoint(x: c.x - 4.9 * s, y: c.y - 5.4 * s))
        p.addLine(to: CGPoint(x: c.x + 4.9 * s, y: c.y - 5.4 * s))
        return p
    }
}

// A toss pulled home by a magnet-like force: the badge is launched sideways off the line between the
// points (up and away from the sidebar) and a pull that strengthens as it closes in bends it home, so it
// peels off the click, hangs at the top of its swing, then gets yanked into the target at its fastest.
// With u in 0...1, p(u) = start + v0 u + k (q u^2 + c u^3): the quadratic part is a constant pull, the
// cubic part makes that pull ramp up, and k = (end - start - v0) / (q + c) lands it exactly at u = 1.
private struct Trajectory {
    let start: CGPoint
    let launch: CGPoint
    let pull: CGPoint
    let distance: CGFloat
    let peakSpeed: CGFloat

    // share of the pull that's constant versus ramping; more ramp means a harder final acceleration
    private static let q: CGFloat = 0.3
    private static let c: CGFloat = 0.7

    private static func offset(_ u: CGFloat) -> CGFloat { q * u * u + c * u * u * u }
    private static func rate(_ u: CGFloat) -> CGFloat { 2 * q * u + 3 * c * u * u }

    init(from start: CGPoint, to end: CGPoint, within area: CGRect) {
        self.start = start
        let d = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let distance = max(1, hypot(d.x, d.y))
        self.distance = distance
        var normal = CGPoint(x: -d.y / distance, y: d.x / distance)
        if normal.y + normal.x * 0.6 < 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }

        // the sideways launch sets how far it swings out (the apex sits at a quarter of it); it backs
        // off until the flight fits on screen. the endpoints themselves may sit in the margin (the
        // target is a button near the window's corner), so they always count as inside.
        let ends = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let area = area.union(ends)
        var strength = min(1.0, 330 / distance + 0.47)
        var launch = CGPoint.zero
        var pull = CGPoint.zero
        for _ in 0..<12 {
            let speed = distance * strength
            launch = CGPoint(x: normal.x * speed - d.x * 0.05, y: normal.y * speed - d.y * 0.05)
            pull = CGPoint(x: (d.x - launch.x) / (Self.q + Self.c), y: (d.y - launch.y) / (Self.q + Self.c))
            let fits = (1..<24).allSatisfy { i -> Bool in
                let u = CGFloat(i) / 24
                let k = Self.offset(u)
                return area.contains(CGPoint(x: start.x + launch.x * u + pull.x * k,
                                             y: start.y + launch.y * u + pull.y * k))
            }
            if fits { break }
            strength *= 0.78
        }
        self.launch = launch
        self.pull = pull
        let r = Self.rate(1)
        let arrival = CGPoint(x: launch.x + pull.x * r, y: launch.y + pull.y * r)
        peakSpeed = max(1, hypot(launch.x, launch.y), hypot(arrival.x, arrival.y))
    }

    func position(at u: CGFloat) -> CGPoint {
        let k = Self.offset(u)
        return CGPoint(x: start.x + launch.x * u + pull.x * k, y: start.y + launch.y * u + pull.y * k)
    }

    func velocity(at u: CGFloat) -> CGPoint {
        let r = Self.rate(u)
        return CGPoint(x: launch.x + pull.x * r, y: launch.y + pull.y * r)
    }
}

private final class FlightOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func makeBadge(size: CGFloat) -> CALayer {
        let badge = CALayer()
        badge.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        badge.cornerRadius = size / 2
        badge.backgroundColor = NSColor(white: 0.2, alpha: 0.96).cgColor
        badge.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        badge.borderWidth = 0.75
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.4
        badge.shadowRadius = 9
        badge.shadowOffset = CGSize(width: 0, height: -3)
        badge.contentsScale = scale

        let glyph = CAShapeLayer()
        glyph.frame = badge.bounds
        glyph.path = DownloadFlight.arrowPath(in: badge.bounds, scale: size / 26)
        glyph.fillColor = nil
        glyph.strokeColor = NSColor(white: 1, alpha: 0.95).cgColor
        glyph.lineWidth = 1.7 * size / 26
        glyph.lineCap = .round
        glyph.lineJoin = .round
        glyph.contentsScale = scale
        badge.addSublayer(glyph)
        return badge
    }

    private func ripple(at point: CGPoint) {
        let ring = CAShapeLayer()
        let size: CGFloat = 26
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor(white: 1, alpha: 0.7).cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        ring.contentsScale = scale
        layer?.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.7
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.6, 0]
        fade.keyTimes = [0, 0.18, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { ring.removeFromSuperlayer() }
    }

    func fly(from start: NSPoint, to end: NSPoint, onLand: @escaping () -> Void, completion: @escaping () -> Void) {
        guard let root = layer else { completion(); return }
        ripple(at: start)

        let badge = makeBadge(size: 26)
        badge.position = end
        badge.opacity = 0
        root.addSublayer(badge)

        let flight = Trajectory(from: start, to: end, within: bounds.insetBy(dx: 20, dy: 20))
        let duration = min(0.82, 0.52 + Double(flight.distance) / 2600)

        // every property is sampled from the same simulated time, so position, size and lean stay in
        // step; linear keyframe interpolation keeps the physics' own acceleration intact
        let steps = 72
        var positions: [NSValue] = []
        var scales: [CGFloat] = []
        var tilts: [CGFloat] = []
        var opacities: [CGFloat] = []
        var times: [NSNumber] = []
        for i in 0...steps {
            let u = CGFloat(i) / CGFloat(steps)
            positions.append(NSValue(point: flight.position(at: u)))
            times.append(NSNumber(value: Double(u)))

            // pops up on launch, holds through the swing, and shrinks ever faster into the target
            let scale: CGFloat
            if u < 0.18 {
                let t = u / 0.18
                scale = 0.5 + 0.78 * (1 - (1 - t) * (1 - t))
            } else if u < 0.58 {
                scale = 1.28 - 0.13 * ((u - 0.18) / 0.4)
            } else {
                let t = (u - 0.58) / 0.42
                scale = 1.15 - 0.73 * t * t
            }
            scales.append(scale)

            // leans into its direction of travel, more the faster it moves sideways
            let v = flight.velocity(at: u)
            tilts.append(max(-0.32, min(0.32, -0.3 * v.x / flight.peakSpeed)))

            opacities.append(u < 0.08 ? u / 0.08 : (u > 0.93 ? max(0, (1 - u) / 0.07) : 1))
        }

        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let anim = CAKeyframeAnimation(keyPath: keyPath)
            anim.values = values
            anim.keyTimes = times
            anim.calculationMode = .linear
            return anim
        }

        let group = CAAnimationGroup()
        group.animations = [
            keyframes("position", positions),
            keyframes("transform.scale", scales),
            keyframes("transform.rotation.z", tilts),
            keyframes("opacity", opacities),
        ]
        group.duration = duration
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        badge.add(group, forKey: "flight")

        // it arrives at its fastest, so the receiver reacts right at impact
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.94) { onLand() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            badge.removeFromSuperlayer()
            completion()
        }
    }

    func flyToCatcher(from start: NSPoint, onLand: (() -> Void)?, completion: @escaping () -> Void) {
        guard let root = layer else { completion(); return }
        let size: CGFloat = 36
        let inset: CGFloat = 14
        let tile = CALayer()
        tile.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        tile.cornerRadius = 11
        tile.cornerCurve = .continuous
        tile.backgroundColor = NSColor(white: 0.16, alpha: 0.97).cgColor
        tile.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        tile.borderWidth = 0.75
        tile.shadowColor = NSColor.black.cgColor
        tile.shadowOpacity = 0.35
        tile.shadowRadius = 10
        tile.shadowOffset = CGSize(width: 0, height: -3)
        tile.contentsScale = scale

        let glyph = CAShapeLayer()
        glyph.frame = tile.bounds
        glyph.path = DownloadFlight.arrowPath(in: tile.bounds)
        glyph.fillColor = nil
        glyph.strokeColor = NSColor(white: 1, alpha: 0.85).cgColor
        glyph.lineWidth = 1.45
        glyph.lineCap = .round
        glyph.lineJoin = .round
        glyph.contentsScale = scale
        tile.addSublayer(glyph)

        let home = CGPoint(x: inset + size / 2, y: inset + size / 2)
        let away = CGPoint(x: -size, y: home.y)
        tile.position = home
        root.addSublayer(tile)

        let enter = CASpringAnimation(perceptualDuration: 0.42, bounce: 0.28)
        enter.keyPath = "position.x"
        enter.fromValue = away.x
        enter.toValue = home.x
        enter.duration = enter.settlingDuration
        tile.add(enter, forKey: "enter")

        fly(from: start, to: home, onLand: { [weak tile] in
            onLand?()
            guard let tile else { return }
            let bump = CAKeyframeAnimation(keyPath: "transform.scale")
            bump.values = [1.0, 1.16, 0.97, 1.0]
            bump.keyTimes = [0, 0.25, 0.65, 1]
            bump.duration = 0.42
            tile.add(bump, forKey: "bump")
        }, completion: { [weak tile] in
            guard let tile else { completion(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                let exit = CABasicAnimation(keyPath: "position.x")
                exit.fromValue = home.x
                exit.toValue = away.x
                exit.duration = 0.3
                exit.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)
                exit.isRemovedOnCompletion = false
                exit.fillMode = .forwards
                tile.add(exit, forKey: "exit")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                    tile.removeFromSuperlayer()
                    completion()
                }
            }
        })
    }
}
