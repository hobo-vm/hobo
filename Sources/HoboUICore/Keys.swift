import ArgumentParser

/// A modifier key, for `key cmd+k` and `click --mods cmd,shift`.
public enum Modifier: String, CaseIterable, Codable, Sendable {
    case command, shift, option, control, function

    static let aliases: [String: Modifier] = [
        "cmd": .command, "command": .command, "shift": .shift,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control, "fn": .function,
    ]

    public static func parse(_ text: String) -> Modifier? { aliases[text.lowercased()] }

    /// `cmd,shift` (or `cmd+shift`).
    public static func parseList(_ text: String) throws(ValidationError) -> [Modifier] {
        var modifiers: [Modifier] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == "+" }) {
            guard let modifier = parse(String(part)) else { throw KeyError.unknownModifier(String(part)).asUsage }
            modifiers.append(modifier)
        }
        return modifiers
    }
}

/// A key press: modifiers and the key's virtual key code (US ANSI layout, which is what the
/// key's position means; `type` sends text without regard to layout).
public struct KeySpec: Equatable, Sendable {
    public var modifiers: [Modifier]
    /// The key's name, the same for every way of writing it (`minus` and `-` are `-`, `enter` is
    /// `return`, `+` is `=`, the key it's on), for the Linux and Windows backends.
    public var key: String
    /// macOS's virtual key code for it.
    public var keyCode: UInt16

    public init(modifiers: [Modifier], key: String) {
        self.modifiers = modifiers
        self.key = key
        keyCode = Self.keyCodes[key] ?? 0
    }

    /// `cmd+shift+k`, `return`, `ctrl+f2`, `cmd++` or `cmd+plus` (the plus key), `cmd+-` or `cmd+minus`.
    public static func parse(_ text: String) throws(ValidationError) -> KeySpec {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // `cmd++` splits as ["cmd", "", ""]: the last key is "+".
        if text.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let keyName = parts.last, !keyName.isEmpty else { throw KeyError.noKey(text).asUsage }
        var modifiers: [Modifier] = []
        for part in parts.dropLast() {
            guard let modifier = Modifier.parse(part) else { throw KeyError.unknownModifier(part).asUsage }
            if !modifiers.contains(modifier) { modifiers.append(modifier) }
        }
        let name = keyName.lowercased()
        guard keyCodes[name] != nil else { throw KeyError.unknownKey(keyName).asUsage }
        return KeySpec(modifiers: modifiers, key: canonical[name] ?? name)
    }

    /// Virtual key codes (Carbon's `kVK_*`), by name.
    static let keyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
            "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
            "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
            "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
            "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75,
            "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        ]
        // Shifted on a US keyboard, but named by the key they're on.
        codes["+"] = codes["="]
        // Punctuation by name, since `cmd+minus` is as natural a guess as `cmd+-`.
        let names = [
            "minus": "-", "plus": "+", "equals": "=", "equal": "=", "comma": ",", "period": ".", "dot": ".",
            "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'", "backtick": "`", "grave": "`",
            "leftbracket": "[", "rightbracket": "]",
        ]
        for (name, key) in names { codes[name] = codes[key] }
        return codes
    }()

    /// The one name `key` gives each key with more than one.
    static let canonical: [String: String] = [
        "enter": "return", "backspace": "delete", "esc": "escape", "+": "=", "plus": "=",
        "minus": "-", "equals": "=", "equal": "=", "comma": ",", "period": ".", "dot": ".",
        "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'", "backtick": "`", "grave": "`",
        "leftbracket": "[", "rightbracket": "]",
    ]

    /// Every key name after `canonical`, for a backend's table to cover.
    public static var names: Set<String> { Set(keyCodes.keys.map { canonical[$0] ?? $0 }) }
}

/// What's wrong with a key or modifier as typed. The parsers throw it as a `ValidationError`
/// (`asUsage`), so that wherever a command's `validate()` meets one, it prints with that command's usage.
public enum KeyError: Equatable, CustomStringConvertible {
    case noKey(String)
    case unknownKey(String)
    case unknownModifier(String)

    public var description: String {
        switch self {
        case .noKey(let text): "\(text) names no key, e.g. cmd+k"
        case .unknownKey(let key): "unknown key \(key) (letters, digits, punctuation or its name, e.g. - or minus, + or plus; return, tab, space, delete, escape, arrows, home, end, pageup, pagedown, f1-f12)"
        case .unknownModifier(let modifier): "unknown modifier \(modifier) (cmd, shift, opt, ctrl, fn)"
        }
    }

    var asUsage: ValidationError { ValidationError(description) }
}
