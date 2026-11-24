import CLIOutput
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import HoboCore

@Suite struct GuestScreenshotTests {
    let directory: URL
    let screenshot = GuestScreenshot(name: "dev", png: Data("png".utf8))
    /// 2027-01-15 08:00:07 UTC, in whatever zone the host is.
    let date = Date(timeIntervalSince1970: 1_800_000_007)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "hobo-shot-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    private var stamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    @Test func aDefaultNameNeverReplacesAnEarlierShot() throws {
        defer { cleanUp() }
        let first = try screenshot.save(to: nil, in: directory, date: date)
        let second = try GuestScreenshot(name: "dev", png: Data("two".utf8)).save(to: nil, in: directory, date: date)
        let third = try screenshot.save(to: nil, in: directory, date: date)
        #expect(first.lastPathComponent == "dev-\(stamp).png")
        #expect(second.lastPathComponent == "dev-\(stamp)-2.png")
        #expect(third.lastPathComponent == "dev-\(stamp)-3.png")
        #expect(try Data(contentsOf: first) == Data("png".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    @Test func aNamedPathIsRelativeToTheDirectoryAndReplaced() throws {
        defer { cleanUp() }
        let file = directory.appending(path: "shot.png")
        try Data("old".utf8).write(to: file)
        #expect(try screenshot.save(to: "shot.png", in: directory, date: date).path == file.path)
        #expect(try Data(contentsOf: file) == Data("png".utf8))
    }

    /// The path is printed for the caller to use, so it comes back without the `..`.
    @Test func anAbsolutePathIgnoresTheDirectory() throws {
        defer { cleanUp() }
        let file = directory.appending(path: "shot.png")
        let saved = try screenshot.save(to: directory.path + "/elsewhere/../shot.png", in: directory.appending(path: "unused"), date: date)
        #expect(saved.path == file.path)
        #expect(try Data(contentsOf: file) == Data("png".utf8))
    }

    @Test func aFailedWriteIsAnErrorRatherThanALoop() throws {
        defer { cleanUp() }
        let missing = directory.appending(path: "missing")
        #expect(throws: (any Error).self) { try screenshot.save(to: nil, in: missing, date: date) }
    }

    @Test func eachGuestOSCapturesWithItsOwnCommand() {
        #expect(GuestScreenshot.command(for: .windows) == WindowsGuest.screenshotCommand)
        #expect(GuestScreenshot.command(for: .macOS) == GuestScreenshot.macOSCommand)
        #expect(GuestScreenshot.command(for: .linux) == GuestScreenshot.linuxCommand)
    }

    /// A PNG of `width`×`height` whose pixel at (x, y) is grey level x + 16y, so a crop shows where
    /// it was cut from.
    private func gradient(width: Int, height: Int) throws -> Data {
        let pixels = (0..<height).flatMap { y in (0..<width).map { x in UInt8(x + 16 * y) } }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The grey levels of a PNG, row by row.
    private func levels(of png: Data) throws -> [[UInt8]] {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<image.height).map { Array(pixels[$0 * image.width..<($0 + 1) * image.width]) }
    }

    @Test func aCropKeepsTheRectangleMeasuredFromTheTopLeft() throws {
        let shot = GuestScreenshot(name: "dev", png: try gradient(width: 8, height: 6))
        let cropped = try shot.cropped(to: ScreenshotCrop(x: 2, y: 1, width: 3, height: 2))
        #expect(cropped.name == "dev")
        #expect(cropped.png.starts(with: GuestScreenshot.pngSignature))
        #expect(try levels(of: cropped.png) == [[18, 19, 20], [34, 35, 36]])
    }

    /// A window partly off the screen has a frame that reaches past it; the part on screen is kept.
    @Test func aCropReachingPastTheScreenKeepsWhatIsOnIt() throws {
        let shot = GuestScreenshot(name: "dev", png: try gradient(width: 8, height: 6))
        #expect(try levels(of: shot.cropped(to: ScreenshotCrop(x: -3, y: 4, width: 5, height: 10)).png) == [[64, 65], [80, 81]])
        #expect(throws: ScreenshotCropError.offScreen(ScreenshotCrop(x: 8, y: 0, width: 4, height: 4), width: 8, height: 6)) {
            try shot.cropped(to: ScreenshotCrop(x: 8, y: 0, width: 4, height: 4))
        }
        #expect(throws: ScreenshotCropError.unreadable) { try screenshot.cropped(to: ScreenshotCrop(x: 0, y: 0, width: 1, height: 1)) }
    }

    @Test(arguments: ["840,412,80,28", "840,412 80×28", "(840,412 80×28)", "840,412 80x28"])
    func aCropParsesFromFourNumbersOrASnapshotFrame(text: String) {
        #expect(ScreenshotCrop(text) == ScreenshotCrop(x: 840, y: 412, width: 80, height: 28))
    }

    @Test func aCropCanStartOffTheScreenButNotBeEmptyOrMalformed() {
        #expect(ScreenshotCrop("-40,-8,200,100") == ScreenshotCrop(x: -40, y: -8, width: 200, height: 100))
        #expect(ScreenshotCrop(x: 1, y: 2, width: 3, height: 4).description == "1,2,3,4")
        for text in ["", "1,2,3", "1,2,3,4,5", "1,2,0,4", "1,2,3,-4", "a,b,c,d", "1.5,2,3,4"] {
            #expect(ScreenshotCrop(text) == nil, "\(text)")
        }
    }

    @Test func resultShape() throws {
        let json = String(decoding: try CLIJSON.line(ScreenshotResult(name: "dev", path: "/tmp/a.png")), as: UTF8.self)
        #expect(json == #"{"name":"dev","path":"/tmp/a.png"}"#)
    }

    // The capture script, with the guest's tools stubbed by PATH. The integration test covers it on
    // a real guest, but only with the grant: its refusal would take a VM built without one.

    /// Runs the script with `osascript` answering `granted`. The stubbed `screencapture` notes the
    /// file it was given, returned as `tempFile`, then runs the `screencapture` argument, where
    /// `$last` is that file.
    private func capture(
        granted: String, screencapture: String = #"printf shot > "$last""#
    ) throws -> (status: Int32, stdout: Data, stderr: String, tempFile: String?) {
        let note = directory.appending(path: "captured")
        try stub("osascript", "echo \(granted)")
        try stub("screencapture", "for last; do :; done; printf %s \"$last\" > '\(note.path)'; \(screencapture)")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/\(GuestScreenshot.macOSCommand[0])")
        process.arguments = Array(GuestScreenshot.macOSCommand.dropFirst())
        process.environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, String(decoding: stderr, as: UTF8.self), try? String(contentsOf: note, encoding: .utf8))
    }

    private func stub(_ name: String, _ body: String) throws {
        let file = directory.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    @Test func theCaptureGoesToStdoutWithTheGrant() throws {
        defer { cleanUp() }
        let result = try capture(granted: "true")
        #expect(result.status == 0)
        #expect(result.stdout == Data("shot".utf8))
        #expect(result.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(result.tempFile)))
    }

    /// Exiting 0 with no output would blame the capture for coming back empty, not for failing.
    @Test func aFailedCaptureKeepsItsStatusAndLeavesNothing() throws {
        defer { cleanUp() }
        let result = try capture(granted: "true", screencapture: "exit 3")
        #expect(result.status == 3)
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(result.tempFile)))
    }

    /// A cancelled exec signals the script, which exits as a command killed by SIGTERM would.
    @Test func anInterruptedCaptureLeavesNothing() throws {
        defer { cleanUp() }
        let result = try capture(granted: "true", screencapture: "kill -TERM $PPID")
        #expect(result.status == 143)
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(result.tempFile)))
    }

    /// `screencapture` would succeed, leaving windows out.
    @Test func withoutTheGrantItFailsAndNeverCaptures() throws {
        defer { cleanUp() }
        let result = try capture(granted: "false")
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("[gui_testing]"))
        #expect(result.tempFile == nil)
    }
}
