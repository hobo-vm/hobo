import Foundation
import HoboCore

/// The New VM sheet: a name and what `hobo init` would ask for, plus the machine settings. It
/// becomes a `RecipeDraft`, written to a temporary directory for `create` to build from, which
/// keeps its own copy in the bundle (design decision 3).
public struct NewVMForm: Equatable, Sendable {
    public var name = ""
    public var os: VMConfig.OS = .macOS {
        didSet { if os != oldValue { resetMachine() } }
    }
    /// A macOS build from the catalog, or nil for "latest".
    public var macOSImage: IPSWCatalog.Image?
    public var linuxImage: UbuntuCatalog.Image?
    public var linuxDesktop = true
    /// A Windows on Arm installer the user picked, since there is no catalog.
    public var windowsISO: URL?
    public var cpus = Recipe.defaultCPUs
    public var memoryGB = 0
    public var diskGB = 0
    public var guiTesting = false

    public init() { resetMachine() }

    private mutating func resetMachine() {
        cpus = Recipe.defaultCPUs
        memoryGB = Int(Recipe.defaultMemory(for: os).bytes / SettingsForm.gigabyte)
        diskGB = Int(Recipe.defaultDisk(for: os).bytes / SettingsForm.gigabyte)
        if os != .macOS { guiTesting = false }
    }

    /// Why the form can't be submitted yet, or nil if it can.
    public var problem: String? {
        if name.isEmpty { return "Name the VM." }
        do { try VMStore.validate(name) } catch { return "\(error)" }
        switch os {
        case .macOS: return nil
        case .linux: return linuxImage == nil ? "Pick an Ubuntu version." : nil
        case .windows: return windowsISO == nil ? "Choose a Windows on Arm installer ISO." : nil
        }
    }

    /// The recipe to create from. A Windows ISO's SHA-256 is the caller's to compute (it reads the
    /// whole file), with `ImageIndex.hash`, as `hobo init --os windows` does.
    public func draft(windowsSHA256: String? = nil) throws -> RecipeDraft {
        if let problem { throw NewVMFormError(description: problem) }
        let source: RecipeDraft.Source = switch os {
        case .macOS: .macOS(macOSImage)
        case .linux: .linux(linuxImage!, desktop: linuxDesktop)
        case .windows: .windows(iso: windowsISO!.path, sha256: windowsSHA256 ?? "")
        }
        return RecipeDraft(
            source: source, cpus: cpus, memory: ByteSize(bytes: UInt64(memoryGB) * SettingsForm.gigabyte),
            disk: ByteSize(bytes: UInt64(diskGB) * SettingsForm.gigabyte), guiTesting: guiTesting && os == .macOS
        )
    }

    /// Writes `draft` as `Hobo.toml` in a new temporary directory and returns the file.
    public static func writeRecipe(_ draft: RecipeDraft) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Hobo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: Recipe.fileName)
        try draft.text().write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

public struct NewVMFormError: Error, CustomStringConvertible, Equatable {
    public var description: String
}
