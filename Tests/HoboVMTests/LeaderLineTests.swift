import Foundation
import HoboControl
import Synchronization
import Testing
@testable import HoboVM

/// `exec`'s first stdout line is the guest shell's PID, kept for killing the command on cancel.
/// Needs no VM, so it runs without HOBO_INTEGRATION.
@Suite struct LeaderLineTests {
    final class Received: Sendable {
        let chunks = Mutex<[(GuestStream, String)]>([])
        func append(_ stream: GuestStream, _ data: Data) {
            chunks.withLock { $0.append((stream, String(decoding: data, as: UTF8.self))) }
        }
        var stdout: String { chunks.withLock { $0.filter { $0.0 == .stdout }.map(\.1).joined() } }
        var stderr: String { chunks.withLock { $0.filter { $0.0 == .stderr }.map(\.1).joined() } }
    }

    @Test func takesThePIDLineSplitAcrossChunks() {
        let received = Received()
        let leader = GuestSSH.LeaderLine(received.append)
        leader.receive(.stdout, Data("12".utf8))
        leader.receive(.stderr, Data("warn\n".utf8))
        #expect(leader.pid == nil)
        leader.receive(.stdout, Data("34\nhello\n".utf8))
        leader.receive(.stdout, Data("more\n".utf8))
        #expect(leader.pid == 1234)
        #expect(received.stdout == "hello\nmore\n")
        #expect(received.stderr == "warn\n")
    }

    @Test func aFirstLineThatIsNotAPIDIsOutput() {
        let received = Received()
        let leader = GuestSSH.LeaderLine(received.append)
        leader.receive(.stdout, Data("Welcome".utf8))
        leader.receive(.stdout, Data("!\n567\nrest".utf8))
        #expect(leader.pid == nil)
        #expect(received.stdout == "Welcome!\n567\nrest")
    }

    @Test func aPIDLineAloneSendsNothing() {
        let received = Received()
        let leader = GuestSSH.LeaderLine(received.append)
        leader.receive(.stdout, Data("99\n".utf8))
        #expect(leader.pid == 99)
        #expect(received.chunks.withLock { $0.isEmpty })
    }
}
