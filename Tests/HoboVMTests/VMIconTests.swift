import AppKit
import HoboVM
import Testing

@MainActor struct VMIconTests {
    /// The bytes compiled into the binary decode to an icon big enough for ⌘Tab.
    @Test func iconDraws() throws {
        let image = try #require(VMIcon.image(for: "ubuntu2604"))
        let bitmap = try #require(image.representations.first)
        #expect(bitmap.pixelsWide == 1024)
        #expect(bitmap.pixelsHigh == 1024)
    }

    /// The tile fills the canvas up to its margin and rounded corners, which stay see-through.
    @Test func iconIsARoundedTile() throws {
        let raster = try Raster(try #require(VMIcon.image(for: "ubuntu2604")))
        #expect(raster.pixel(x: 0, y: 0)[3] == 0)
        #expect(raster.pixel(x: 70, y: 70)[3] == 0)
        #expect(raster.pixel(x: 70, y: 512)[3] == 255)
    }

    /// A VM's icon never changes, which rules out unseeded chalk grain.
    @Test func iconIsTheSameEveryTime() throws {
        let first = try Raster(try #require(VMIcon.image(for: "ubuntu2604")))
        let second = try Raster(try #require(VMIcon.image(for: "ubuntu2604")))
        #expect(first.rows(fromBottom: 0..<1024) == second.rows(fromBottom: 0..<1024))
    }

    @Test func everyColorDrawsItsOwnTile() throws {
        var tiles = Set<[UInt8]>()
        for color in 0..<VMIcon.colorCount {
            let name = try #require((0..<500).lazy.map { "vm-\($0)" }.first { VMIcon.assignment(for: $0).color == color })
            let raster = try Raster(try #require(VMIcon.image(for: name)))
            tiles.insert(raster.pixel(x: 70, y: 512))
        }
        #expect(tiles.count == VMIcon.colorCount)
    }

    /// Two names with one sign and color differ only in the band under the sign, where the name goes.
    @Test func nameIsDrawnUnderTheSign() throws {
        var seen: [String: String] = [:]
        var pair: (String, String)?
        for index in 0..<500 where pair == nil {
            let name = "vm-\(index)"
            let assignment = VMIcon.assignment(for: name)
            let key = "\(assignment.sign)/\(assignment.color)"
            if let earlier = seen[key] { pair = (earlier, name) }
            seen[key] = name
        }
        let (firstName, secondName) = try #require(pair)
        let first = try Raster(try #require(VMIcon.image(for: firstName)))
        let second = try Raster(try #require(VMIcon.image(for: secondName)))
        #expect(first.rows(fromBottom: 64..<220) != second.rows(fromBottom: 64..<220))
        #expect(first.rows(fromBottom: 230..<1024) == second.rows(fromBottom: 230..<1024))
    }

    /// A sign can decode and still draw nothing, so look for its chalk.
    @Test func everySignDrawsChalk() throws {
        for index in 0..<VMIcon.signCount {
            let raster = try Raster(try #require(VMIcon.signImage(at: index), "sign \(index)"))
            #expect(raster.hasVisiblePixel, "sign \(index)")
        }
    }

    /// Pinned: a VM's icon mustn't vary between processes, as `Hasher` would.
    @Test func assignmentIsStable() {
        let assignment = VMIcon.assignment(for: "ubuntu2604")
        #expect(assignment.sign == 7)
        #expect(assignment.color == 6)
    }

    @Test func assignmentStaysInRange() {
        for index in 0..<500 {
            let assignment = VMIcon.assignment(for: "vm-\(index)")
            #expect((0..<VMIcon.signCount).contains(assignment.sign))
            #expect((0..<VMIcon.colorCount).contains(assignment.color))
        }
    }

    @Test func shortNameIsKeptWhole() {
        let fitted = VMIcon.fittedName("nsa")
        #expect(fitted.text == "nsa")
        #expect(fitted.pointSize == 112)
    }

    @Test func mediumNameShrinksBeforeLosingAnything() {
        let fitted = VMIcon.fittedName("ubuntu2604-a3f1")
        #expect(fitted.text == "ubuntu2604-a3f1")
        #expect(fitted.pointSize < 112)
    }

    /// Clones of one source differ only in their last characters, which must survive.
    @Test func longNameKeepsItsCloneSuffix() {
        let fitted = VMIcon.fittedName("hobo-code-review-with-a-long-name-a3f1")
        let first = fitted.text
        let second = VMIcon.fittedName("hobo-code-review-with-a-long-name-7c02").text
        #expect(fitted.pointSize == 86)
        #expect(first.hasPrefix("hobo"))
        #expect(first.contains("…"))
        #expect(first.hasSuffix("-a3f1"))
        #expect(second.hasSuffix("-7c02"))
    }

    /// The longest name a VM can have is shortened, but keeps some of its start.
    @Test func longestNameKeepsSomeOfItsStart() {
        let name = String(repeating: "W", count: 63)
        let fitted = VMIcon.fittedName(name)
        #expect(fitted.text.hasPrefix("W"))
        // Without this, the suffix-only fallback would pass too: it also starts with a W.
        #expect(fitted.text.contains("…"))
        #expect(fitted.text.count < name.count)
    }
}

/// An icon's pixels, addressed from the bottom left as `VMIcon` draws them.
private struct Raster {
    let bitmap: NSBitmapImageRep

    init(_ image: NSImage) throws {
        bitmap = try #require(image.representations.first as? NSBitmapImageRep)
    }

    private var bytes: UnsafeMutablePointer<UInt8> { bitmap.bitmapData! }

    /// Red, green, blue and alpha, each 0-255.
    func pixel(x: Int, y: Int) -> [UInt8] {
        let start = (bitmap.pixelsHigh - 1 - y) * bitmap.bytesPerRow + x * 4
        return (0..<4).map { bytes[start + $0] }
    }

    func rows(fromBottom range: Range<Int>) -> Data {
        let start = (bitmap.pixelsHigh - range.upperBound) * bitmap.bytesPerRow
        return Data(bytes: bytes + start, count: range.count * bitmap.bytesPerRow)
    }

    var hasVisiblePixel: Bool {
        let count = bitmap.pixelsHigh * bitmap.bytesPerRow
        return stride(from: 3, to: count, by: 4).contains { bytes[$0] > 128 }
    }
}
