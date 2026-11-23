import Foundation

// What a terminal reports, decoded from the byte stream it sends a program in the modes TerminalLink
// enables: sgr mouse reports in pixels, the kitty keyboard protocol with every key and its text,
// bracketed paste, focus changes, in-band size reports, and kitty graphics acknowledgements.
nonisolated enum TerminalEvent {
    case mouse(MouseReport)
    case key(KeyReport)
    case text(String)
    case paste(String)
    case focus(Bool)
    case resize(rows: Int, columns: Int, height: Int, width: Int)
    case graphicsReply(id: Int, ok: Bool)
}

nonisolated struct TerminalModifiers: OptionSet {
    let rawValue: Int
    static let shift = TerminalModifiers(rawValue: 1)
    static let option = TerminalModifiers(rawValue: 2)
    static let control = TerminalModifiers(rawValue: 4)
    static let command = TerminalModifiers(rawValue: 8)
    static let capsLock = TerminalModifiers(rawValue: 64)
}

nonisolated struct MouseReport {
    enum Kind {
        case press
        case release
        case motion
        case wheel
    }

    let kind: Kind
    // 0 left, 1 middle, 2 right, 3 none (motion with no button); for wheel, 0 up, 1 down, 2 left, 3 right
    let button: Int
    // pixels from the top left of the terminal's text area
    let x: Int
    let y: Int
    let modifiers: TerminalModifiers
}

nonisolated struct KeyReport {
    enum Identity: Equatable {
        case character(Character)
        case enter, tab, backspace, escape
        case insert, delete, home, end, pageUp, pageDown
        case up, down, left, right
        case function(Int)
        case modifier(TerminalModifiers, right: Bool)
        case capsLock
        case other
    }

    enum Action {
        case press
        case repeatPress
        case release
    }

    let identity: Identity
    // the same key's character with shift, and its position on a us layout, when the terminal knows them
    let shifted: Character?
    let base: Character?
    let modifiers: TerminalModifiers
    let action: Action
    let text: String?
}

nonisolated struct TerminalInputParser {
    private enum State {
        case ground
        case escape
        case csi
        case apc
        case apcEscape
        case osc
        case oscEscape
        case paste
    }

    private var state = State.ground
    private var sequence: [UInt8] = []
    private var text: [UInt8] = []

    mutating func feed(_ data: Data) -> [TerminalEvent] {
        var events: [TerminalEvent] = []
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B {
                    flushText(&events)
                    state = .escape
                } else {
                    text.append(byte)
                }
            case .escape:
                sequence.removeAll(keepingCapacity: true)
                switch byte {
                case UInt8(ascii: "["): state = .csi
                case UInt8(ascii: "_"): state = .apc
                case UInt8(ascii: "]"): state = .osc
                default:
                    text.append(byte)
                    state = .ground
                }
            case .csi:
                if byte >= 0x40 && byte <= 0x7E {
                    state = .ground
                    if byte == UInt8(ascii: "~"), sequence == Array("200".utf8) {
                        state = .paste
                        sequence.removeAll(keepingCapacity: true)
                    } else if let event = Self.csi(sequence, final: byte) {
                        events.append(event)
                    }
                } else {
                    sequence.append(byte)
                }
            case .apc:
                if byte == 0x1B { state = .apcEscape } else { sequence.append(byte) }
            case .apcEscape:
                state = .ground
                if let event = Self.apc(sequence) { events.append(event) }
            case .osc:
                if byte == 0x1B { state = .oscEscape } else if byte == 0x07 { state = .ground }
            case .oscEscape:
                state = .ground
            case .paste:
                sequence.append(byte)
                let end = Array("\u{1b}[201~".utf8)
                if sequence.count >= end.count, Array(sequence.suffix(end.count)) == end {
                    events.append(.paste(String(decoding: sequence.dropLast(end.count), as: UTF8.self)))
                    sequence.removeAll(keepingCapacity: true)
                    state = .ground
                }
            }
        }
        flushText(&events)
        return events
    }

    // text typed outside any sequence, such as composed input; held back while it ends mid-character
    private mutating func flushText(_ events: inout [TerminalEvent]) {
        guard !text.isEmpty else { return }
        var complete = text.count
        for back in 1...min(3, text.count) {
            let byte = text[text.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if needed > back { complete = text.count - back }
            break
        }
        guard complete > 0 else { return }
        // control bytes are keys as terminals send them without the kitty protocol (or as tools write
        // them into a terminal); everything between them is text
        var run = text.startIndex
        for index in text.startIndex..<complete {
            guard let key = Self.legacyKey(text[index]) else { continue }
            if run < index { events.append(.text(String(decoding: text[run..<index], as: UTF8.self))) }
            // such terminals never report releases, so each key is a press and its release
            events.append(.key(key))
            events.append(.key(KeyReport(identity: key.identity, shifted: nil, base: nil, modifiers: key.modifiers, action: .release, text: nil)))
            run = index + 1
        }
        if run < complete { events.append(.text(String(decoding: text[run..<complete], as: UTF8.self))) }
        text.removeFirst(complete)
    }

    private static func legacyKey(_ byte: UInt8) -> KeyReport? {
        let identity: KeyReport.Identity
        var modifiers: TerminalModifiers = []
        switch byte {
        case 0x0D, 0x0A: identity = .enter
        case 0x09: identity = .tab
        case 0x08, 0x7F: identity = .backspace
        case 0x01...0x1A:
            identity = .character(Character(UnicodeScalar(byte + 0x60)))
            modifiers = .control
        default: return nil
        }
        return KeyReport(identity: identity, shifted: nil, base: nil, modifiers: modifiers, action: .press, text: nil)
    }

    private static func apc(_ body: [UInt8]) -> TerminalEvent? {
        let string = String(decoding: body, as: UTF8.self)
        guard string.hasPrefix("G") else { return nil }
        let parts = string.dropFirst().split(separator: ";", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        var id = 0
        for pair in parts[0].split(separator: ",") where pair.hasPrefix("i=") {
            id = Int(pair.dropFirst(2)) ?? 0
        }
        return .graphicsReply(id: id, ok: parts[1] == "OK")
    }

    private static func csi(_ body: [UInt8], final: UInt8) -> TerminalEvent? {
        var string = String(decoding: body, as: UTF8.self)
        let finalCharacter = Character(UnicodeScalar(final))

        if string.hasPrefix("<"), finalCharacter == "M" || finalCharacter == "m" {
            string.removeFirst()
            let numbers = string.split(separator: ";").compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            return .mouse(mouse(code: numbers[0], x: numbers[1], y: numbers[2], released: finalCharacter == "m"))
        }
        if string.hasPrefix("?") || string.hasPrefix(">") || string.hasPrefix("=") { return nil }

        let fields = string.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        }
        func field(_ index: Int, _ sub: Int = 0) -> Int? {
            guard index < fields.count, sub < fields[index].count else { return nil }
            return fields[index][sub]
        }

        switch finalCharacter {
        case "I": return .focus(true)
        case "O": return .focus(false)
        case "t":
            guard field(0) == 48, let rows = field(1), let columns = field(2), let height = field(3), let width = field(4) else { return nil }
            return .resize(rows: rows, columns: columns, height: height, width: width)
        case "u":
            guard let code = field(0) else { return nil }
            var textValue: String?
            if fields.count > 2 {
                let scalars = fields[2].compactMap { $0 }.compactMap(UnicodeScalar.init)
                if !scalars.isEmpty { textValue = String(String.UnicodeScalarView(scalars)) }
            }
            return .key(key(
                identity(forCode: code), code: code, shifted: field(0, 1), base: field(0, 2),
                modifierField: field(1) ?? 1, actionField: field(1, 1) ?? 1, text: textValue
            ))
        case "~":
            guard let number = field(0) else { return nil }
            let identity: KeyReport.Identity
            switch number {
            case 2: identity = .insert
            case 3: identity = .delete
            case 1, 7: identity = .home
            case 4, 8: identity = .end
            case 5: identity = .pageUp
            case 6: identity = .pageDown
            case 11...15: identity = .function(number - 10)
            case 17...21: identity = .function(number - 11)
            case 23, 24: identity = .function(number - 12)
            default: return nil
            }
            return .key(key(identity, code: 0, shifted: nil, base: nil, modifierField: field(1) ?? 1, actionField: field(1, 1) ?? 1, text: nil))
        case "A", "B", "C", "D", "H", "F", "P", "Q", "R", "S":
            let identities: [Character: KeyReport.Identity] = [
                "A": .up, "B": .down, "C": .right, "D": .left, "H": .home, "F": .end,
                "P": .function(1), "Q": .function(2), "R": .function(3), "S": .function(4),
            ]
            return .key(key(identities[finalCharacter]!, code: 0, shifted: nil, base: nil, modifierField: field(1) ?? 1, actionField: field(1, 1) ?? 1, text: nil))
        default:
            return nil
        }
    }

    private static func mouse(code: Int, x: Int, y: Int, released: Bool) -> MouseReport {
        var modifiers: TerminalModifiers = []
        if code & 4 != 0 { modifiers.insert(.shift) }
        if code & 8 != 0 { modifiers.insert(.option) }
        if code & 16 != 0 { modifiers.insert(.control) }
        let kind: MouseReport.Kind
        if code & 64 != 0 {
            kind = .wheel
        } else if code & 32 != 0 {
            kind = .motion
        } else {
            kind = released ? .release : .press
        }
        return MouseReport(kind: kind, button: code & 3, x: max(0, x - 1), y: max(0, y - 1), modifiers: modifiers)
    }

    private static func key(
        _ identity: KeyReport.Identity, code: Int, shifted: Int?, base: Int?, modifierField: Int, actionField: Int, text: String?
    ) -> KeyReport {
        let action: KeyReport.Action = actionField == 3 ? .release : actionField == 2 ? .repeatPress : .press
        func character(_ value: Int?) -> Character? {
            guard let value, let scalar = UnicodeScalar(value) else { return nil }
            return Character(scalar)
        }
        // control characters as text (from enter, tab and so on) are the key, not text to insert
        let insertable = text.flatMap { value in value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } ? value : nil }
        return KeyReport(
            identity: identity, shifted: character(shifted), base: character(base),
            modifiers: TerminalModifiers(rawValue: max(0, modifierField - 1)), action: action, text: insertable
        )
    }

    private static func identity(forCode code: Int) -> KeyReport.Identity {
        switch code {
        case 13, 57414: return .enter
        case 9: return .tab
        case 127, 8: return .backspace
        case 27: return .escape
        case 57441: return .modifier(.shift, right: false)
        case 57442: return .modifier(.control, right: false)
        case 57443: return .modifier(.option, right: false)
        case 57444: return .modifier(.command, right: false)
        case 57447: return .modifier(.shift, right: true)
        case 57448: return .modifier(.control, right: true)
        case 57449: return .modifier(.option, right: true)
        case 57450: return .modifier(.command, right: true)
        case 57358: return .capsLock
        case 57376...57398: return .function(code - 57376 + 13)
        case 57399...57408: return .character(Character(UnicodeScalar(UInt8(ascii: "0") + UInt8(code - 57399))))
        case 57409: return .character(".")
        case 57410: return .character("/")
        case 57411: return .character("*")
        case 57412: return .character("-")
        case 57413: return .character("+")
        case 57415: return .character("=")
        case 0xE000...0xF8FF: return .other
        default:
            guard let scalar = UnicodeScalar(code) else { return .other }
            return .character(Character(scalar))
        }
    }
}
