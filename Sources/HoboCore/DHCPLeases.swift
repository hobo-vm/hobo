import Foundation

/// The host's vmnet DHCP leases (`/var/db/dhcpd_leases`), used to find a NAT guest's IP by MAC.
public enum DHCPLeases {
    public static let defaultPath = "/var/db/dhcpd_leases"

    public struct Lease: Equatable, Sendable {
        public var ipAddress: String
        public var hardwareAddress: String
    }

    /// Leases in file order. `hw_address=1,a:b:c:d:e:f` drops leading zeros, so addresses are
    /// normalised to two lowercase hex digits per octet.
    public static func parse(_ text: String) -> [Lease] {
        var leases: [Lease] = []
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "{" {
                fields = [:]
            } else if trimmed == "}" {
                if let ip = fields["ip_address"], let hw = fields["hw_address"],
                   let mac = normalize(String(hw.split(separator: ",").last ?? "")) {
                    leases.append(Lease(ipAddress: ip, hardwareAddress: mac))
                }
            } else if let eq = trimmed.firstIndex(of: "=") {
                fields[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
            }
        }
        return leases
    }

    /// The IP leased to `mac`. Each VM keeps its own MAC, so at most one lease matches.
    public static func ipAddress(forMAC mac: String, in text: String) -> String? {
        guard let wanted = normalize(mac) else { return nil }
        return parse(text).first { $0.hardwareAddress == wanted }?.ipAddress
    }

    public static func ipAddress(forMAC mac: String, path: String = defaultPath) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return ipAddress(forMAC: mac, in: text)
    }

    static func normalize(_ mac: String) -> String? {
        let octets = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard octets.count == 6 else { return nil }
        return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
