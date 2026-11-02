import Foundation
import Testing
@testable import HoboCore

@Suite struct UbuntuCatalogTests {
    static let sha = String(repeating: "CD", count: 32)

    /// One simplestreams product with its releases' `disk1.img` items.
    static func product(
        _ version: String, codename: String, title: String, supported: Bool, arch: String = "arm64", serials: [String]
    ) -> String {
        let releases = serials.map { serial in
            """
            "\(serial)": {"label": "release", "items": {
              "disk1.img": {"ftype": "disk1.img", "path": "server/releases/\(codename.lowercased())/release-\(serial)/ubuntu-\(version)-server-cloudimg-\(arch).img",
                            "sha256": "\(sha)", "size": 940373504},
              "manifest": {"ftype": "manifest", "path": "x.manifest", "sha256": "\(sha)", "size": 1}}}
            """
        }
        return """
        "com.ubuntu.cloud:server:\(version):\(arch)": {
          "arch": "\(arch)", "os": "ubuntu", "version": "\(version)", "release": "\(codename.lowercased())",
          "release_title": "\(title)", "release_codename": "\(codename) Animal", "supported": \(supported),
          "support_eol": "2031-05-29", "versions": {\(releases.joined(separator: ","))}}
        """
    }

    static var fixture: Data {
        let products = [
            product("24.04", codename: "Noble", title: "24.04 LTS", supported: true, serials: ["20261017", "20260901"]),
            product("26.10", codename: "Stonking", title: "26.10", supported: true, serials: ["20261025"]),
            product("26.04", codename: "Resolute", title: "26.04 LTS", supported: true, serials: ["20261016", "20261101"]),
            product("23.10", codename: "Mantic", title: "23.10", supported: false, serials: ["20240701"]),
            product("26.04", codename: "Resolute", title: "26.04 LTS", supported: true, arch: "amd64", serials: ["20261016"]),
            // Incomplete products and releases are skipped, not fatal.
            #""com.ubuntu.cloud:server:99.04:arm64": {"arch": "arm64"}"#,
            #""com.ubuntu.cloud:server:25.04:arm64": {"arch": "arm64", "os": "ubuntu", "version": "25.04", "release_title": "25.04", "versions": {"20250101": {"items": {}}}}"#,
        ]
        return Data(#"{"format": "products:1.0", "products": {\#(products.joined(separator: ","))}}"#.utf8)
    }

    var images: [UbuntuCatalog.Image] { get throws { try UbuntuCatalog.decode(Self.fixture) } }

    @Test func decodesArm64NewestFirst() throws {
        let images = try images
        #expect(images.map { "\($0.version)/\($0.serial)" } == [
            "26.10/20261025", "26.04/20261101", "26.04/20261016", "24.04/20261017", "24.04/20260901", "23.10/20240701",
        ])
        let image = images[1]
        #expect(image.name == "Ubuntu 26.04 LTS" && image.lts)
        #expect(image.codename == "Resolute Animal")
        #expect(image.url.absoluteString
            == "https://cloud-images.ubuntu.com/server/releases/resolute/release-20261101/ubuntu-26.04-server-cloudimg-arm64.img")
        #expect(image.sha256 == Self.sha.lowercased())
        #expect(image.size == 940_373_504)
        #expect(image.supportEnds == UbuntuCatalog.day("2031-05-29"))
        #expect(images[0].name == "Ubuntu 26.10" && !images[0].lts)
    }

    @Test func filtersToSupportedAndNewestPerSeries() throws {
        let images = UbuntuCatalog.latestPerSeries(UbuntuCatalog.supported(try images))
        #expect(images.map { "\($0.version)/\($0.serial)" } == ["26.10/20261025", "26.04/20261101", "24.04/20261017"])
    }

    @Test func looksUpVersionsAndTheNewestLTS() throws {
        let images = try images
        #expect(try UbuntuCatalog.image(version: "24.04", in: images).serial == "20261017")
        #expect(try UbuntuCatalog.image(version: "23.10", in: images).supported == false)
        #expect(throws: UbuntuCatalogError.unknownVersion("20.04")) { try UbuntuCatalog.image(version: "20.04", in: images) }
        #expect(try UbuntuCatalog.newestLTS(in: images).version == "26.04")
        #expect(throws: UbuntuCatalogError.noLTS) { try UbuntuCatalog.newestLTS(in: images.filter { !$0.lts }) }
    }

    /// `hobo init --os linux` must not pin an LTS whose support has ended, even the newest one.
    @Test func newestLTSSkipsAnUnsupportedSeries() throws {
        let images = try images.map { image in
            var image = image
            if image.version == "26.04" { image.supported = false }
            return image
        }
        #expect(try UbuntuCatalog.newestLTS(in: images).version == "24.04")
    }

    @Test func sourceLinesPinTheImage() throws {
        let image = try UbuntuCatalog.newestLTS(in: try images)
        let recipe = try Recipe.parse("[source]\n" + image.sourceLines, directory: URL(filePath: "/"))
        #expect(recipe.os == .linux)
        #expect(recipe.source == .remote(image.url, sha256: image.sha256))
    }

    @Test func unreadableIndexesAreReported() throws {
        #expect(throws: UbuntuCatalogError.self) { try UbuntuCatalog.decode(Data("[]".utf8)) }
        let broken = Data(#"{"products": {"a": {"arch": "arm64", "os": "ubuntu", "version": "1", "release_title": "1", "versions": {"1": {}}}}}"#.utf8)
        #expect(throws: UbuntuCatalogError.unreadable("none of its 1 arm64 products has a complete disk image")) {
            try UbuntuCatalog.decode(broken)
        }
        #expect(try UbuntuCatalog.decode(Data(#"{"products": {}}"#.utf8)).isEmpty)
    }
}
