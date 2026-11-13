import Foundation
import Testing
@testable import HoboCore

@Suite struct RecipeDraftTests {
    static let sha = String(repeating: "ab", count: 32)
    static let ipsw = IPSWCatalog.Image(
        name: "macOS 27", version: "27.2", build: "26B123", url: URL(string: "https://updates.cdn-apple.com/x/UniversalMac_27.2_Restore.ipsw")!,
        sha256: sha, size: 1, released: Date(timeIntervalSince1970: 0), signed: true
    )
    static let ubuntu = UbuntuCatalog.Image(
        name: "Ubuntu 26.04 LTS", version: "26.04", codename: "Resolute Raccoon", lts: true, serial: "20261016",
        url: URL(string: "https://cloud-images.ubuntu.com/x/ubuntu-26.04-server-cloudimg-arm64.img")!, sha256: sha,
        size: 1, supported: true, supportEnds: nil
    )
    static let sources: [RecipeDraft.Source] = [
        .macOS(nil), .macOS(ipsw), .linux(ubuntu, desktop: true), .linux(ubuntu, desktop: false),
        .windows(iso: "/isos/win.iso", sha256: sha),
    ]

    /// Each OS's template parses, with that OS's default machine.
    @Test(arguments: sources)
    func eachSourceWritesItsTemplate(source: RecipeDraft.Source) throws {
        let recipe = try Recipe.parse(RecipeDraft(source: source).text(), directory: URL(filePath: "/recipes"))
        #expect(recipe.memory == Recipe.defaultMemory(for: recipe.os) && recipe.disk == Recipe.defaultDisk(for: recipe.os))
    }
}
