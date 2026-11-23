import AppKit
import Darwin

// signal handlers can't capture anything, so they reach the run loop through this pipe
nonisolated(unsafe) private var signalPipeWrite: Int32 = -1

// `dawn <url>` run in a terminal, through the launcher script in the app's resources. The page itself
// lives in the running Dawn app (started in the background if needed); this process lends it the
// terminal: it switches on the modes a page needs, relays bytes both ways, and always switches them off
// afterwards. The sandbox doesn't allow changing terminal settings, so raw mode is the launcher's job.
nonisolated enum TerminalShim {
    static var isRequested: Bool {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, !arguments[1].hasPrefix("-") else { return false }
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    static func run() -> Never {
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0, settings.c_lflag & tcflag_t(ICANON) == 0 else {
            fputs("dawn: run pages with the dawn command in Dawn.app/Contents/Resources\n", stderr)
            exit(1)
        }
        guard let socket = connectToApp() else {
            fputs("dawn: couldn't reach Dawn\n", stderr)
            exit(1)
        }
        TerminalLink.writeAll(STDOUT_FILENO, Data(TerminalLink.enterModes.utf8))

        var pipeEnds: [Int32] = [0, 0]
        pipe(&pipeEnds)
        signalPipeWrite = pipeEnds[1]
        for number in [SIGWINCH, SIGTERM, SIGHUP, SIGINT] {
            signal(number) { received in
                var byte = UInt8(truncatingIfNeeded: received)
                _ = write(signalPipeWrite, &byte, 1)
            }
        }

        let size = terminalSize()
        let hello = TerminalLink.Hello(
            url: CommandLine.arguments[1], columns: size.columns, rows: size.rows, width: size.width, height: size.height
        )
        var status: Int32 = 0
        if let payload = try? JSONEncoder().encode(hello) {
            TerminalLink.writeAll(socket, TerminalLink.frame(.hello, payload))
            status = relay(socket, signals: pipeEnds[0])
        }

        TerminalLink.writeAll(STDOUT_FILENO, Data(TerminalLink.leaveModes.utf8))
        close(socket)
        exit(status)
    }

    private static func relay(_ socket: Int32, signals: Int32) -> Int32 {
        var fds = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
            pollfd(fd: signals, events: Int16(POLLIN), revents: 0),
        ]
        let capacity = 1 << 16
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        var incoming = Data()

        while true {
            if poll(&fds, nfds_t(fds.count), -1) < 0 {
                if errno == EINTR { continue }
                return 1
            }
            if fds[0].revents != 0 {
                let count = read(STDIN_FILENO, buffer, capacity)
                if count <= 0 { return 0 }
                TerminalLink.writeAll(socket, TerminalLink.frame(.input, Data(bytes: buffer, count: count)))
            }
            if fds[1].revents != 0 {
                let count = read(socket, buffer, capacity)
                if count <= 0 { return 0 }
                incoming.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
                for (type, payload) in TerminalLink.takeMessages(&incoming) {
                    switch type {
                    case .output: TerminalLink.writeAll(STDOUT_FILENO, payload)
                    case .close: return payload.first.map { Int32($0) } ?? 0
                    default: break
                    }
                }
            }
            if fds[2].revents != 0 {
                var received: UInt8 = 0
                guard read(signals, &received, 1) == 1 else { continue }
                if Int32(received) == SIGWINCH {
                    let size = terminalSize()
                    let message = TerminalLink.Size(columns: size.columns, rows: size.rows, width: size.width, height: size.height)
                    if let payload = try? JSONEncoder().encode(message) {
                        TerminalLink.writeAll(socket, TerminalLink.frame(.resize, payload))
                    }
                } else {
                    return 128 + Int32(received)
                }
            }
        }
    }

    private static func terminalSize() -> (columns: Int, rows: Int, width: Int, height: Int) {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        return (Int(size.ws_col), Int(size.ws_row), Int(size.ws_xpixel), Int(size.ws_ypixel))
    }

    // connects to the running app, launching it in the background first if it isn't running
    private static func connectToApp() -> Int32? {
        if let socket = connectOnce() { return socket }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appBundleURL(), configuration: configuration)
        for _ in 0..<150 {
            usleep(100_000)
            if let socket = connectOnce() { return socket }
        }
        return nil
    }

    private static func connectOnce() -> Int32? {
        guard var address = TerminalLink.socketAddress() else { return nil }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            return nil
        }
        return socket
    }

    // the command is usually a symlink to the executable, so the bundle is found from the real path
    private static func appBundleURL() -> URL {
        var size = UInt32(PATH_MAX)
        var path = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&path, &size)
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
