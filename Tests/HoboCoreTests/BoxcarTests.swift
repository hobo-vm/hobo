import Testing
@testable import HoboCore

@Suite struct BoxcarTests {
    @Test func singleMachineUsesTopLevelKeys() throws {
        let boxcar = try Boxcar.parse("""
        box = "greg/ubuntu-24.04"
        memory = "2GB"
        """)
        #expect(boxcar.machines.map(\.name) == ["default"])
        #expect(boxcar.machines[0].settings.box == "greg/ubuntu-24.04")
        #expect(boxcar.machines[0].settings.memory == ByteSize(bytes: 2 << 30))
    }

    @Test func machinesKeepOrderAndInheritDefaults() throws {
        let boxcar = try Boxcar.parse("""
        [defaults]
        box = "greg/macos-27"
        cpus = 4

        [[machine]]
        name = "app"
        cpus = 8

          [[machine.forwarded_port]]
          guest = 8080
          host = 8080

          [[machine.provision]]
          type = "shell"
          inline = "xcodebuild -version"
          run = "once"

        [[machine]]
        name = "db"
        box = "greg/ubuntu-24.04"
        private_network = { ip = "10.42.0.11" }
        """)
        #expect(boxcar.machines.map(\.name) == ["app", "db"])

        let app = boxcar.resolved(boxcar.machines[0])
        #expect(app.box == "greg/macos-27")
        #expect(app.cpus == 8)
        #expect(app.forwardedPorts == [ForwardedPort(guest: 8080, host: 8080)])
        #expect(app.provisioners?.first?.run == .once)

        let db = boxcar.resolved(boxcar.machines[1])
        #expect(db.box == "greg/ubuntu-24.04")
        #expect(db.cpus == 4)
        #expect(db.privateNetwork?.ip == "10.42.0.11")
    }

    @Test func duplicateMachineNamesAreRejected() {
        #expect(throws: BoxcarError.duplicateMachine("app")) {
            try Boxcar.parse("""
            [[machine]]
            name = "app"
            [[machine]]
            name = "app"
            """)
        }
    }

    @Test func templateParses() throws {
        let boxcar = try Boxcar.parse(BoxcarTemplate.render(box: "greg/macos-27"))
        #expect(boxcar.machines[0].settings.disk == ByteSize(bytes: 80 << 30))
    }

    @Test(arguments: ["8", "eight GB", "GB", "-1GB", "99999999999TB"])
    func invalidSizesAreRejected(text: String) {
        #expect(throws: BoxcarError.invalidSize(text)) { try ByteSize(parsing: text) }
    }
}

@Suite struct ProvisionerTests {
    @Test func boxcarRejectsTheStepsARecipeRejects() {
        #expect(throws: BoxcarError.invalidProvisioner(scope: "machine \"app\"", index: 0, reason: "shell needs exactly one of inline or path")) {
            try Boxcar.parse("""
            [[machine]]
            name = "app"
              [[machine.provision]]
              type = "shell"
              inline = "true"
              path = "setup.sh"
            """)
        }
        #expect(throws: BoxcarError.invalidProvisioner(scope: "[defaults]", index: 0, reason: "file needs source and destination")) {
            try Boxcar.parse("""
            [defaults]
              [[defaults.provision]]
              type = "file"
              source = "x"
            """)
        }
    }

    @Test func invalidProvisionerNamesTheStepOneBased() {
        #expect(throws: BoxcarError.invalidProvisioner(scope: "machine \"app\"", index: 1, reason: "file needs source and destination")) {
            try Boxcar.parse("""
            [[machine]]
            name = "app"
              [[machine.provision]]
              type = "shell"
              inline = "true"
              [[machine.provision]]
              type = "file"
            """)
        }
        let error = BoxcarError.invalidProvisioner(scope: "machine \"app\"", index: 1, reason: "file needs source and destination")
        #expect(error.description == "machine \"app\" provision step 2: file needs source and destination")
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
