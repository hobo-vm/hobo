import Foundation
import Testing
@testable import HoboCore

@Suite struct ProvisionerTests {
    @Test func invalidProvisionerNamesTheStepOneBased() {
        #expect(throws: RecipeError.invalidProvisioner(1, "file needs source and destination")) {
            try Recipe.parse("""
            [source]
            ipsw = "latest"
            [[provision]]
            type = "shell"
            inline = "true"
            [[provision]]
            type = "file"
            """, directory: URL(filePath: "/recipes"))
        }
        #expect(RecipeError.invalidProvisioner(1, "file needs source and destination").description
            == "provision step 2: file needs source and destination")
    }

    @Test func powerShellCommandSetsSortedEnvAndPassesOnTheExitStatus() throws {
        let step = try #require(try Recipe.parse("""
            [source]
            iso = "x.iso"
            sha256 = "\(String(repeating: "a", count: 64))"
            [[provision]]
            type = "shell"
            inline = "exit 0"
            env = { B = "it's", A = "1" }
            """, directory: URL(filePath: "/r/")).provisioners.first)
        #expect(step.powerShellCommand(running: "C:/Windows/Temp/s.ps1") == """
            $env:A = '1'; $env:B = 'it''s'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:/Windows/Temp/s.ps1'; exit $LASTEXITCODE
            """)
    }

    @Test func shellCommandIsPrivilegedByDefaultWithQuotedSortedEnv() {
        let step = Provisioner(type: .shell, inline: "true", env: ["B": "two words", "A": "it's"])
        #expect(step.shellCommand(running: "/tmp/s.sh")
            == #"sudo -n -H env 'A=it'\''s' 'B=two words' /bin/bash -l '/tmp/s.sh'"#)
        let unprivileged = Provisioner(type: .shell, inline: "true", privileged: false)
        #expect(unprivileged.shellCommand(running: "/tmp/s.sh") == "env /bin/bash -l '/tmp/s.sh'")
    }

    @Test(arguments: ["", "A=B", "-i", "1X", "MY VAR"])
    func envKeysMustBeVariableNames(key: String) {
        let step = Provisioner(type: .shell, inline: "true", env: [key: "v"])
        #expect(step.problem == "env key \"\(key)\" is not a variable name")
    }

    @Test func emptyPathsAreRejected() {
        let reason = "path, source and destination can't be empty"
        #expect(Provisioner(type: .shell, path: "").problem == reason)
        #expect(Provisioner(type: .file, source: "", destination: "/c").problem == reason)
        #expect(Provisioner(type: .file, source: "b", destination: "").problem == reason)
    }

    @Test func wellFormedEnvKeysPass() {
        #expect(Provisioner(type: .shell, inline: "true", env: ["_A1": "v", "b": "w"]).problem == nil)
    }

    @Test func hostFileIsThePathOrSourceTheStepReads() {
        #expect(Provisioner(type: .shell, path: "a.sh").hostFile == "a.sh")
        #expect(Provisioner(type: .shell, inline: "true").hostFile == nil)
        #expect(Provisioner(type: .file, source: "b", destination: "/c").hostFile == "b")
    }
}
