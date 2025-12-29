import SwiftUI
import AppKit

struct TrafficLightsView: View {
    var isSidebarVisible: Bool
    var isDocked: Bool
    @State private var isHovering = false
    @State private var isStable = true

    // only when fully visible
    var canHover: Bool {
        isDocked || (isSidebarVisible && isStable)
    }

    var body: some View {
        NativeTrafficLightsController(isSidebarVisible: isSidebarVisible, isDocked: isDocked, isHovering: isHovering && canHover)
            .frame(width: 58, height: 16)
            .offset(x: -1)
            .onHover { hovering in
                isHovering = hovering
            }
            .allowsHitTesting(canHover)
            .onChange(of: isSidebarVisible) { oldValue, newValue in
                // sidebar is only stable if it's not animating
                if !oldValue && newValue {
                    isStable = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isStable = true
                    }
                }
            }
    }
}

struct NativeTrafficLightsController: NSViewRepresentable {
    var isSidebarVisible: Bool
    var isDocked: Bool
    var isHovering: Bool

    func makeNSView(context: Context) -> TrafficLightsContainerView {
        let view = TrafficLightsContainerView()
        return view
    }

    func updateNSView(_ nsView: TrafficLightsContainerView, context: Context) {
        nsView.isSidebarVisible = isSidebarVisible
        nsView.isDocked = isDocked
        nsView.isHovering = isHovering
    }
}

class TrafficLightsContainerView: NSView {
    private var greyCircles: [NSView] = []
    private var isFullscreen = false

    var isSidebarVisible = true {
        didSet { updateButtonVisibility() }
    }

    var isDocked = true {
        didSet { updateButtonVisibility() }
    }

    var isHovering = false {
        didSet { updateButtonVisibility() }
    }

    private var observers: [NSObjectProtocol] = []

    private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private let buttonSpacing: CGFloat = 22
    private let buttonSize: CGFloat = 14

    init() {
        super.init(frame: .zero)
        setupGreyCircles()
        setupObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGreyCircles() {
        for i in 0..<3 {
            let x = CGFloat(i) * buttonSpacing
            let y = (16 - buttonSize) / 2  // Center vertically in 16px container
            let circle = NSView(frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize))
            circle.wantsLayer = true
            circle.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
            circle.layer?.cornerRadius = buttonSize / 2
            addSubview(circle)
            greyCircles.append(circle)
        }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        // Reposition on window resize (buttons revert to default position)
        let resizeObs = center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.repositionButtons()
        }
        observers.append(resizeObs)

        // Fullscreen observers
        let enterObs = center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isFullscreen = true
            self?.updateButtonVisibility()
        }
        observers.append(enterObs)

        let exitObs = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isFullscreen = false
            self?.updateButtonVisibility()
        }
        observers.append(exitObs)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateButtonVisibility()
            }
        }
    }

    // Get a view's origin in window coordinates by traversing the hierarchy
    private func originInWindow(_ view: NSView) -> CGPoint {
        var origin = view.frame.origin
        var current = view.superview
        while let v = current, v != self.window?.contentView?.superview {
            origin.x += v.frame.origin.x
            origin.y += v.frame.origin.y
            current = v.superview
        }
        return origin
    }

    // Reposition buttons to match grey circles (keeping buttons in their original superview)
    private func repositionButtons() {
        guard let window = self.window else { return }

        for (index, type) in buttonTypes.enumerated() {
            guard let button = window.standardWindowButton(type),
                  let buttonSuperview = button.superview,
                  index < greyCircles.count else { continue }

            let circle = greyCircles[index]

            // Convert circle center from our view to button's superview, then calculate origin
            let circleCenter = CGPoint(x: circle.frame.midX, y: circle.frame.midY)
            let centerInSuperview = self.convert(circleCenter, to: buttonSuperview)

            // Position button so its center aligns with circle center
            let buttonOrigin = CGPoint(
                x: centerInSuperview.x - button.frame.width / 2,
                y: centerInSuperview.y - button.frame.height / 2
            )

            // Set frame to ensure proper layout update
            button.frame = NSRect(origin: buttonOrigin, size: button.frame.size)

            // Force tracking areas to update for hover detection
            button.updateTrackingAreas()
        }

        // Also update tracking areas on the buttons' container (titlebar view)
        if let closeButton = window.standardWindowButton(.closeButton),
           let container = closeButton.superview {
            container.updateTrackingAreas()
        }
    }

    private func updateButtonVisibility() {
        guard let window = self.window else { return }

        // Only show buttons when sidebar is stable (docked or fully visible, not during animation)
        let sidebarStable = isDocked || isSidebarVisible
        let shouldShowButtons = isFullscreen || (isHovering && sidebarStable)

        if shouldShowButtons {
            // Hide grey circles
            for circle in greyCircles {
                circle.isHidden = true
            }

            // Show and reposition buttons
            for type in buttonTypes {
                if let button = window.standardWindowButton(type) {
                    button.isHidden = false
                }
            }
            repositionButtons()
        } else {
            // Show grey circles
            for circle in greyCircles {
                circle.isHidden = false
            }

            // Hide buttons
            for type in buttonTypes {
                if let button = window.standardWindowButton(type) {
                    button.isHidden = true
                }
            }
        }
    }

    override func layout() {
        super.layout()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
