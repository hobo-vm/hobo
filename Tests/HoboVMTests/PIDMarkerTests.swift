import Foundation
import HoboControl
import Synchronization
import Testing
@testable import HoboVM

/// `exec` finds the guest shell's PID after a per-run marker in stdout, to kill the command on
/// cancel. Needs no VM, so it runs without HOBO_INTEGRATION.
@Suite struct PIDMarkerTests {
    final class Received: Sendable {
        let chunks = Mutex<[(GuestStream, String)]>([])
        func append(_ stream: GuestStream, _ data: Data) {
            chunks.withLock { $0.append((stream, String(decoding: data, as: UTF8.self))) }
        }
        var stdout: String { chunks.withLock { $0.filter { $0.0 == .stdout }.map(\.1).joined() } }
        var stderr: String { chunks.withLock { $0.filter { $0.0 == .stderr }.map(\.1).joined() } }
    }

    let received = Received()
    var marker: GuestSSH.PIDMarker { GuestSSH.PIDMarker(token: "t0k", received.append) }

    @Test func takesThePIDSplitAcrossChunks() {
        let marker = marker
        marker.receive(.stdout, Data("hobo-pi".utf8))
        marker.receive(.stderr, Data("warn\n".utf8))
        marker.receive(.stdout, Data("d-t0k:12".utf8))
        #expect(marker.pid == nil)
        marker.receive(.stdout, Data("34\nhello\n".utf8))
        marker.receive(.stdout, Data("more\n".utf8))
        marker.finish()
        #expect(marker.pid == 1234)
        #expect(received.stdout == "hello\nmore\n")
        #expect(received.stderr == "warn\n")
    }

    /// A guest startup file (e.g. ~/.zshenv) that prints lines before the marker.
    @Test func startupOutputBeforeTheMarkerPassesThrough() {
        let marker = marker
        marker.receive(.stdout, Data("hello-from-zshenv\nsecond line\nno newline".utf8))
        marker.receive(.stdout, Data("hobo-pid-t0k:829\nhi\n".utf8))
        marker.finish()
        #expect(marker.pid == 829)
        #expect(received.stdout == "hello-from-zshenv\nsecond line\nno newlinehi\n")
    }

    @Test func outputIsKeptWhenTheMarkerNeverArrives() {
        let marker = marker
        marker.receive(.stdout, Data("bye\n567\nhobo-p".utf8))
        marker.finish()
        #expect(marker.pid == nil)
        #expect(received.stdout == "bye\n567\nhobo-p")
    }

    @Test func aMarkerLineAloneSendsNothing() {
        let marker = marker
        marker.receive(.stdout, Data("hobo-pid-t0k:99\n".utf8))
        marker.finish()
        #expect(marker.pid == 99)
        #expect(received.chunks.withLock { $0.isEmpty })
    }
}
