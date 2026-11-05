/// Single-quotes `value` for a POSIX shell.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Quotes an argv for a POSIX shell, as one line.
public func shellQuote(_ arguments: [String]) -> String {
    arguments.map { shellQuote($0) }.joined(separator: " ")
}
