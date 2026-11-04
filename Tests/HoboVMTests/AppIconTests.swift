import AppKit
import HoboVM
import Testing

@MainActor struct AppIconTests {
    /// The bytes compiled into the binary decode to an image big enough for the Dock.
    @Test func embeddedIconDecodes() throws {
        let image = try #require(AppIcon.image)
        let bitmap = try #require(image.representations.first)
        #expect(bitmap.pixelsWide == 512)
        #expect(bitmap.pixelsHigh == 512)
    }
}
