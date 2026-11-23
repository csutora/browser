import AppKit

// Terminals only report scrolling as coarse wheel clicks. Dawn runs on the same Mac, so it can hand a
// page the system's own scroll events instead: every phase, every momentum event and every precise
// delta exactly as the trackpad reported them, so a page in a terminal scrolls like it does in a window.
//
// The terminal decides where a gesture goes. System events are only held until the terminal reports a
// wheel event for one of Dawn's panes, which it does for any movement over that pane; the gesture's held
// events then go to that page, and the rest of the gesture, momentum included, follows directly, like it
// does in AppKit. A gesture the terminal doesn't report, because it happened anywhere else, is dropped.
// The monitor itself is a callback for scroll events only (the one way to see another app's input); it
// does nothing else, and only exists while a page is open.
final class TerminalScrollRouter {
    static let shared = TerminalScrollRouter()

    private let sessions = NSHashTable<TerminalSession>.weakObjects()
    private var monitor: Any?
    // the current gesture's events, held until a pane claims them
    private var held: [NSEvent] = []
    private weak var owner: TerminalSession?
    private var lastEvent: TimeInterval = 0

    func register(_ session: TerminalSession) {
        sessions.add(session)
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.receive(event)
        }
    }

    func unregister(_ session: TerminalSession) {
        sessions.remove(session)
        if owner === session { owner = nil }
        guard sessions.allObjects.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        held.removeAll()
    }

    // whether system scroll events are arriving, so the terminal's own wheel reports aren't needed
    var isReceivingSystemEvents: Bool {
        ProcessInfo.processInfo.systemUptime - lastEvent < 0.5
    }

    private func receive(_ event: NSEvent) {
        lastEvent = ProcessInfo.processInfo.systemUptime
        let startsGesture = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        // a mouse wheel's clicks have no phases, so each one is a gesture of its own
        let isDiscrete = event.phase.isEmpty && event.momentumPhase.isEmpty
        if startsGesture || isDiscrete {
            owner = nil
            held = [event]
        } else if let owner {
            owner.deliverNativeScroll(event)
        } else {
            held.append(event)
            if held.count > 120 { held.removeFirst(held.count - 120) }
        }
    }

    // the terminal reported a wheel event over this page's pane: the gesture in progress is its
    func claim(for session: TerminalSession) {
        guard owner !== session else { return }
        owner = session
        let pending = held
        held.removeAll()
        // held events are the gesture this report came from only if they're fresh; anything older is a
        // gesture that happened elsewhere, and this report's own events are still on their way
        guard let last = pending.last, ProcessInfo.processInfo.systemUptime - last.timestamp < 0.15 else { return }
        pending.forEach { session.deliverNativeScroll($0) }
    }
}
