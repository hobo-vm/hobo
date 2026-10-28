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

    @Test(arguments: ["8", "eight GB", "GB", "-1GB"])
    func invalidSizesAreRejected(text: String) {
        #expect(throws: BoxcarError.invalidSize(text)) { try ByteSize(parsing: text) }
    }
}
