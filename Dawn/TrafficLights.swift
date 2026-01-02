import SwiftUI
import AppKit

struct TrafficLightsView: View {
    var isDocked: Bool
    var isSidebarFullyOpen: Bool

    @State private var isHovering = false

    // Only allow hover when sidebar is docked or floating and fully open
    private var canHover: Bool {
        isDocked || isSidebarFullyOpen
    }

    var body: some View {
        TrafficLightsRepresentable(isHovering: isHovering && canHover)
            .frame(width: 58, height: 16)
            .offset(x: -1)
            .onHover { isHovering = $0 }
            .allowsHitTesting(canHover)
    }
}

struct TrafficLightsRepresentable: NSViewRepresentable {
    var isHovering: Bool

    func makeNSView(context: Context) -> TrafficLightsContainerView {
        TrafficLightsContainerView()
    }

    func updateNSView(_ nsView: TrafficLightsContainerView, context: Context) {
        nsView.isHovering = isHovering
    }
}

class TrafficLightsContainerView: NSView {
    private var greyCircles: [NSView] = []
    private var isFullscreen = false
    private var observers: [NSObjectProtocol] = []

    private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private let buttonSpacing: CGFloat = 22
    private let buttonSize: CGFloat = 14

    var isHovering = false {
        didSet { updateButtonVisibility() }
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
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Delay needed - window buttons aren't immediately accessible
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

        // Update tracking areas on the buttons' container
        if let closeButton = window.standardWindowButton(.closeButton),
           let container = closeButton.superview {
            container.updateTrackingAreas()
        }
    }

    private func updateButtonVisibility() {
        guard let window = self.window else { return }

        let shouldShowButtons = isFullscreen || isHovering

        // Toggle grey circles
        greyCircles.forEach { $0.isHidden = shouldShowButtons }

        // Toggle and position real buttons
        for type in buttonTypes {
            window.standardWindowButton(type)?.isHidden = !shouldShowButtons
        }

        if shouldShowButtons {
            repositionButtons()
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
