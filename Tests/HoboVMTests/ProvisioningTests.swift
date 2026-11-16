import Foundation
import HoboControl
import HoboCore
import Testing
@testable import HoboVM

/// A failed provision step's error carries the end of its output, which in a create can be
/// thousands of lines above the error. Needs no VM: the guest is a stub that prints and fails.
@Suite struct ProvisioningTests {
    /// Uploads succeed; the step's command prints `output` to stdout and exits with `status`.
    struct FailingShell: GuestShell {
        var output: String
        var status: Int32

        func run(_ command: String, quiet: Bool) async throws -> Int32 { 0 }
        func stream(_ command: String, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 {
            onOutput(.stdout, Data(output.utf8))
            return status
        }
        func copy(_ copy: GuestCopy, onOutput: @escaping @Sendable (GuestStream, Data) -> Void) async throws -> Int32 { 0 }
        func upload(_ local: URL, to remote: String) async throws {}
        func waitUntilReachable(timeout: Duration) async throws {}
    }

    @Test func aFailedStepsErrorEndsWithItsLastLines() async throws {
        let recipe = try Recipe.parse("""
        [source]
        ipsw = "latest"
        [[provision]]
        type = "shell"
        inline = "snap install foo"
        """, directory: URL(filePath: "/recipes"))
        let noise = (1...5000).map { "line \($0)\n" }.joined()
        let shell = FailingShell(output: noise + "Downloading 10%\r50%\r\n\nerror: snap store timed out\n", status: 100)
        do {
            try await Provisioning.run(recipe, shell: shell, log: { _ in }, onOutput: { _, _ in })
            Issue.record("the step should have failed")
        } catch let error as VMError {
            #expect(error.description == """
            provision step 1 exited with status 100; its output ended:
              line 4994
              line 4995
              line 4996
              line 4997
              line 4998
              line 4999
              line 5000
              Downloading 10%
              50%
              error: snap store timed out
            """)
        }
    }

    @Test func aStepWithNoOutputFailsWithJustItsStatus() {
        #expect(VMError.provisionFailed(step: 2, status: 1, lastLines: []).description
            == "provision step 2 exited with status 1")
    }
}
