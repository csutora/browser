import AppKit
import Combine

// The sidebar's downloads button. Every glyph is a vector shape layer so state changes morph
// rather than swap: the arrow drops into a ring that draws itself while a pie fills with the
// aggregate progress; a finish fills the pie, shrinks it away and strokes a checkmark; afterwards the
// ring undraws and the arrow drops back in with a notification dot. All animations start from the
// layers' presentation values, so an event arriving mid-transition redirects the motion instead of
// snapping.
final class DownloadIndicatorView: NSView {
    private enum Glyph: Equatable {
        case arrow
        case progress
        case check
        case failure
    }

    // the resting arrow is drawn at the visual weight of the sidebar's 12pt symbols; the ring around
    // it while downloading is a little larger so the pie stays legible
    static let arrowScale: CGFloat = 0.86

    var onClick: (() -> Void)?

    private let manager = DownloadManager.shared
    private var cancellables = Set<AnyCancellable>()

    private let glyphLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private let pieLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private let checkLayer = CAShapeLayer()
    private let crossLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private let alertLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()

    private var glyph: Glyph = .arrow
    private var transient: Glyph?
    private var transientEnd: DispatchWorkItem?
    private var pendingFlights = 0
    private var isShown = false
    private var isIndeterminate = false
    private var shownFraction: Double = 0
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    private static let ringRadius: CGFloat = 6.1
    private static let ringWidth: CGFloat = 1.3
    private static let strokeWidth: CGFloat = 1.35

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLayers()
        isHidden = true
        bind()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layers

    private func setupLayers() {
        guard let root = layer else { return }
        glyphLayer.masksToBounds = false
        root.addSublayer(glyphLayer)

        for shape in [pulseLayer, ringLayer, pieLayer, arrowLayer, checkLayer, crossLayer, dotLayer, alertLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.contentsScale = window?.backingScaleFactor ?? 2
            glyphLayer.addSublayer(shape)
        }

        ringLayer.lineWidth = Self.ringWidth
        ringLayer.strokeEnd = 0
        pieLayer.strokeEnd = 0
        pieLayer.lineCap = .butt
        pieLayer.opacity = 0
        arrowLayer.lineWidth = Self.strokeWidth
        checkLayer.lineWidth = Self.strokeWidth + 0.1
        checkLayer.strokeEnd = 0
        checkLayer.opacity = 0
        crossLayer.lineWidth = Self.strokeWidth + 0.1
        crossLayer.strokeEnd = 0
        crossLayer.opacity = 0
        dotLayer.lineWidth = 0
        dotLayer.setValue(0.0, forKeyPath: "transform.scale")
        alertLayer.lineWidth = 0
        alertLayer.fillRule = .evenOdd
        alertLayer.setValue(0.0, forKeyPath: "transform.scale")
        pulseLayer.lineWidth = 1.2
        pulseLayer.opacity = 0
        applyColors(animated: false)
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for shape in [pulseLayer, ringLayer, pieLayer, arrowLayer, checkLayer, crossLayer, dotLayer, alertLayer] {
            shape.contentsScale = scale
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors(animated: false)
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        glyphLayer.bounds = b
        glyphLayer.position = c

        for shape in [pulseLayer, ringLayer, pieLayer, arrowLayer, checkLayer, crossLayer, dotLayer, alertLayer] {
            shape.bounds = b
            shape.position = c
        }

        // circles start at twelve o'clock and run clockwise, so draw-on and pie growth read naturally
        func circle(_ r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            p.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            return p
        }
        ringLayer.path = circle(Self.ringRadius)
        pulseLayer.path = circle(Self.ringRadius)

        // a stroke as wide as the circle's diameter paints a pie wedge whose sweep is strokeEnd
        let pieRadius = Self.ringRadius - Self.ringWidth / 2 - 1.55
        pieLayer.path = circle(pieRadius / 2)
        pieLayer.lineWidth = pieRadius

        arrowLayer.path = DownloadFlight.arrowPath(in: b, scale: Self.arrowScale)

        let check = CGMutablePath()
        check.move(to: CGPoint(x: c.x - 2.5, y: c.y + 0.05))
        check.addLine(to: CGPoint(x: c.x - 0.75, y: c.y - 1.7))
        check.addLine(to: CGPoint(x: c.x + 2.55, y: c.y + 1.8))
        checkLayer.path = check

        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: c.x - 2.0, y: c.y + 2.0))
        cross.addLine(to: CGPoint(x: c.x + 2.0, y: c.y - 2.0))
        cross.move(to: CGPoint(x: c.x + 2.0, y: c.y + 2.0))
        cross.addLine(to: CGPoint(x: c.x - 2.0, y: c.y - 2.0))
        crossLayer.path = cross

        // tucked into the empty top-right corner of the arrow, clear of the shaft
        let dotSize: CGFloat = 4.6
        dotLayer.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dotLayer.position = CGPoint(x: c.x + 4.6, y: c.y + 4.3)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: dotSize, height: dotSize), transform: nil)

        // same corner, slightly larger so the knocked-out exclamation stays legible; its bottom edge
        // clears the arrowhead's right wing
        let aw: CGFloat = 7.4
        let ah: CGFloat = 6.5
        alertLayer.bounds = CGRect(x: -aw / 2, y: -ah / 2, width: aw, height: ah)
        alertLayer.position = CGPoint(x: c.x + 5.3, y: c.y + 5.0)
        alertLayer.path = Self.warningPath(width: aw, height: ah)
        CATransaction.commit()
    }

    // a rounded triangle with the exclamation mark cut out (even-odd fill), centered on the origin
    private static func warningPath(width w: CGFloat, height h: CGFloat) -> CGPath {
        let top = CGPoint(x: 0, y: h / 2)
        let left = CGPoint(x: -w / 2, y: -h / 2)
        let right = CGPoint(x: w / 2, y: -h / 2)
        let r: CGFloat = 1.15
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -h / 2))
        p.addArc(tangent1End: right, tangent2End: top, radius: r)
        p.addArc(tangent1End: top, tangent2End: left, radius: r)
        p.addArc(tangent1End: left, tangent2End: right, radius: r)
        p.closeSubpath()
        let barWidth: CGFloat = 1.05
        p.addRoundedRect(
            in: CGRect(x: -barWidth / 2, y: -h / 2 + 2.55, width: barWidth, height: 2.25),
            cornerWidth: barWidth / 2, cornerHeight: barWidth / 2
        )
        p.addEllipse(in: CGRect(x: -0.57, y: -h / 2 + 1.0, width: 1.14, height: 1.14))
        return p
    }

    private func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }

    private func applyColors(animated: Bool) {
        let emphasized = isHovered || transient != nil
        let tint = resolved(emphasized ? .labelColor : .secondaryLabelColor)
        let duration: CFTimeInterval = animated ? 0.16 : 0
        for shape in [ringLayer, pieLayer, arrowLayer, checkLayer, crossLayer, pulseLayer] {
            set(shape, "strokeColor", to: tint, duration: duration)
        }
        set(dotLayer, "fillColor", to: resolved(.controlAccentColor), duration: duration)
        set(alertLayer, "fillColor", to: resolved(.systemRed), duration: duration)
    }

    // MARK: - Binding

    private func bind() {
        manager.$aggregate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        manager.$hasSessionDownloads
            .receive(on: DispatchQueue.main)
            .sink { [weak self] has in
                if has { self?.showIfAllowed() } else { self?.hideButton() }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(manager.$hasUnseenCompletion, manager.$hasUnseenFailure)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyColors(animated: true)
                self?.updateDot()
            }
            .store(in: &cancellables)

        manager.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                switch event {
                case .finished: self?.showTransient(.check)
                case .failed: self?.showTransient(.failure)
                case .started: break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Flights

    // a flight headed here holds the appearance and glyph changes until it lands, so the button
    // reacts to the badge arriving rather than ahead of it
    func expectFlight() {
        pendingFlights += 1
    }

    func flightLanded() {
        pendingFlights = max(0, pendingFlights - 1)
        if !isShown {
            showIfAllowed()
        } else {
            bump()
            pulse()
            render()
        }
    }

    // where an incoming badge should land, in window coordinates
    var landingPointInWindow: NSPoint {
        convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
    }

    private func showIfAllowed() {
        guard manager.hasSessionDownloads, !isShown, pendingFlights == 0 else { return }
        isShown = true
        isHidden = false
        layoutLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.opacity = 0
        glyphLayer.setValue(0.25, forKeyPath: "transform.scale")
        CATransaction.commit()
        set(glyphLayer, "opacity", to: 1.0, duration: 0.16)
        spring(glyphLayer, "transform.scale", to: 1.0, duration: 0.5, bounce: 0.42)
        pulse()
        resetToArrow()
        // appear directly in the current state: a download is usually running by now, and showing
        // the arrow only to morph it away a frame later reads as clutter
        let target = desiredGlyph()
        glyph = target
        if target != .arrow {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arrowLayer.opacity = 0
            CATransaction.commit()
            transition(from: nil, to: target)
            applyColors(animated: false)
        }
        render()
    }

    // the reverse of the pop-in; afterwards the next download appears from scratch
    private func hideButton() {
        guard isShown, pendingFlights == 0 else { return }
        isShown = false
        transient = nil
        transientEnd?.cancel()
        transientEnd = nil
        set(glyphLayer, "transform.scale", to: 0.3, duration: 0.22, timing: .easeIn)
        set(glyphLayer, "opacity", to: 0.0, duration: 0.18, timing: .easeIn, delay: 0.04)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, !self.isShown else { return }
            self.isHidden = true
            self.stopSpinning()
            self.glyph = .arrow
        }
    }

    private func resetToArrow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrowLayer.opacity = 1
        arrowLayer.setValue(0.0, forKeyPath: "transform.translation.y")
        ringLayer.strokeStart = 0
        ringLayer.strokeEnd = 0
        pieLayer.strokeEnd = 0
        pieLayer.opacity = 0
        CATransaction.commit()
    }

    // MARK: - Rendering

    private var canRender: Bool { isShown && pendingFlights == 0 }

    private func showTransient(_ g: Glyph) {
        transient = g
        transientEnd?.cancel()
        transientEnd = nil
        guard canRender else { return }
        render()
        scheduleTransientEnd()
    }

    private func scheduleTransientEnd() {
        transientEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transient = nil
            self.applyColors(animated: true)
            self.render()
        }
        transientEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45, execute: work)
    }

    private func desiredGlyph() -> Glyph {
        if let transient { return transient }
        return manager.aggregate.activeCount > 0 ? .progress : .arrow
    }

    private func render() {
        guard canRender else { return }
        if transient != nil, transientEnd == nil { scheduleTransientEnd() }
        let target = desiredGlyph()
        if target != glyph {
            let from = glyph
            glyph = target
            transition(from: from, to: target)
            applyColors(animated: true)
        } else if target == .progress {
            updateProgress(animatedFrom: nil)
        }
        updateDot()
        updateAccessibility()
    }

    // `from` is nil when nothing is on screen yet (the button just appeared)
    private func transition(from: Glyph?, to: Glyph) {
        switch to {
        case .arrow:
            hideCenterMarks()
            hidePie()
            // the ring is mostly gone before the arrow arrives, so the two hand off instead of overlapping
            set(ringLayer, "strokeEnd", to: 0.0, duration: 0.24, timing: .easeIn)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arrowLayer.opacity = 0
            arrowLayer.setValue(4.5, forKeyPath: "transform.translation.y")
            CATransaction.commit()
            set(arrowLayer, "opacity", to: 1.0, duration: 0.18, delay: 0.19)
            spring(arrowLayer, "transform.translation.y", to: 0.0, duration: 0.42, bounce: 0.22, delay: 0.19)

        case .progress:
            hideCenterMarks()
            if from == .arrow {
                set(arrowLayer, "opacity", to: 0.0, duration: 0.16, timing: .easeIn)
                set(arrowLayer, "transform.translation.y", to: -3.5, duration: 0.18, timing: .easeIn)
            }
            ringLayer.strokeStart = 0
            set(ringLayer, "strokeEnd", to: 1.0, duration: 0.42, timing: .easeOut, delay: from == .arrow ? 0.06 : 0)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pieLayer.opacity = 1
            if from != .progress {
                pieLayer.strokeEnd = 0
                pieLayer.setValue(1.0, forKeyPath: "transform.scale")
            }
            CATransaction.commit()
            updateProgress(animatedFrom: 0)

        case .check, .failure:
            let mark = to == .check ? checkLayer : crossLayer
            let other = to == .check ? crossLayer : checkLayer
            set(other, "opacity", to: 0.0, duration: 0.12)
            if from == .arrow {
                set(arrowLayer, "opacity", to: 0.0, duration: 0.14, timing: .easeIn)
                set(arrowLayer, "transform.translation.y", to: -3.5, duration: 0.16, timing: .easeIn)
            }
            ringLayer.strokeStart = 0
            set(ringLayer, "strokeEnd", to: 1.0, duration: 0.3, timing: .easeOut)
            stopSpinning()
            var markDelay: CFTimeInterval = 0.12
            if from == .progress && to == .check {
                // complete the pie first so the finish reads as the progress filling up
                set(pieLayer, "strokeEnd", to: 1.0, duration: 0.18, timing: .easeOut)
                set(pieLayer, "transform.scale", to: 0.0, duration: 0.22, timing: .easeIn, delay: 0.2)
                set(pieLayer, "opacity", to: 0.0, duration: 0.12, delay: 0.3)
                markDelay = 0.3
            } else {
                hidePie()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mark.strokeEnd = 0
            mark.opacity = 1
            mark.setValue(0.7, forKeyPath: "transform.scale")
            CATransaction.commit()
            set(mark, "strokeEnd", to: 1.0, duration: 0.3, timing: .easeOut, delay: markDelay)
            spring(mark, "transform.scale", to: 1.0, duration: 0.45, bounce: 0.45, delay: markDelay)
            bump(amplitude: 1.12, delay: markDelay + 0.05)
        }
    }

    private func hideCenterMarks() {
        for mark in [checkLayer, crossLayer] where (mark.presentation()?.opacity ?? mark.opacity) > 0 {
            set(mark, "opacity", to: 0.0, duration: 0.14, timing: .easeIn)
            set(mark, "transform.scale", to: 0.6, duration: 0.16, timing: .easeIn)
        }
    }

    private func hidePie() {
        stopSpinning()
        set(pieLayer, "strokeEnd", to: 0.0, duration: 0.22, timing: .easeIn)
        set(pieLayer, "opacity", to: 0.0, duration: 0.18, delay: 0.06)
    }

    private func updateProgress(animatedFrom start: Double?) {
        let fraction = manager.aggregate.fraction
        let delay: CFTimeInterval = start != nil ? 0.12 : 0
        if let fraction {
            if isIndeterminate { stopSpinning() }
            // a hair of wedge from the start so a fresh download reads as progress, not as empty
            let target = max(0.035, fraction)
            set(pieLayer, "strokeEnd", to: target, duration: start != nil ? 0.5 : 0.3, timing: .easeOut, delay: delay)
            shownFraction = target
        } else {
            set(pieLayer, "strokeEnd", to: 0.28, duration: 0.4, timing: .easeOut, delay: delay)
            startSpinning()
        }
    }

    private func startSpinning() {
        guard !isIndeterminate else { return }
        isIndeterminate = true
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.byValue = -2 * CGFloat.pi
        spin.duration = 1.1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        pieLayer.add(spin, forKey: "spin")
    }

    private func stopSpinning() {
        guard isIndeterminate else { return }
        isIndeterminate = false
        let angle = (pieLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        pieLayer.removeAnimation(forKey: "spin")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pieLayer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        // unwind to twelve o'clock along the shorter way
        var target: CGFloat = 0
        if angle < -.pi { target = -2 * .pi }
        set(pieLayer, "transform.rotation.z", to: target, duration: 0.3, timing: .easeOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, !self.isIndeterminate else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.pieLayer.setValue(0.0, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
        }
    }

    // a finished download shows the accent dot; a failed one shows the warning triangle instead, which
    // reads by shape as well as color. the warning wins when both are pending.
    private func updateDot() {
        let resting = isShown && glyph == .arrow && transient == nil
        let showAlert = resting && manager.hasUnseenFailure
        let showDot = resting && manager.hasUnseenCompletion && !showAlert
        for (badge, visible) in [(dotLayer, showDot), (alertLayer, showAlert)] {
            let current = (badge.value(forKeyPath: "transform.scale") as? CGFloat) ?? 0
            if visible && current < 0.5 {
                spring(badge, "transform.scale", to: 1.0, duration: 0.42, bounce: 0.5, delay: 0.32)
            } else if !visible && current > 0.5 {
                set(badge, "transform.scale", to: 0.0, duration: 0.16, timing: .easeIn)
            }
        }
    }

    // MARK: - Feedback

    private func bump(amplitude: CGFloat = 1.22, delay: CFTimeInterval = 0) {
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, amplitude, 0.97, 1.01, 1.0]
        anim.keyTimes = [0, 0.22, 0.55, 0.8, 1]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        anim.duration = 0.46
        anim.isAdditive = false
        if delay > 0 {
            anim.beginTime = glyphLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
        }
        glyphLayer.add(anim, forKey: "bump")
    }

    private func pulse() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.opacity = 0
        pulseLayer.setValue(1.0, forKeyPath: "transform.scale")
        CATransaction.commit()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.9
        scale.toValue = 2.1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        pulseLayer.add(group, forKey: "pulse")
    }

    // MARK: - Animation helpers

    private func set(
        _ layer: CALayer, _ keyPath: String, to value: Any, duration: CFTimeInterval,
        timing: CAMediaTimingFunctionName = .easeOut, delay: CFTimeInterval = 0
    ) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard duration > 0 else {
            layer.removeAnimation(forKey: keyPath)
            return
        }
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = value
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: timing)
        if delay > 0 {
            anim.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            anim.fillMode = .backwards
        }
        layer.add(anim, forKey: keyPath)
    }

    private func spring(
        _ layer: CALayer, _ keyPath: String, to value: Any, duration: CFTimeInterval,
        bounce: CGFloat, delay: CFTimeInterval = 0
    ) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        let anim = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        anim.keyPath = keyPath
        anim.fromValue = from
        anim.toValue = value
        anim.duration = anim.settlingDuration
        if delay > 0 {
            anim.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            anim.fillMode = .backwards
        }
        layer.add(anim, forKey: keyPath)
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColors(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        set(glyphLayer, "transform.scale", to: 0.86, duration: 0.1, timing: .easeOut)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        spring(glyphLayer, "transform.scale", to: 1.0, duration: 0.35, bounce: 0.45)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { isShown }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Downloads" }

    private func updateAccessibility() {
        let value: String
        switch glyph {
        case .progress:
            if let f = manager.aggregate.fraction {
                value = "\(Int((f * 100).rounded())) percent"
            } else {
                value = "In progress"
            }
        case .check: value = "Download finished"
        case .failure: value = "Download failed"
        case .arrow: value = manager.hasUnseenCompletion ? "New downloads" : ""
        }
        setAccessibilityValue(value)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
