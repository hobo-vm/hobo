#!/usr/bin/env swift
// Regenerates every derived logo file from the SVGs in this directory, using only macOS:
//
//     swift assets/render.swift
//
// icon.svg is the master and icon-small.svg the simplified drawing for 16-32 px. The output is
// Hobo.icns, the two README headers, and the PNG compiled into HoboVM for the Dock. The renderer
// is NSImage's SVG support, which has no blur filter, so the drawings don't use one.
import AppKit

let assets = URL(filePath: #filePath).deletingLastPathComponent()
let master = assets.appending(path: "icon.svg")
let small = assets.appending(path: "icon-small.svg")

func renderPNG(svg: URL, width: Int, height: Int, to output: URL) throws {
    guard let image = NSImage(contentsOf: svg) else { throw CocoaError(.fileReadCorruptFile) }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.coderInvalidValue) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
    }
    try png.write(to: output)
}

/// The icon and the name side by side. The letters are round-capped strokes rather than type, so
/// no font is involved anywhere.
func header(icon: String, ink: String) throws -> String {
    let inner = try Regex("<svg[^>]*>|</svg>|<title>[^<]*</title>")
    let body = icon.replacing(inner, with: "")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1360 400" width="340" height="100">
      <title>Hobo</title>
      <g transform="translate(-30 -30) scale(0.4492)">\(body)</g>
      <g transform="translate(450 2)" fill="none" stroke="\(ink)" stroke-width="44" stroke-linecap="round" stroke-linejoin="round">
        <path d="M 22 90 V 330 M 182 90 V 330 M 22 210 H 182"/>
        <circle cx="336" cy="255" r="78"/>
        <path d="M 486 90 V 255"/>
        <circle cx="564" cy="255" r="78"/>
        <circle cx="792" cy="255" r="78"/>
      </g>
    </svg>

    """
}

let fileManager = FileManager.default
let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--preview", let directory = arguments.dropFirst().first {
    // Renders each drawing at every size to a directory, without touching the committed files.
    let out = URL(filePath: directory)
    for size in [32, 48, 64, 128, 256, 512, 1024] {
        try renderPNG(svg: master, width: size, height: size, to: out.appending(path: "icon-\(size).png"))
    }
    for size in [16, 24, 32, 48] {
        try renderPNG(svg: small, width: size, height: size, to: out.appending(path: "icon-small-\(size).png"))
    }
    for name in ["logo-light", "logo-dark"] {
        try renderPNG(svg: assets.appending(path: "\(name).svg"), width: 1360, height: 400, to: out.appending(path: "\(name).png"))
    }
    exit(0)
}

let icon = try String(contentsOf: master, encoding: .utf8)
try header(icon: icon, ink: "#3B2A1A").write(to: assets.appending(path: "logo-light.svg"), atomically: true, encoding: .utf8)
try header(icon: icon, ink: "#F3E7D0").write(to: assets.appending(path: "logo-dark.svg"), atomically: true, encoding: .utf8)

let dock = assets.deletingLastPathComponent().appending(path: "Sources/HoboVM/Resources/AppIcon.png")
try fileManager.createDirectory(at: dock.deletingLastPathComponent(), withIntermediateDirectories: true)
try renderPNG(svg: master, width: 512, height: 512, to: dock)

let temporary = fileManager.temporaryDirectory.appending(path: "Hobo-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporary) }
let slots: [(name: String, pixels: Int, svg: URL)] = [
    ("icon_16x16", 16, small), ("icon_16x16@2x", 32, small),
    ("icon_32x32", 32, small), ("icon_32x32@2x", 64, master),
    ("icon_128x128", 128, master), ("icon_128x128@2x", 256, master),
    ("icon_256x256", 256, master), ("icon_256x256@2x", 512, master),
    ("icon_512x512", 512, master), ("icon_512x512@2x", 1024, master),
]
for slot in slots {
    try renderPNG(svg: slot.svg, width: slot.pixels, height: slot.pixels, to: temporary.appending(path: "\(slot.name).png"))
}
let iconutil = try Process.run(
    URL(filePath: "/usr/bin/iconutil"),
    arguments: ["-c", "icns", temporary.path, "-o", assets.appending(path: "Hobo.icns").path]
)
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 { exit(iconutil.terminationStatus) }
