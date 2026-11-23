import AppKit
import Combine
import WebKit

// MARK: - Server

// Accepts `dawn <url>` connections from terminals and gives each its own page.
final class TerminalServer {
    static let shared = TerminalServer()

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sessions: [ObjectIdentifier: TerminalSession] = [:]
    private var pending: [ObjectIdentifier: TerminalConnection] = [:]
    private var makeState: (() -> BrowserState)?

    func start(makeState: @escaping () -> BrowserState) {
        guard listener < 0 else { return }
        self.makeState = makeState
        let path = TerminalLink.socketPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        unlink(path)
        guard var address = TerminalLink.socketAddress() else { return }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(socket, 16) == 0 else {
            close(socket)
            return
        }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        listener = socket

        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    private func acceptPending() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let connection = TerminalConnection(client)
            let key = ObjectIdentifier(connection)
            // held from here until its hello turns it into a session, or it hangs up first
            pending[key] = connection
            connection.onClose = { [weak self] in self?.pending[key] = nil }
            connection.onMessage = { [weak self, weak connection] type, payload in
                guard let self, let connection, type == .hello, let makeState = self.makeState,
                      let hello = try? JSONDecoder().decode(TerminalLink.Hello.self, from: payload) else { return }
                self.pending[key] = nil
                let session = TerminalSession(connection: connection, hello: hello, state: makeState())
                let sessionKey = ObjectIdentifier(session)
                self.sessions[sessionKey] = session
                session.onEnd = { [weak self] in self?.sessions[sessionKey] = nil }
            }
            connection.start()
        }
    }
}

// MARK: - Connection

final class TerminalConnection {
    private let fd: Int32
    private var readSource: DispatchSourceRead?
    // only exists while output is waiting on a full socket
    private var writeSource: DispatchSourceWrite?
    private var incoming = Data()
    private var outgoing = Data()
    private(set) var isClosed = false

    // the session replaces this once the hello arrives
    var onMessage: ((TerminalLink.Message, Data) -> Void)?
    var onClose: (() -> Void)?

    init(_ fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
    }

    deinit {
        if !isClosed { Darwin.close(fd) }
    }

    func send(_ type: TerminalLink.Message, _ payload: Data) {
        guard !isClosed else { return }
        outgoing.append(TerminalLink.frame(type, payload))
        flush()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        writeSource?.cancel()
        writeSource = nil
        Darwin.close(fd)
        onClose?()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                incoming.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EINTR) {
                deliver()
                close()
                return
            }
            break
        }
        deliver()
    }

    private func deliver() {
        for (type, payload) in TerminalLink.takeMessages(&incoming) {
            guard !isClosed else { return }
            onMessage?(type, payload)
        }
    }

    private func flush() {
        while !outgoing.isEmpty {
            let written = outgoing.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                outgoing.removeSubrange(0..<written)
            } else if written < 0, errno == EAGAIN {
                if writeSource == nil {
                    let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    writer.setEventHandler { [weak self] in self?.flush() }
                    writer.resume()
                    writeSource = writer
                }
                return
            } else if written < 0, errno == EINTR {
                continue
            } else {
                close()
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }
}

// MARK: - Host window

// The invisible window a terminal's page renders in. It reports itself key while its terminal pane has
// focus, so the page shows its caret and focus rings and pages that check focus behave, without ever
// becoming the app's real key window and taking the keyboard from Dawn's own windows.
final class TerminalHostWindow: NSWindow {
    var isTerminalFocused = false {
        didSet {
            guard isTerminalFocused != oldValue else { return }
            NotificationCenter.default.post(
                name: isTerminalFocused ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: self
            )
        }
    }

    // the screen the terminal is on, which webkit takes its display (and so its frame rate) from
    var terminalScreen: NSScreen? {
        didSet {
            guard terminalScreen != oldValue else { return }
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: self)
        }
    }

    override var screen: NSScreen? { terminalScreen ?? super.screen }
    override var isKeyWindow: Bool { isTerminalFocused }
    // webkit suspends pages whose window isn't visible, which a window that's never on screen isn't, and
    // which every window stops being while dawn is hidden. the page is visible: it's in the terminal.
    override var isVisible: Bool { true }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Session

// One page shown in one terminal. The page renders in an invisible window; frames go to the terminal as
// kitty graphics through shared memory, and the terminal's mouse, keyboard and size reports come back
// as the events AppKit would have delivered.
final class TerminalSession: NSObject {
    private let connection: TerminalConnection
    private let state: BrowserState
    private let window: TerminalHostWindow
    private let renderer: TerminalRenderer
    private var parser = TerminalInputParser()
    private var titleSubscription: AnyCancellable?
    // dawn runs in the background while a page shows in a terminal, which macos would otherwise nap,
    // throttling the page's rendering (and with it every animation and hover effect) to a few frames a
    // second. the page is in front of someone, so it's treated as such for as long as it's shown.
    private var activity: NSObjectProtocol?
    var onEnd: (() -> Void)?

    // the terminal's text area in pixels and cells, and the display scale those pixels are at
    private var pixelWidth: Int
    private var pixelHeight: Int
    private var columns: Int
    private var rows: Int
    private var scale: CGFloat

    // where the terminal last reported the pointer, in the page window's points
    private var pointer = NSPoint.zero

    private var pressedButton: Int?
    private var clickCount = 0
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = NSPoint.zero

    private var webView: WKWebView { state.webView }

    init(connection: TerminalConnection, hello: TerminalLink.Hello, state: BrowserState) {
        self.connection = connection
        self.state = state
        scale = NSScreen.main?.backingScaleFactor ?? 2
        pixelWidth = max(hello.width, 1)
        pixelHeight = max(hello.height, 1)
        columns = max(hello.columns, 1)
        rows = max(hello.rows, 1)

        window = TerminalHostWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        // the terminal takes images as srgb, so that's what webkit paints the page's tiles in
        window.colorSpace = .sRGB
        renderer = TerminalRenderer(webView: state.webView)
        super.init()

        let view = state.webView
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        Self.disableOcclusionDetection(view)
        state.navigationDelegate.showsContextMenus = false
        state.onNewTabRequested = { [weak self] url, _ in self?.state.loadURL(url.absoluteString) }
        state.onNewWindowRequested = { [weak self] url in self?.state.loadURL(url.absoluteString) }
        applySize()
        window.orderFront(nil)
        window.makeFirstResponder(view)
        // the pane a command was just typed into has focus; the terminal reports any change from here
        window.isTerminalFocused = true

        renderer.output = { [weak connection] data in connection?.send(.output, data) }
        if let screen = NSScreen.main { useScreen(screen) }
        connection.onMessage = { [weak self] type, payload in self?.receive(type, payload) }
        connection.onClose = { [weak self] in self?.end() }
        TerminalScrollRouter.shared.register(self)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "showing a page in a terminal"
        )

        // the page's title names the terminal tab, like it names a window
        titleSubscription = state.$pageTitle.receive(on: DispatchQueue.main).sink { [weak connection] title in
            let clean = String(title.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
            connection?.send(.output, Data("\u{1b}]2;\(clean)\u{7}".utf8))
        }

        state.loadURL(hello.url)
    }

    // the page renders, and frames are taken, at the pace of the screen the terminal is on
    private func useScreen(_ screen: NSScreen) {
        guard window.terminalScreen != screen else { return }
        window.terminalScreen = screen
        renderer.setScreen(screen)
        if screen.backingScaleFactor != scale {
            scale = screen.backingScaleFactor
            applySize()
        }
    }

    // webkit stops rendering a page in a window it thinks nobody can see. this window is never on
    // screen, so that judgement is switched off; without it the page would freeze.
    private static func disableOcclusionDetection(_ view: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard view.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(view.method(for: selector), to: Setter.self)(view, selector, false)
    }

    private func applySize() {
        let size = NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        window.setContentSize(size)
        renderer.resize(width: pixelWidth, height: pixelHeight, columns: columns, rows: rows, scale: scale)
    }

    func end() {
        guard let onEnd else { return }
        self.onEnd = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        window.isTerminalFocused = false
        TerminalScrollRouter.shared.unregister(self)
        renderer.stop()
        webView.stopLoading()
        webView.removeFromSuperview()
        window.close()
        if !connection.isClosed {
            connection.send(.close, Data([0]))
            connection.close()
        }
        onEnd()
    }

    // MARK: Messages

    private func receive(_ type: TerminalLink.Message, _ payload: Data) {
        switch type {
        case .input:
            for event in parser.feed(payload) { handle(event) }
        case .resize:
            guard let size = try? JSONDecoder().decode(TerminalLink.Size.self, from: payload), size.width > 0, size.height > 0 else { return }
            resize(width: size.width, height: size.height, columns: size.columns, rows: size.rows)
        default:
            break
        }
    }

    private func resize(width: Int, height: Int, columns: Int, rows: Int) {
        guard width != pixelWidth || height != pixelHeight || columns != self.columns || rows != self.rows,
              width > 0, height > 0, columns > 0, rows > 0 else { return }
        pixelWidth = width
        pixelHeight = height
        self.columns = columns
        self.rows = rows
        applySize()
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .mouse(let report):
            handleMouse(report)
        case .key(let report):
            handleKey(report)
        case .text(let text):
            webView.insertText(text)
        case .paste(let text):
            // the paste came from this mac's clipboard, so pasting from it keeps rich content
            if NSPasteboard.general.string(forType: .string) == text {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: webView, from: nil)
            } else {
                webView.insertText(text)
            }
        case .focus(let focused):
            window.isTerminalFocused = focused
        case .resize(let rows, let columns, let height, let width):
            resize(width: width, height: height, columns: columns, rows: rows)
        case .graphicsReply(_, let ok):
            renderer.reply(ok: ok)
        }
    }

    // MARK: Mouse

    private func windowPoint(x: Int, y: Int) -> NSPoint {
        NSPoint(x: CGFloat(x) / scale, y: window.contentLayoutRect.height - CGFloat(y) / scale)
    }

    private func handleMouse(_ report: MouseReport) {
        trace("report \(report.kind) \(report.x),\(report.y)")
        pointer = windowPoint(x: report.x, y: report.y)
        let flags = Self.flags(report.modifiers)
        let now = ProcessInfo.processInfo.systemUptime
        // the pointer is over this pane, so the screen under it is the one the terminal is on
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            useScreen(screen)
        }

        switch report.kind {
        case .wheel:
            // the report says the gesture in progress is over this pane, so its system events are this
            // page's; the report itself only stands in when no system events are coming
            TerminalScrollRouter.shared.claim(for: self)
            if !TerminalScrollRouter.shared.isReceivingSystemEvents { wheelFallback(report, at: pointer) }
        case .motion:
            if let button = pressedButton {
                let type: NSEvent.EventType = button == 0 ? .leftMouseDragged : button == 2 ? .rightMouseDragged : .otherMouseDragged
                send(mouse: type, flags: flags, clickCount: clickCount, button: button)
            } else {
                send(mouse: .mouseMoved, flags: flags, clickCount: 0, button: 0)
            }
        case .press:
            let distance = hypot(pointer.x - lastClickPoint.x, pointer.y - lastClickPoint.y)
            clickCount = (now - lastClickTime < NSEvent.doubleClickInterval && distance < 4) ? clickCount + 1 : 1
            lastClickTime = now
            lastClickPoint = pointer
            pressedButton = report.button
            let type: NSEvent.EventType = report.button == 0 ? .leftMouseDown : report.button == 2 ? .rightMouseDown : .otherMouseDown
            send(mouse: type, flags: flags, clickCount: clickCount, button: report.button)
        case .release:
            let button = pressedButton ?? report.button
            pressedButton = nil
            let type: NSEvent.EventType = button == 0 ? .leftMouseUp : button == 2 ? .rightMouseUp : .otherMouseUp
            send(mouse: type, flags: flags, clickCount: clickCount, button: button)
        }
    }

    private func send(mouse type: NSEvent.EventType, flags: NSEvent.ModifierFlags, clickCount: Int, button: Int) {
        let pressed = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
        guard let event = NSEvent.mouseEvent(
            with: type, location: pointer, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: pressed ? 1 : 0
        ) else { return }
        switch type {
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        case .rightMouseDown: webView.rightMouseDown(with: event)
        case .rightMouseUp: webView.rightMouseUp(with: event)
        case .rightMouseDragged: webView.rightMouseDragged(with: event)
        case .otherMouseDown: webView.otherMouseDown(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        case .otherMouseDragged: webView.otherMouseDragged(with: event)
        default: simulateMouseMove(event)
        }
    }

    // webkit takes pointer moves only from its tracking areas, and only while its view is topmost under
    // the real cursor, which a view in an invisible window never is. this is webkit's own entry point for
    // moves that come from elsewhere, so hover, mouseover and cursor-driven ui all work.
    private func simulateMouseMove(_ event: NSEvent) {
        let selector = NSSelectorFromString("_simulateMouseMove:")
        guard webView.responds(to: selector) else { return }
        webView.perform(selector, with: event)
    }

    private func wheelFallback(_ report: MouseReport, at point: NSPoint) {
        let lines: (Int32, Int32) = [(3, 0), (-3, 0), (0, 3), (0, -3)][min(report.button, 3)]
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: lines.0, wheel2: lines.1, wheel3: 0) else { return }
        deliver(scroll: event, at: point)
    }

    // MARK: Native scrolling

    // a system scroll event of a gesture the terminal placed over this pane, at the pointer it reported
    func deliverNativeScroll(_ event: NSEvent) {
        trace(String(format: "native phase=%lu momentum=%lu dy=%.2f", event.phase.rawValue, event.momentumPhase.rawValue, event.scrollingDeltaY))
        guard let copy = event.cgEvent?.copy() else { return }
        deliver(scroll: copy, at: pointer)
    }

    // an event without a window is read in window coordinates, so placing it at the point's value in
    // screen coordinates lands it on that point of this window, wherever the window is
    private func deliver(scroll event: CGEvent, at point: NSPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: point.x, y: primaryHeight - point.y)
        guard let retargeted = NSEvent(cgEvent: event) else { return }
        webView.scrollWheel(with: retargeted)
        renderer.wake()
    }

    // MARK: Keyboard

    private func handleKey(_ report: KeyReport) {
        if report.action != .release, report.modifiers.subtracting(.capsLock) == .control, report.identity == .character("c") {
            end()
            return
        }
        if report.action != .release, report.modifiers.contains(.command), performShortcut(report) { return }

        let flags = Self.flags(report.modifiers)
        if case .modifier = report.identity {
            sendFlagsChanged(report, flags: flags)
            return
        }
        if report.identity == .capsLock {
            sendFlagsChanged(report, flags: flags)
            return
        }
        guard let key = KeyTranslation.translate(report) else { return }
        guard let event = NSEvent.keyEvent(
            with: report.action == .release ? .keyUp : .keyDown, location: pointer, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            isARepeat: report.action == .repeatPress, keyCode: key.keyCode
        ) else { return }
        if report.action == .release {
            webView.keyUp(with: event)
        } else if report.modifiers.contains(.command), webView.performKeyEquivalent(with: event) {
            return
        } else {
            webView.keyDown(with: event)
        }
    }

    private func sendFlagsChanged(_ report: KeyReport, flags: NSEvent.ModifierFlags) {
        guard let keyCode = KeyTranslation.modifierKeyCode(report.identity),
              let event = NSEvent.keyEvent(
                with: .flagsChanged, location: pointer, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode
              ) else { return }
        webView.flagsChanged(with: event)
    }

    // the menu shortcuts a page window would have, since there's no menu bar here
    private func performShortcut(_ report: KeyReport) -> Bool {
        guard case .character(let raw) = report.identity else {
            switch report.identity {
            case .left: webView.goBack()
            case .right: webView.goForward()
            default: return false
            }
            return true
        }
        let character = Character((report.base ?? raw).lowercased())
        let shift = report.modifiers.contains(.shift)
        switch character {
        case "a": NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: webView, from: nil)
        case "c": NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil)
        case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: webView, from: nil)
        case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: webView, from: nil)
        case "z": shift ? webView.undoManager?.redo() : webView.undoManager?.undo()
        case "[": webView.goBack()
        case "]": webView.goForward()
        case "r":
            if shift { webView.reloadFromOrigin() } else { webView.reload() }
        case "=", "+": webView.pageZoom = min(3, webView.pageZoom + 0.1)
        case "-": webView.pageZoom = max(0.5, webView.pageZoom - 0.1)
        case "0": webView.pageZoom = 1
        case "w": end()
        default: return false
        }
        return true
    }

    private static func flags(_ modifiers: TerminalModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.capsLock) { flags.insert(.capsLock) }
        return flags
    }
}

