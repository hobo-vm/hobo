import Foundation
import Testing
@testable import HoboCore

@Suite struct CloudInitTests {
    let seed = CloudInit.seed(vmName: "dev", uid: 502, agent: Data("agent".utf8))

    @Test func seedHasTheNoCloudFiles() {
        #expect(Set(seed.keys) == ["meta-data", "user-data", "network-config"])
        #expect(seed["meta-data"]?.contains("local-hostname: dev\n") == true)
        #expect(seed["meta-data"]?.contains(/instance-id: hobo-[0-9a-f-]{36}\n/) == true)
    }

    @Test func hostnameIsAValidLabel() {
        #expect(CloudInit.hostname(for: "dev") == "dev")
        #expect(CloudInit.hostname(for: "my_vm.2") == "my-vm-2")
        #expect(CloudInit.hostname(for: "build-") == "build")
        #expect(CloudInit.seed(vmName: "a_b", uid: 502, agent: Data())["meta-data"]?.contains("local-hostname: a-b\n") == true)
    }

    @Test func userDataAppliesTheGuestConventions() throws {
        let userData = try #require(seed["user-data"])
        #expect(userData.hasPrefix("#cloud-config\n"))
        #expect(userData.contains("  - name: hobo\n"))
        #expect(userData.contains("    sudo: \"ALL=(ALL) NOPASSWD:ALL\"\n"))
        #expect(userData.contains("    plain_text_passwd: hobo\n"))
        // The key is an item of ssh_authorized_keys, indented under it.
        #expect(userData.contains("    ssh_authorized_keys:\n      - \(Conventions.insecurePublicKey)\n"))
        #expect(userData.contains("APT::Periodic::Unattended-Upgrade \"0\";"))
        // A readable text console: the kernel's built-in Terminus font, which setupcon then keeps.
        #expect(userData.contains("console=hvc0 fbcon=font:TER10x18\""))
        #expect(userData.contains(#"'s/^FONTSIZE=.*/FONTSIZE="10x20"/'"#))
    }

    /// Shared files show with their host owner, so hobo takes the host user's uid; the fstab
    /// line mounts every share on every boot, after cloud-init is disabled.
    @Test func userDataMountsShares() throws {
        let userData = try #require(seed["user-data"])
        #expect(userData.contains("  - name: hobo\n    uid: 502\n"))
        #expect(userData.contains("  - path: /etc/fstab\n    append: true\n    content: |\n      hobo /mnt/hobo virtiofs defaults,nofail 0 0\n"))
        #expect(userData.contains("  - [mkdir, -p, /mnt/hobo]\n"))
    }

    /// bootpd records the client ID it is sent, and leases are found by MAC. The NIC is matched by
    /// driver, so a clone with a new MAC still gets a network.
    @Test func networkConfigMatchesTheDriverAndUsesTheMACAsDHCPIdentifier() throws {
        let config = try #require(seed["network-config"])
        #expect(config.contains("match:\n      driver: virtio_net\n"))
        #expect(!config.contains("macaddress"))
        #expect(config.contains("dhcp-identifier: mac"))
    }

    /// The stub goes in at create and starts at once, so the rest of create already runs through it.
    @Test func userDataInstallsTheAgentStub() throws {
        let userData = try #require(seed["user-data"])
        #expect(userData.contains("  - path: /usr/local/libexec/hobo-agent\n    permissions: '0755'\n    encoding: b64\n    content: YWdlbnQ=\n"))
        #expect(userData.contains("      ExecStart=/usr/local/libexec/hobo-agent stub\n      Restart=always\n"))
        #expect(userData.contains("  - [systemctl, enable, --now, hobo-agent.service]\n"))
    }

    @Test func cleanupDisablesCloudInitAndTrims() {
        #expect(CloudInit.cleanupScript.contains("touch /etc/cloud/cloud-init.disabled"))
        #expect(CloudInit.cleanupScript.contains("fstrim -a"))
    }
}
