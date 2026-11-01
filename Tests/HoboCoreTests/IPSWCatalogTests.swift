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
        ].map { firmware($0.0, $0.1, day: $0.2) }.joined(separator: ",")
        // Deliberately out of order, with a 28.x newer than the host and a two-digit minor.
        return Data("{\"name\": \"Apple Virtual Machine 1\", \"firmwares\": [\(firmwares)]}".utf8)
    }

    @Test func decodesNewestVersionFirst() throws {
        let images = try images
        #expect(images.map(\.build) == ["27A100", "26B123", "26A434", "26A428", "25H10", "25G83"])
        let image = images[1]
        #expect(image.name == "macOS 27 Golden Gate")
        #expect(image.version == "27.2" && image.major == 27)
        #expect(image.sha256 == String(repeating: "ab", count: 32))
        #expect(image.url.absoluteString == "https://updates.cdn-apple.com/x/UniversalMac_27.2_26B123_Restore.ipsw")
        #expect(image.size == 25_595_669_503)
        #expect(image.released == ISO8601DateFormatter().date(from: "2026-10-26T18:14:17Z"))
    }

    @Test func hidesGuestsNewerThanTheHost() throws {
        #expect(IPSWCatalog.runnable(try images, hostMajor: 27).map(\.major) == [27, 27, 27, 26, 26])
        #expect(IPSWCatalog.runnable(try images, hostMajor: 28).count == 6)
    }

    @Test func latestKeepsTheNewestOfEachMajor() throws {
        #expect(IPSWCatalog.latestPerMajor(try images).map(\.build) == ["27A100", "26B123", "25H10"])
    }

    @Test func findsBuildsIgnoringCase() throws {
        #expect(try IPSWCatalog.image(build: "26a434", in: images, hostMajor: 27).version == "27.0.1")
        #expect(throws: CatalogError.unknownBuild("26Z1")) { try IPSWCatalog.image(build: "26Z1", in: images, hostMajor: 27) }
        // Details for any build, runnable or not; pinning one needs the host to run it.
        #expect(try IPSWCatalog.image(build: "27A100", in: images).version == "28.0")
        #expect(throws: CatalogError.unknownBuild("26Z1")) { try IPSWCatalog.image(build: "26Z1", in: images) }
        #expect(throws: CatalogError.unsupportedBuild("27A100", version: "28.0", hostMajor: 27)) {
            try IPSWCatalog.image(build: "27A100", in: images, hostMajor: 27)
        }
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
