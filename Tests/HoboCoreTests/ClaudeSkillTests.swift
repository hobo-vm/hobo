import Foundation
import Testing
@testable import HoboCore

struct ClaudeSkillTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ClaudeSkillTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private var skill: ClaudeSkill { .global(home: root) }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: skill.directory, withIntermediateDirectories: true)
        try text.write(to: skill.file, atomically: true, encoding: .utf8)
    }

    private func read() throws -> String { try String(contentsOf: skill.file, encoding: .utf8) }

    @Test func globalSkillLivesUnderClaudeSkills() {
        #expect(skill.file.path == root.appending(path: ".claude/skills/hobo/SKILL.md").path)
    }

    @Test func contentsAreFrontmatterThenTheGuidance() {
        let text = ClaudeSkill.contents(version: "1.2.3")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.prefix(5) == ["---", "name: hobo", "description: \"\(AgentGuidance.skillDescription)\"",
                                    "hobo-version: 1.2.3", "---"])
        #expect(text.hasSuffix(AgentGuidance.skillBody + "\n"))
        #expect(ClaudeSkill.isHobos(text))
    }

    @Test func markerCountsOnlyInTheFrontmatter() {
        #expect(!ClaudeSkill.isHobos("---\nname: hobo\n---\nhobo-version: 1\n"))
        #expect(!ClaudeSkill.isHobos("hobo-version: 1\n"))
        #expect(!ClaudeSkill.isHobos(""))
    }

    @Test func installWritesAndRefreshesHobosCopy() throws {
        try skill.install(force: false)
        #expect(try read() == ClaudeSkill.contents())
        try write(ClaudeSkill.contents(version: "0.0.0"))
        try skill.install(force: false)
        #expect(try read() == ClaudeSkill.contents())
    }

    @Test func installRefusesAnotherSkillWithoutForce() throws {
        try write("---\nname: hobo\n---\nmine\n")
        #expect(throws: ClaudeSkillError.notHobos(skill.directory.path, forceTo: "replace")) {
            try skill.install(force: false)
        }
        #expect(try read() == "---\nname: hobo\n---\nmine\n")
        try skill.install(force: true)
        #expect(try read() == ClaudeSkill.contents())
    }

    @Test func uninstallRemovesHobosDirectory() throws {
        try skill.install(force: false)
        #expect(try skill.uninstall(force: false))
        #expect(!FileManager.default.fileExists(atPath: skill.directory.path))
        #expect(try !skill.uninstall(force: false))
    }

    @Test func uninstallRefusesAnotherSkillWithoutForce() throws {
        // A directory without SKILL.md isn't hobo's either.
        try FileManager.default.createDirectory(at: skill.directory, withIntermediateDirectories: true)
        #expect(throws: ClaudeSkillError.notHobos(skill.directory.path, forceTo: "remove")) {
            try skill.uninstall(force: false)
        }
        #expect(FileManager.default.fileExists(atPath: skill.directory.path))
        #expect(try skill.uninstall(force: true))
        #expect(!FileManager.default.fileExists(atPath: skill.directory.path))
    }

    @Test func projectSkillLivesAtTheGitRoot() throws {
        let repo = root.appending(path: "repo")
        let nested = repo.appending(path: "a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        // A worktree's .git is a file.
        try "gitdir: elsewhere\n".write(to: repo.appending(path: ".git"), atomically: true, encoding: .utf8)
        let skill = try ClaudeSkill.project(containing: nested)
        #expect(skill.directory.path == repo.appending(path: ".claude/skills/hobo").standardizedFileURL.path)
    }

    @Test func projectNeedsAGitRepository() {
        let outside = URL(filePath: "/")
        #expect(throws: ClaudeSkillError.notInGitRepository(outside.path)) { try ClaudeSkill.project(containing: outside) }
    }
}
