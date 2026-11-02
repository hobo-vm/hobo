import Foundation

/// The Ubuntu Server cloud images a Linux VM can be built from: the arm64 `disk1.img` (qcow2) of
/// each release, from Canonical's simplestreams index. Each release ("serial", e.g. `20261016`) is a
/// dated rebuild of a series ("26.04") at a URL that never changes, listed with its SHA-256, so
/// `hobo init --os linux` can write a pinned source.
public enum UbuntuCatalog {
    public static let url = URL(string: "https://cloud-images.ubuntu.com/releases/streams/v1/com.ubuntu.cloud:released:download.json")!
    /// Item paths in the index are relative to this.
    static let mirror = URL(string: "https://cloud-images.ubuntu.com/")!

    public struct Image: Codable, Equatable, Sendable {
        /// e.g. `Ubuntu 26.04 LTS`.
        public var name: String
        /// The series, e.g. `26.04`.
        public var version: String
        /// e.g. `Resolute Raccoon`.
        public var codename: String
        public var lts: Bool
        /// The build date, e.g. `20261016`.
        public var serial: String
        public var url: URL
        public var sha256: String
        public var size: UInt64
        /// Whether Canonical still supports the series.
        public var supported: Bool
        /// When standard support for the series ends, if the index says.
        public var supportEnds: Date?

        /// The `[source]` lines that pin this image in a recipe.
        public var sourceLines: String {
            """
            # \(name) (\(codename)), release \(serial)
            image  = "\(url.absoluteString)"
            sha256 = "\(sha256)"
            """
        }
    }

    /// Fetches the catalog: every arm64 release, newest series first, newest serial first within one.
    public static func fetch() async throws -> [Image] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UbuntuCatalogError.httpStatus(http.statusCode)
        }
        return try decode(data)
    }

    /// Decodes a simplestreams `image-downloads` index. A product or release missing a field or a
    /// valid SHA-256 is skipped rather than hiding the rest; the index is unreadable only if it
    /// lists arm64 products and none of their releases decode.
    public static func decode(_ data: Data) throws -> [Image] {
        let index: RawIndex
        do {
            index = try JSONDecoder().decode(RawIndex.self, from: data)
        } catch {
            throw UbuntuCatalogError.unreadable(String(describing: error))
        }
        let products = index.products.values.compactMap(\.product).filter { $0.os == "ubuntu" && $0.arch == "arm64" }
        let images = products.flatMap { product in
            product.versions.compactMap { serial, release -> Image? in
                guard let disk = release.items?["disk1.img"], let path = disk.path, let size = disk.size,
                      let sha = disk.sha256?.lowercased(), sha.count == 64, sha.allSatisfy(\.isHexDigit),
                      let url = URL(string: path, relativeTo: mirror)?.absoluteURL
                else { return nil }
                let lts = product.releaseTitle.hasSuffix("LTS")
                return Image(
                    name: "Ubuntu \(product.version)\(lts ? " LTS" : "")", version: product.version,
                    codename: product.releaseCodename ?? product.release ?? "", lts: lts, serial: serial,
                    url: url, sha256: sha, size: size, supported: product.supported ?? false,
                    supportEnds: product.supportEOL.flatMap(day)
                )
            }
        }
        if images.isEmpty && !products.isEmpty {
            throw UbuntuCatalogError.unreadable("none of its \(products.count) arm64 products has a complete disk image")
        }
        return images.sorted { lhs, rhs in
            let (l, r) = (versionComponents(lhs.version), versionComponents(rhs.version))
            return l != r ? l.lexicographicallyPrecedes(r, by: >) : lhs.serial > rhs.serial
        }
    }

    /// The series Canonical still supports.
    public static func supported(_ images: [Image]) -> [Image] {
        images.filter(\.supported)
    }

    /// The newest release of each series, in the order given (newest first).
    public static func latestPerSeries(_ images: [Image]) -> [Image] {
        var seen = Set<String>()
        return images.filter { seen.insert($0.version).inserted }
    }

    /// The newest release of series `version` (e.g. `26.04`).
    public static func image(version: String, in images: [Image]) throws -> Image {
        guard let image = images.first(where: { $0.version == version }) else {
            throw UbuntuCatalogError.unknownVersion(version)
        }
        return image
    }

    /// The newest release of the newest supported LTS series: what `hobo init --os linux` pins.
    public static func newestLTS(in images: [Image]) throws -> Image {
        guard let image = images.first(where: { $0.lts && $0.supported }) else { throw UbuntuCatalogError.noLTS }
        return image
    }

    static func day(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601.year().month().day())
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    private struct RawIndex: Decodable {
        var products: [String: MaybeProduct]
    }

    private struct MaybeProduct: Decodable {
        var product: RawProduct?

        init(from decoder: Decoder) throws {
            product = try? RawProduct(from: decoder)
        }
    }

    private struct RawProduct: Decodable {
        var os: String
        var arch: String
        var version: String
        var release: String?
        var releaseTitle: String
        var releaseCodename: String?
        var supported: Bool?
        var supportEOL: String?
        var versions: [String: RawRelease]

        enum CodingKeys: String, CodingKey {
            case os, arch, version, release, versions, supported
            case releaseTitle = "release_title"
            case releaseCodename = "release_codename"
            case supportEOL = "support_eol"
        }
    }

    private struct RawRelease: Decodable {
        var items: [String: RawItem]?
    }

    private struct RawItem: Decodable {
        var path: String?
        var sha256: String?
        var size: UInt64?
    }
}

public enum UbuntuCatalogError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int)
    case unreadable(String)
    case unknownVersion(String)
    case unsupportedVersion(String)
    case noLTS

    public var description: String {
        switch self {
        case .httpStatus(let status): "the Ubuntu image catalog (\(UbuntuCatalog.url.absoluteString)) returned HTTP \(status)"
        case .unreadable(let reason): "could not read the Ubuntu image catalog: \(reason)"
        case .unknownVersion(let version): "no Ubuntu \(version) arm64 cloud image (run `hobo images --os linux` to list them)"
        case .unsupportedVersion(let version):
            "Ubuntu \(version) is no longer supported; run `hobo images --os linux` to list the supported releases"
        case .noLTS: "the Ubuntu image catalog lists no supported LTS release"
        }
    }
}
