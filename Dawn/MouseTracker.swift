import AppKit
import Combine

class MouseTracker: ObservableObject {
    @Published var shouldShowSidebar: Bool = false

    var sidebarWidth: CGFloat = 260.0
    var isDocked: Bool = true
    weak var window: NSWindow?

    private var isWindowDragging: Bool = false
    private var isTransitioning: Bool = false

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    // Throttle mouse checks to 15fps (~67ms) - sidebar show/hide doesn't need high precision
    private var lastCheckTime: CFTimeInterval = 0
    private let checkInterval: CFTimeInterval = 1.0 / 15.0  // 15fps

    init() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.throttledCheckMouse()
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.throttledCheckMouse()
        }

        setupWindowObservers()
    }

    private func throttledCheckMouse() {
        let now = CACurrentMediaTime()
        guard now - lastCheckTime >= checkInterval else { return }
        lastCheckTime = now
        checkMouse()
    }

    private func setupWindowObservers() {
        let center = NotificationCenter.default
        let notifications: [(NSNotification.Name, Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true),
            (NSWindow.didEnterFullScreenNotification, false),
            (NSWindow.willExitFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false)
        ]

        for (name, startState) in notifications {
            let obs = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.isTransitioning = startState
                if !startState { self?.checkMouse() }
            }
            observers.append(obs)
        }
    }

    func updateSettings(sidebarWidth: Double, isDocked: Bool) {
        let wasDockedNowUndocking = self.isDocked && !isDocked
        self.sidebarWidth = CGFloat(sidebarWidth)
        self.isDocked = isDocked

        if wasDockedNowUndocking {
            shouldShowSidebar = true
        }
        checkMouse()
    }

    private func checkMouse() {
        guard !isDocked else {
            if shouldShowSidebar { DispatchQueue.main.async { self.shouldShowSidebar = false } }
            return
        }

        if NSEvent.pressedMouseButtons > 0 || isTransitioning { return }

        guard let window = self.window ?? NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first else { return }

        let mouseLoc = NSEvent.mouseLocation
        let frame = window.frame

        let isVerticallyInside = (mouseLoc.y >= frame.minY) && (mouseLoc.y <= frame.maxY)
        let x = mouseLoc.x - frame.minX

        let shouldBeOpen: Bool

        if !isVerticallyInside {
            shouldBeOpen = false
        } else {
            if shouldShowSidebar {
                shouldBeOpen = (x > -200) && (x < (sidebarWidth + 30))
            } else {
                shouldBeOpen = (x > -200) && (x < 10)
            }
        }

        if shouldShowSidebar != shouldBeOpen {
            DispatchQueue.main.async {
                self.shouldShowSidebar = shouldBeOpen
            }
        }
    }

    deinit {
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
