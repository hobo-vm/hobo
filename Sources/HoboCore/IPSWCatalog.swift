import Foundation

/// The macOS IPSWs a VM can be built from, as listed by ipsw.me for `VirtualMac2,1` (the model a
/// Virtualization framework guest reports). Apple publishes only the newest IPSW; ipsw.me keeps
/// the history, with each file's SHA-256, so `hobo init <build>` can write a pinned source.
public enum IPSWCatalog {
    public static let url = URL(string: "https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw")!

    public struct Image: Codable, Hashable, Sendable {
        public var name: String
        public var version: String
        public var build: String
        public var url: URL
        public var sha256: String
        public var size: UInt64
        public var released: Date
        public var signed: Bool

        public var major: Int { IPSWCatalog.major(of: version) }

        /// The `[source]` lines that pin this image in a recipe.
        public var sourceLines: String {
            """
            # \(name) \(version) (\(build))
            ipsw   = "\(url.absoluteString)"
            sha256 = "\(sha256)"
            """
        }
    }

    /// Fetches the catalog, newest first.
    public static func fetch() async throws -> [Image] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CatalogError.httpStatus(http.statusCode)
        }
        return try decode(data)
    }

    /// Decodes an ipsw.me device response, newest version first. A record missing a field (as a
    /// just-uploaded build can be) or without a valid SHA-256 is skipped rather than hiding every
    /// other build; the response is unreadable only if it has records and none of them decode.
    public static func decode(_ data: Data) throws -> [Image] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let device: RawDevice
        do {
            device = try decoder.decode(RawDevice.self, from: data)
        } catch {
            throw CatalogError.unreadable(String(describing: error))
        }
        let firmwares = device.firmwares.compactMap(\.firmware)
        if firmwares.isEmpty && !device.firmwares.isEmpty {
            throw CatalogError.unreadable("none of its \(device.firmwares.count) firmware records are complete")
        }
        return firmwares.map { raw in
            Image(
                name: marketingName(major: major(of: raw.version)),
                version: raw.version, build: raw.buildid, url: raw.url, sha256: raw.sha256sum.lowercased(),
                size: raw.filesize, released: raw.releasedate, signed: raw.signed
            )
        }
        .sorted { lhs, rhs in
            let (l, r) = (versionComponents(lhs.version), versionComponents(rhs.version))
            return l != r ? l.lexicographicallyPrecedes(r, by: >) : lhs.released > rhs.released
        }
    }

    /// The oldest macOS a VM can be built from. A guest older than 27 ignores
    /// `VZMacGuestProvisioningOptions` and is set up by `SeededSetup` instead, which is checked
    /// back to this version.
    public static let minimumGuestMajor = 15

    /// The images a host on macOS `hostMajor` can build a VM from: a guest can't be newer than its
    /// host, nor older than `minimumGuestMajor`.
    public static func buildable(_ images: [Image], hostMajor: Int) -> [Image] {
        images.filter { $0.major >= minimumGuestMajor && $0.major <= hostMajor }
    }

    /// The newest image of each major version, in the order given (newest first).
    public static func latestPerMajor(_ images: [Image]) -> [Image] {
        var seen = Set<Int>()
        return images.filter { seen.insert($0.major).inserted }
    }

    /// The image with build number `build`, ignoring case.
    public static func image(build: String, in images: [Image]) throws -> Image {
        guard let image = images.first(where: { $0.build.caseInsensitiveCompare(build) == .orderedSame }) else {
            throw CatalogError.unknownBuild(build)
        }
        return image
    }

    /// The image with build number `build` (ignoring case), which a host on `hostMajor` must be
    /// able to build a VM from.
    public static func image(build: String, in images: [Image], hostMajor: Int) throws -> Image {
        let image = try image(build: build, in: images)
        if image.major < minimumGuestMajor { throw CatalogError.tooOldBuild(image.build, version: image.version) }
        if image.major > hostMajor {
            throw CatalogError.unsupportedBuild(image.build, version: image.version, hostMajor: hostMajor)
        }
        return image
    }

    public static var hostMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    static func marketingName(major: Int) -> String {
        switch major {
        case 27: "macOS 27 Golden Gate"
        case 26: "macOS Tahoe"
        case 15: "macOS Sequoia"
        case 14: "macOS Sonoma"
        case 13: "macOS Ventura"
        case 12: "macOS Monterey"
        default: "macOS \(major)"
        }
    }

    /// The major version of `version` ("26.1" is 26), or 0 if it doesn't start with a number.
    static func major(of version: String) -> Int {
        Int(version.prefix { $0 != "." }) ?? 0
    }

    private static func versionComponents(_ version: String) -> [Int] {
        // Padded so "27.0" and "27" compare equal rather than by length.
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }

    private struct RawDevice: Decodable {
        var firmwares: [MaybeFirmware]
    }

    private struct MaybeFirmware: Decodable {
        var firmware: RawFirmware?

        init(from decoder: Decoder) throws {
            let raw = try? RawFirmware(from: decoder)
            let sha = raw?.sha256sum ?? ""
            firmware = sha.count == 64 && sha.allSatisfy(\.isHexDigit) ? raw : nil
        }
    }

    private struct RawFirmware: Decodable {
        var version: String
        var buildid: String
        var url: URL
        var sha256sum: String
        var filesize: UInt64
        var releasedate: Date
        var signed: Bool
    }
}

public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int)
    case unreadable(String)
    case unknownBuild(String)
    case unsupportedBuild(String, version: String, hostMajor: Int)
    case tooOldBuild(String, version: String)

    public var description: String {
        switch self {
        case .httpStatus(let status): "the IPSW catalog (\(IPSWCatalog.url.absoluteString)) returned HTTP \(status)"
        case .unreadable(let reason): "could not read the IPSW catalog: \(reason)"
        case .unknownBuild(let build): "no macOS IPSW with build \(build) (run `hobo images` to list them)"
        case .unsupportedBuild(let build, let version, let hostMajor):
            "build \(build) is macOS \(version), newer than this host (macOS \(hostMajor)); run `hobo images` to list the ones it can run"
        case .tooOldBuild(let build, let version):
            "build \(build) is macOS \(version), and hobo builds VMs from macOS \(IPSWCatalog.minimumGuestMajor) or later (run `hobo images` to list them)"
        }
    }
}
