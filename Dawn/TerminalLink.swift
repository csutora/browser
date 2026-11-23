import Darwin
import Foundation

// The connection between `dawn <url>` running in a terminal and the Dawn app showing the page. Both are
// the same sandboxed executable, so they share a container, and the socket lives inside it. Messages are
// a type byte, a little-endian 32-bit length, and the payload.
nonisolated enum TerminalLink {
    enum Message: UInt8 {
        // from the terminal side
        case hello = 1
        case input = 2
        case resize = 3
        // from the app
        case output = 64
        case close = 65
    }

    struct Hello: Codable {
        var url: String
        var columns: Int
        var rows: Int
        var width: Int
        var height: Int
    }

    struct Size: Codable {
        var columns: Int
        var rows: Int
        var width: Int
        var height: Int
    }

    static var socketPath: String {
        NSHomeDirectory() + "/tmp/terminal.sock"
    }

    // what the terminal is switched into for a page, and back out of afterwards. the terminal side owns
    // both, so the terminal is restored even if the app goes away mid-page.
    // alternate screen, hidden cursor, every mouse event reported in pixels, focus reports, bracketed
    // paste, size reports in pixels, and kitty keyboard reporting of every key with its text
    static let enterModes = "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1016h\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?2048h\u{1b}[>31u"
    static let leaveModes = "\u{1b}]111\u{1b}\\\u{1b}[0m\u{1b}[2J\u{1b}_Ga=d,d=A,q=2\u{1b}\\\u{1b}[<u\u{1b}[?2026l\u{1b}[?2048l\u{1b}[?2004l\u{1b}[?1004l\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1003l\u{1b}[?25h\u{1b}[?1049l"

    static func frame(_ type: Message, _ payload: Data) -> Data {
        var out = Data([type.rawValue])
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    // splits complete messages off the front of a receive buffer
    static func takeMessages(_ buffer: inout Data) -> [(Message, Data)] {
        var messages: [(Message, Data)] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = Int(buffer[offset + 1]) | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3]) << 16 | Int(buffer[offset + 4]) << 24
            guard buffer.endIndex - offset - 5 >= length else { break }
            let payload = buffer.subdata(in: (offset + 5)..<(offset + 5 + length))
            if let type = Message(rawValue: buffer[offset]) { messages.append((type, payload)) }
            offset += 5 + length
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
        return messages
    }

    static func socketAddress() -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    // writes everything, waiting out a full socket or terminal
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let written = Darwin.write(fd, pointer, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&poller, 1, 1000)
                        continue
                    }
                    return false
                }
                pointer += written
                left -= written
            }
            return true
        }
    }
}
