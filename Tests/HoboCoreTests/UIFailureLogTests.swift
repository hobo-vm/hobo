import Foundation
import Testing
@testable import HoboCore

@Suite struct UIFailureLogTests {
    let file = FileManager.default.temporaryDirectory.appending(path: "hobo-ui-failures-\(UUID().uuidString)/ui-failures.log")
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func cleanUp() { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    func contents() throws -> String { try String(contentsOf: file, encoding: .utf8) }

    @Test func anEntryIsTheCommandLineItsResultAndWhatItPrinted() throws {
        defer { cleanUp() }
        let log = UIFailureLog(file: file)
        let output = Data("hobo-ui: timed out after 30s waiting for app Wisp\n- window \"Main\" [e1]\n".utf8)
        try log.record(vm: "wisp-9431", arguments: ["wait", "--timeout", "30", "--text", "3 photos", "--app", "app.wisp"], result: "exit 1", output: output, at: date)
        try log.record(vm: "dev", arguments: ["snapshot"], result: "dev is not running (hobo start dev)", output: Data(), at: date)
        #expect(try contents() == """
            === 2027-01-15T08:00:00Z hobo ui wisp-9431 wait --timeout 30 --text '3 photos' --app app.wisp: exit 1
            hobo-ui: timed out after 30s waiting for app Wisp
            - window "Main" [e1]

            === 2027-01-15T08:00:00Z hobo ui dev snapshot: dev is not running (hobo start dev)


            """)
    }

    /// Only an entry's first line starts with the marker, so the oldest entries can be found and dropped.
    @Test func outputThatLooksLikeAnEntryIsIndented() throws {
        defer { cleanUp() }
        try UIFailureLog(file: file).record(vm: "dev", arguments: ["snapshot"], result: "exit 1", output: Data("=== text\nmore\n".utf8), at: date)
        #expect(try contents().split(separator: "\n").map(String.init) == ["=== 2027-01-15T08:00:00Z hobo ui dev snapshot: exit 1", " === text", "more"])
    }

    @Test func pastItsLimitTheOldestEntriesGo() throws {
        defer { cleanUp() }
        let log = UIFailureLog(file: file, limit: 2000)
        for number in 1...40 {
            try log.record(vm: "dev", arguments: ["wait", "--ref", "e\(number)"], result: "exit 1", output: Data(String(repeating: "x", count: 100).utf8), at: date)
        }
        let text = try contents()
        #expect(text.utf8.count <= 2000)
        #expect(text.hasPrefix(UIFailureLog.marker))
        #expect(text.contains("--ref e40:"))
        #expect(!text.contains("--ref e1:"))
        // Whole entries: each has its 100 bytes of output.
        let entries = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        #expect(entries.count > 3)
        #expect(entries.allSatisfy { $0.hasPrefix(UIFailureLog.marker) && $0.hasSuffix(String(repeating: "x", count: 100)) })
    }

    @Test func oneCommandsOutputIsCutShortRatherThanPushingOutTheRest() throws {
        defer { cleanUp() }
        let log = UIFailureLog(file: file, limit: 2000)
        try log.record(vm: "dev", arguments: ["snapshot"], result: "exit 1", output: Data("first".utf8), at: date)
        try log.record(vm: "dev", arguments: ["wait", "--app", "X"], result: "exit 1", output: Data(String(repeating: "y", count: 900).utf8), at: date)
        let text = try contents()
        #expect(text.contains("first"))
        #expect(text.contains(String(repeating: "y", count: 500) + "\n… (400 more bytes)\n"))
    }
}
