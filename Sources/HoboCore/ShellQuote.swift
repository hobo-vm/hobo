import Foundation

/// Single-quotes `value` for a POSIX shell.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Quotes an argv for a POSIX shell, as one line.
public func shellQuote(_ arguments: [String]) -> String {
    arguments.map { shellQuote($0) }.joined(separator: " ")
}

/// An argv as the line a person would paste into a shell: an argument is quoted only if the shell
/// would change it bare. It can hold `;`, `$`, quotes, globs, a newline or nothing at all, not
/// just spaces.
public func shellCommandLine(_ arguments: [String]) -> String {
    arguments.map { argument in
        let bare = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "@%+=:,./-_".unicodeScalars.contains($0))
        }
        return bare ? argument : shellQuote(argument)
    }.joined(separator: " ")
}
