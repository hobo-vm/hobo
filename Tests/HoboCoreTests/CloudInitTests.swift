import Foundation
import Testing
@testable import HoboCore

@Suite struct CloudInitTests {
    let seed = CloudInit.seed(hostname: "dev", macAddress: "AA:BB:CC:DD:EE:0F")

    @Test func seedHasTheNoCloudFiles() {
        #expect(Set(seed.keys) == ["meta-data", "user-data", "network-config"])
        #expect(seed["meta-data"]?.contains("local-hostname: dev\n") == true)
        #expect(seed["meta-data"]?.contains(/instance-id: hobo-[0-9a-f-]{36}\n/) == true)
    }

    @Test func userDataAppliesTheVagrantConventions() throws {
        let userData = try #require(seed["user-data"])
        #expect(userData.hasPrefix("#cloud-config\n"))
        #expect(userData.contains("  - name: vagrant\n"))
        #expect(userData.contains("    sudo: \"ALL=(ALL) NOPASSWD:ALL\"\n"))
        #expect(userData.contains("    plain_text_passwd: vagrant\n"))
        // Each key is an item of ssh_authorized_keys, indented under it.
        for key in Conventions.insecurePublicKeys {
            #expect(userData.contains("    ssh_authorized_keys:\n") && userData.contains("\n      - \(key)\n"))
        }
        #expect(userData.contains("APT::Periodic::Unattended-Upgrade \"0\";"))
    }

    /// bootpd records the client ID it is sent, and leases are found by MAC.
    @Test func networkConfigUsesTheMACAsDHCPIdentifier() throws {
        let config = try #require(seed["network-config"])
        #expect(config.contains("macaddress: \"aa:bb:cc:dd:ee:0f\""))
        #expect(config.contains("dhcp-identifier: mac"))
    }

    @Test func cleanupDisablesCloudInitAndTrims() {
        #expect(CloudInit.cleanupScript.contains("touch /etc/cloud/cloud-init.disabled"))
        #expect(CloudInit.cleanupScript.contains("fstrim -a"))
    }
}
