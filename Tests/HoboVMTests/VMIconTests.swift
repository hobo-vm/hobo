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

    @Test func everySignDecodes() {
        for index in 0..<VMIcon.signCount {
            #expect(VMIcon.signImage(at: index) != nil, "sign \(index)")
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
        let fitted = VMIcon.fittedName("hobo-code-1")
        #expect(fitted.text == "hobo-code-1")
    }

    /// Clones of one source differ only in their last characters, which must survive.
    @Test func longNameKeepsItsCloneSuffix() {
        let first = VMIcon.fittedName("hobo-code-review-with-a-long-name-a3f1").text
        let second = VMIcon.fittedName("hobo-code-review-with-a-long-name-7c02").text
        #expect(first.hasPrefix("hobo"))
        #expect(first.contains("…"))
        #expect(first.hasSuffix("-a3f1"))
        #expect(second.hasSuffix("-7c02"))
    }

    /// The longest name a VM can have still fits, with some of its start.
    @Test func longestNameFits() {
        let name = String(repeating: "W", count: 63)
        let fitted = VMIcon.fittedName(name)
        #expect(fitted.text.hasPrefix("W"))
        #expect(fitted.text.count < name.count)
    }
}
