import Foundation
import Testing
@testable import HoboCore

@Suite struct IPSWCatalogTests {
    /// One ipsw.me firmware record, as in a `v4/device` response.
    static func firmware(_ version: String, _ build: String, day: String) -> String {
        """
        {"identifier": "VirtualMac2,1", "version": "\(version)", "buildid": "\(build)",
         "sha1sum": "\(String(repeating: "1", count: 40))", "sha256sum": "\(String(repeating: "AB", count: 32))",
         "filesize": 25595669503, "url": "https://updates.cdn-apple.com/x/UniversalMac_\(version)_\(build)_Restore.ipsw",
         "releasedate": "\(day)T18:14:17Z", "uploaddate": "\(day)T00:00:00Z", "signed": false}
        """
    }

    var images: [IPSWCatalog.Image] { get throws { try IPSWCatalog.decode(Self.fixture) } }

    static var fixture: Data {
        let firmwares = [
            ("26.6.2", "25G83", "2026-08-17"), ("27.0.1", "26A434", "2026-09-28"), ("28.0", "27A100", "2027-09-14"),
            ("27.2", "26B123", "2026-10-26"), ("26.10", "25H10", "2026-12-01"), ("27.0", "26A428", "2026-09-14"),
            ("14.8", "23J21", "2025-09-15"),
        ].map { firmware($0.0, $0.1, day: $0.2) }.joined(separator: ",")
        // Deliberately out of order, with a 28.x newer than the host, a two-digit minor, and a
        // 14.x older than hobo builds.
        return Data("{\"name\": \"Apple Virtual Machine 1\", \"firmwares\": [\(firmwares)]}".utf8)
    }

    @Test func decodesNewestVersionFirst() throws {
        let images = try images
        #expect(images.map(\.build) == ["27A100", "26B123", "26A434", "26A428", "25H10", "25G83", "23J21"])
        let image = images[1]
        #expect(image.name == "macOS 27 Golden Gate")
        #expect(image.version == "27.2" && image.major == 27)
        #expect(image.sha256 == String(repeating: "ab", count: 32))
        #expect(image.url.absoluteString == "https://updates.cdn-apple.com/x/UniversalMac_27.2_26B123_Restore.ipsw")
        #expect(image.size == 25_595_669_503)
        #expect(image.released == ISO8601DateFormatter().date(from: "2026-10-26T18:14:17Z"))
    }

    @Test func ordersEqualVersionsByReleaseDate() throws {
        // "27" and "27.0" are the same version; the later release (a re-spin) comes first.
        let firmwares = [Self.firmware("27", "26A1", day: "2026-09-01"), Self.firmware("27.0", "26A2", day: "2026-09-08")]
        let data = Data("{\"firmwares\": [\(firmwares.joined(separator: ","))]}".utf8)
        #expect(try IPSWCatalog.decode(data).map(\.build) == ["26A2", "26A1"])
    }

    @Test func jsonRoundTripsWithISO8601Dates() throws {
        let image = try images[1]
        let data = try HoboJSON.document(image)
        #expect(String(decoding: data, as: UTF8.self).contains(#""released" : "2026-10-26T18:14:17Z""#))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(IPSWCatalog.Image.self, from: data) == image)
        #expect(try decoder.decode([IPSWCatalog.Image].self, from: HoboJSON.document(images)) == images)
    }

    @Test func hidesGuestsNewerThanTheHostOrOlderThanHoboBuilds() throws {
        #expect(IPSWCatalog.buildable(try images, hostMajor: 27).map(\.major) == [27, 27, 27, 26, 26])
        #expect(IPSWCatalog.buildable(try images, hostMajor: 28).map(\.major) == [28, 27, 27, 27, 26, 26])
    }

    @Test func latestKeepsTheNewestOfEachMajor() throws {
        #expect(IPSWCatalog.latestPerMajor(try images).map(\.build) == ["27A100", "26B123", "25H10", "23J21"])
    }

    @Test func findsBuildsIgnoringCase() throws {
        #expect(try IPSWCatalog.image(build: "26a434", in: images, hostMajor: 27).version == "27.0.1")
        #expect(throws: CatalogError.unknownBuild("26Z1")) { try IPSWCatalog.image(build: "26Z1", in: images, hostMajor: 27) }
        // Details for any build, buildable or not; pinning one needs hobo to build a VM from it.
        #expect(try IPSWCatalog.image(build: "27A100", in: images).version == "28.0")
        #expect(throws: CatalogError.unknownBuild("26Z1")) { try IPSWCatalog.image(build: "26Z1", in: images) }
        #expect(throws: CatalogError.unsupportedBuild("27A100", version: "28.0", hostMajor: 27)) {
            try IPSWCatalog.image(build: "27A100", in: images, hostMajor: 27)
        }
        #expect(try IPSWCatalog.image(build: "25G83", in: images, hostMajor: 27).version == "26.6.2")
        #expect(try IPSWCatalog.image(build: "23J21", in: images).version == "14.8")
        #expect(throws: CatalogError.tooOldBuild("23J21", version: "14.8")) {
            try IPSWCatalog.image(build: "23J21", in: images, hostMajor: 27)
        }
    }

    @Test func skipsIncompleteRecords() throws {
        let good = Self.firmware("27.2", "26B123", day: "2026-10-26")
        let noSHA = Self.firmware("27.3", "26C1", day: "2026-11-01").replacingOccurrences(of: String(repeating: "AB", count: 32), with: "")
        let noDate = #"{"version": "27.3", "buildid": "26C2", "url": "https://x/y.ipsw", "sha256sum": "\#(String(repeating: "a", count: 64))", "filesize": 1, "releasedate": null, "signed": true}"#
        let data = Data("{\"firmwares\": [\(noSHA), \(good), \(noDate)]}".utf8)
        #expect(try IPSWCatalog.decode(data).map(\.build) == ["26B123"])
        #expect(try IPSWCatalog.decode(Data(#"{"firmwares": []}"#.utf8)).isEmpty)
    }

    @Test func rejectsAnUnexpectedResponse() {
        #expect(throws: CatalogError.self) { try IPSWCatalog.decode(Data(#"{"firmwares": [{"version": "27.2"}]}"#.utf8)) }
        #expect(throws: CatalogError.self) { try IPSWCatalog.decode(Data("<html>".utf8)) }
    }

    @Test func pinnedTemplateParsesToTheImage() throws {
        let image = try IPSWCatalog.image(build: "26B123", in: images, hostMajor: 27)
        let toml = Recipe.template(pinnedTo: image)
        #expect(toml.contains("# macOS 27 Golden Gate 27.2 (26B123)\nipsw   = "))
        let recipe = try Recipe.parse(toml, directory: URL(filePath: "/"))
        #expect(recipe.source == .remote(image.url, sha256: image.sha256))
        #expect(toml.replacingOccurrences(of: image.sourceLines, with: "") == Recipe.template.replacingOccurrences(of: templateLatestSource, with: ""))
    }

    private var templateLatestSource: String {
        let lines = Recipe.template.split(separator: "\n", omittingEmptySubsequences: false)
        let start = lines.firstIndex(of: "[source]")! + 1
        let end = lines.firstIndex(of: #"ipsw = "latest""#)!
        return lines[start...end].joined(separator: "\n")
    }
}
