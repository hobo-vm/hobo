import AppKit
import CryptoKit
import HoboCore

/// A VM's icon for the Dock and ⌘Tab: a hobo sign in chalk on a dark tile, with the VM's name under
/// it. The name picks the sign and the color, so a VM's icon never changes and needs no state.
public enum VMIcon {
    /// The signs' files in `Resources/Signs` (`Payloads`), drawn by `assets/draw_signs.py`. Changing
    /// this list or `tileColors` moves VMs to other icons, which costs nothing but familiarity.
    private static let signs = [
        "all-right", "barking-dog", "burned-house", "camp-here", "courthouse", "cursed-out", "defend-yourself",
        "doctor", "fresh-water", "good-for-a-handout", "good-road", "hit-the-road", "jail", "keep-quiet",
        "man-with-gun", "not-safe", "nothing-to-gain", "police", "rich", "road-spoiled", "thieves",
        "this-is-the-place", "this-way", "work-here",
    ].map { "\($0).svg" }
    private static let tileColors: [UInt32] = [
        0x3A4A5C, 0x7A2E2A, 0x2F5240, 0x22375E, 0x54305A, 0x86491F, 0x1F5558, 0x45413C,
    ]

    static var signCount: Int { signs.count }
    static var colorCount: Int { tileColors.count }

    // The icon's layout, in pixels of its 1024 px canvas. The tile is the size of a macOS app icon's
    // (824 px, with a 100 px margin), so it sits level with the icons beside it in the Dock and ⌘Tab.
    private static let canvas = 1024
    private static let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    private static let tileCornerRadius: CGFloat = 184
    private static let signFrame = NSRect(x: 199, y: 244, width: 626, height: 626)
    private static let nameCenterY: CGFloat = 183
    /// The width that clears the tile's rounded corners at the name's height.
    private static let nameMaxWidth: CGFloat = 662
    private static let namePointSizes: ClosedRange<CGFloat> = 79...103
    /// The characters a shortened name always keeps, so clones of one source stay distinct.
    private static let keptSuffixLength = VMStore.ephemeralSuffixLength
    private static let chalkFleckCount = 14000

    /// Which sign and color `name` gets. A SHA-256 rather than `Hasher`, which differs per process.
    static func assignment(for name: String) -> (sign: Int, color: Int) {
        let digest = Array(SHA256.hash(data: Data(name.utf8)))
        return (
            sign: (Int(digest[0]) << 8 | Int(digest[1])) % signs.count,
            color: (Int(digest[2]) << 8 | Int(digest[3])) % tileColors.count
        )
    }

    /// The largest size at which `name` fits; failing that, the smallest size with the name's middle
    /// cut, since clones differ only in their last characters.
    static func fittedName(_ name: String) -> (text: String, pointSize: CGFloat) {
        for pointSize in stride(from: namePointSizes.upperBound, through: namePointSizes.lowerBound, by: -2) {
            if nameWidth(name, pointSize: pointSize) <= nameMaxWidth { return (name, pointSize) }
        }
        let smallest = namePointSizes.lowerBound
        for headLength in stride(from: name.count - keptSuffixLength - 1, to: 0, by: -1) {
            let text = "\(name.prefix(headLength))…\(name.suffix(keptSuffixLength))"
            if nameWidth(text, pointSize: smallest) <= nameMaxWidth { return (text, smallest) }
        }
        return (String(name.suffix(keptSuffixLength)), smallest)
    }

    /// The icon for the VM called `name`, or nil if it can't be drawn, which leaves the default icon.
    @MainActor public static func image(for name: String) -> NSImage? {
        let (sign, color) = assignment(for: name)
        guard let chalk = signImage(at: sign), let bitmap = newBitmap() else { return nil }
        let tileColor = nsColor(tileColors[color])
        let shape = NSBezierPath(roundedRect: tile, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        drawing(in: bitmap) {
            NSGradient(
                starting: tileColor.blended(withFraction: 0.12, of: .white) ?? tileColor,
                ending: tileColor.blended(withFraction: 0.18, of: .black) ?? tileColor
            )?.draw(in: shape, angle: -90)
            chalk.draw(in: signFrame)
            let fitted = fittedName(name)
            let label = NSAttributedString(string: fitted.text, attributes: nameAttributes(pointSize: fitted.pointSize))
            let size = label.size()
            label.draw(at: NSPoint(x: tile.midX - size.width / 2, y: nameCenterY - size.height / 2))
        }
        return image(wrapping: bitmap)
    }

    /// One sign with chalk grain knocked out of it, or nil if its SVG is missing or doesn't decode.
    @MainActor static func signImage(at index: Int) -> NSImage? {
        guard let data = try? Payloads.sign(signs[index]), let svg = NSImage(data: data), svg.isValid, let bitmap = newBitmap() else { return nil }
        let bounds = NSRect(x: 0, y: 0, width: canvas, height: canvas)
        drawing(in: bitmap) {
            svg.draw(in: bounds)
            knockOutChalkGrain(in: bounds)
        }
        return image(wrapping: bitmap)
    }

    /// Erases small, partly transparent flecks from what's already drawn, so solid strokes look chalky.
    private static func knockOutChalkGrain(in bounds: NSRect) {
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        // A linear congruential generator with a fixed seed: a VM's icon is the same every time.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }
        for _ in 0..<chalkFleckCount {
            NSColor(white: 0, alpha: 0.25 + 0.5 * random()).setFill()
            let diameter = 1 + 3.5 * random()
            let x = random() * bounds.width, y = random() * bounds.height
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
        }
    }

    private static func nameWidth(_ text: String, pointSize: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: nameAttributes(pointSize: pointSize)).size().width
    }

    private static func nameAttributes(pointSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: pointSize, weight: .semibold), .foregroundColor: NSColor.white]
    }

    private static func nsColor(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1
        )
    }

    private static func newBitmap() -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
    }

    private static func drawing(in bitmap: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        body()
    }

    private static func image(wrapping bitmap: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.addRepresentation(bitmap)
        return image
    }
}
