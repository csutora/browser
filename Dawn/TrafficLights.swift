import AppKit

class TrafficLightsContainerView: NSView {
    private var greyCircles: [NSView] = []
    private var isFullscreen = false
    private var observers: [NSObjectProtocol] = []

    private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private let buttonSpacing: CGFloat = 22
    private let buttonSize: CGFloat = 14

    var canHover: Bool = true {
        didSet { updateButtonVisibility() }
    }

    private var isHoveringMouse = false

    var isHovering: Bool {
        isHoveringMouse && canHover
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupGreyCircles()
        setupFullscreenObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGreyCircles() {
        for i in 0..<3 {
            let circle = NSView(frame: NSRect(
                x: CGFloat(i) * buttonSpacing,
                y: (16 - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            ))
            circle.wantsLayer = true
            circle.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
            circle.layer?.cornerRadius = buttonSize / 2
            addSubview(circle)
            greyCircles.append(circle)
        }
    }

    private func setupFullscreenObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isFullscreen = true
            self?.updateButtonVisibility()
        })

        observers.append(center.addObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isFullscreen = false
            self?.updateButtonVisibility()
        })

        // On exit macOS resets the buttons to their default position; reposition them into the
        // sidebar only after the exit transition has fully finished.
        observers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isFullscreen = false
            self?.updateButtonVisibility()
        })
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateButtonVisibility()
        }
    }

    private func repositionButtons() {
        guard let window = self.window else { return }

        for (index, type) in buttonTypes.enumerated() {
            guard let button = window.standardWindowButton(type),
                  let buttonSuperview = button.superview,
                  index < greyCircles.count else { continue }

            let circle = greyCircles[index]
            let circleCenter = CGPoint(x: circle.frame.midX, y: circle.frame.midY)
            let centerInSuperview = self.convert(circleCenter, to: buttonSuperview)

            button.frame = NSRect(
                origin: CGPoint(
                    x: centerInSuperview.x - button.frame.width / 2,
                    y: centerInSuperview.y - button.frame.height / 2
                ),
                size: button.frame.size
            )
            button.updateTrackingAreas()
        }

        if let closeButton = window.standardWindowButton(.closeButton),
           let container = closeButton.superview {
            container.updateTrackingAreas()
        }
    }

    private func updateButtonVisibility() {
        guard let window = self.window else { return }

        let shouldShowButtons = isFullscreen || isHovering

        greyCircles.forEach { $0.isHidden = shouldShowButtons }

        for type in buttonTypes {
            window.standardWindowButton(type)?.isHidden = !shouldShowButtons
        }

        if shouldShowButtons {
            repositionButtons()
        }
    }

    // MARK: - Hover Tracking

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHoveringMouse = true
        updateButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringMouse = false
        updateButtonVisibility()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
