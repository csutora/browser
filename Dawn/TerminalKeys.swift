import AppKit
import Carbon.HIToolbox

// Turns a terminal's key report into what an AppKit key event carries: the physical key code (which
// webkit reports as KeyboardEvent.code), the characters typed, and the characters without modifiers.
nonisolated enum KeyTranslation {
    struct Key {
        let keyCode: UInt16
        let characters: String
        let charactersIgnoringModifiers: String
    }

    static func translate(_ report: KeyReport) -> Key? {
        switch report.identity {
        case .character(let character):
            let base = report.base ?? Character(character.lowercased())
            // keys off the us layout get a code no physical key has, which webkit reports as unidentified
            let keyCode = UInt16(usLayout[base] ?? 0xFF)
            let shift = report.modifiers.contains(.shift)
            let shifted = report.shifted ?? Character(character.uppercased())
            let unmodified = String(shift ? shifted : character)
            var typed = report.text ?? unmodified
            if report.modifiers.contains(.control), let ascii = base.asciiValue, base.isLetter {
                typed = String(UnicodeScalar(ascii & 0x1F))
            }
            return Key(keyCode: keyCode, characters: typed, charactersIgnoringModifiers: unmodified)
        case .enter: return special(kVK_Return, "\r")
        case .tab: return special(kVK_Tab, "\t")
        case .backspace: return special(kVK_Delete, "\u{7f}")
        case .escape: return special(kVK_Escape, "\u{1b}")
        case .insert: return special(kVK_Help, function(NSHelpFunctionKey))
        case .delete: return special(kVK_ForwardDelete, function(NSDeleteFunctionKey))
        case .home: return special(kVK_Home, function(NSHomeFunctionKey))
        case .end: return special(kVK_End, function(NSEndFunctionKey))
        case .pageUp: return special(kVK_PageUp, function(NSPageUpFunctionKey))
        case .pageDown: return special(kVK_PageDown, function(NSPageDownFunctionKey))
        case .up: return special(kVK_UpArrow, function(NSUpArrowFunctionKey))
        case .down: return special(kVK_DownArrow, function(NSDownArrowFunctionKey))
        case .left: return special(kVK_LeftArrow, function(NSLeftArrowFunctionKey))
        case .right: return special(kVK_RightArrow, function(NSRightArrowFunctionKey))
        case .function(let number):
            guard number >= 1, number <= functionKeyCodes.count else { return nil }
            return special(functionKeyCodes[number - 1], function(NSF1FunctionKey + number - 1))
        case .modifier, .capsLock, .other:
            return nil
        }
    }

    static func modifierKeyCode(_ identity: KeyReport.Identity) -> UInt16? {
        switch identity {
        case .modifier(let modifier, let right):
            switch modifier {
            case .shift: return UInt16(right ? kVK_RightShift : kVK_Shift)
            case .control: return UInt16(right ? kVK_RightControl : kVK_Control)
            case .option: return UInt16(right ? kVK_RightOption : kVK_Option)
            case .command: return UInt16(right ? kVK_RightCommand : kVK_Command)
            default: return nil
            }
        case .capsLock:
            return UInt16(kVK_CapsLock)
        default:
            return nil
        }
    }

    private static func special(_ keyCode: Int, _ characters: String) -> Key {
        Key(keyCode: UInt16(keyCode), characters: characters, charactersIgnoringModifiers: characters)
    }

    private static func function(_ value: Int) -> String {
        String(UnicodeScalar(UInt16(value)).map(Character.init) ?? " ")
    }

    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    // the key at each us-layout position, which the kitty protocol reports as the base layout key
    private static let usLayout: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave, " ": kVK_Space,
    ]
}
