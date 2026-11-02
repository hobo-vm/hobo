import Foundation

/// The Claude Code skill `hobo claude install` writes: `AgentGuidance` as `<skills>/hobo/SKILL.md`.
/// A `hobo-version` frontmatter line marks the file as hobo's, so hobo overwrites or removes only
/// its own copy and refuses (without `force`) to touch a skill someone else put there.
public struct ClaudeSkill: Sendable {
    /// The skill's directory, `<skills>/hobo`.
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/.claude/skills/hobo`, for every project. `~` is `$HOME`, as Claude Code resolves it.
    public static func global(home: URL = homeDirectory()) -> ClaudeSkill {
        ClaudeSkill(directory: skillsDirectory(under: home))
    }

    public static func homeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `<git root>/.claude/skills/hobo`, for the repository containing `directory`.
    public static func project(containing directory: URL) throws -> ClaudeSkill {
        guard let root = gitRoot(containing: directory) else { throw ClaudeSkillError.notInGitRepository(directory.path) }
        return ClaudeSkill(directory: skillsDirectory(under: root))
    }

    private static func skillsDirectory(under root: URL) -> URL {
        root.appending(path: ".claude/skills/\(AgentGuidance.skillName)", directoryHint: .isDirectory)
    }

    /// The nearest directory at or above `directory` holding `.git` (a directory, or a worktree's file).
    static func gitRoot(containing directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: current.appending(path: ".git").path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    public var file: URL { directory.appending(path: "SKILL.md") }

    /// SKILL.md: frontmatter, then the guidance. The description is double-quoted (YAML's
    /// JSON-compatible form) because it contains `: `.
    public static func contents(version: String = Hobo.version) -> String {
        """
        ---
        name: \(AgentGuidance.skillName)
        description: \(yamlQuoted(AgentGuidance.skillDescription))
        \(markerKey): \(version)
        ---

        \(AgentGuidance.skillBody)

        """
    }

    static let markerKey = "hobo-version"

    private static func yamlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Whether SKILL.md's frontmatter carries the `hobo-version` line.
    static func isHobos(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return false }
        for line in lines.dropFirst() {
            if line == "---" { return false }
            if line.hasPrefix(markerKey + ":") { return true }
        }
        return false
    }

    /// What is at `directory` now.
    enum State: Equatable { case absent, hobos, foreign }

    func state() -> State {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .absent }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .foreign }
        return Self.isHobos(text) ? .hobos : .foreign
    }

    /// Writes SKILL.md, replacing hobo's own copy. Another skill in the way needs `force`.
    public func install(force: Bool) throws {
        if state() == .foreign && !force { throw ClaudeSkillError.notHobos(directory.path, forceTo: "replace") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.contents().write(to: file, atomically: true, encoding: .utf8)
    }

    /// Removes the skill's directory and reports whether there was one. A directory that isn't
    /// hobo's needs `force`.
    @discardableResult
    public func uninstall(force: Bool) throws -> Bool {
        switch state() {
        case .absent: return false
        case .foreign where !force: throw ClaudeSkillError.notHobos(directory.path, forceTo: "remove")
        case .hobos, .foreign:
            try FileManager.default.removeItem(at: directory)
            return true
        }
    }
}

public enum ClaudeSkillError: Error, CustomStringConvertible, Equatable {
    case notInGitRepository(String)
    /// The path, and what `--force` would do to it.
    case notHobos(String, forceTo: String)

    public var description: String {
        switch self {
        case .notInGitRepository(let path):
            "\(path) isn't in a git repository, so there's no project to install the skill into"
        case .notHobos(let path, let action):
            "\(path) wasn't written by hobo (it has no SKILL.md with a \(ClaudeSkill.markerKey) line); pass --force to \(action) it"
        }
    }
}
