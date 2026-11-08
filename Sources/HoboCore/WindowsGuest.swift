import Foundation

/// The commands Hobo sends a Windows guest over SSH, where the shell is PowerShell. Each is one line
/// with no double quotes, which sshd would have to escape on its way to PowerShell. The scripts it
/// names were installed by create (`Sources/HoboVM/Resources/Windows`).
public enum WindowsGuest {
    public static let scriptsDirectory = #"C:\ProgramData\Hobo"#
    /// A guest path scp accepts, for files a create or provision step uploads.
    public static let temporaryDirectory = "C:/Windows/Temp"

    public static let shutdownCommand = "shutdown.exe /s /t 0"
    public static let versionCommand = "$o = Get-CimInstance Win32_OperatingSystem; $o.Caption + ' (' + $o.BuildNumber + ')'"
    /// `Update-HostStorageCache` first: Windows may not have noticed the disk grew. A partition
    /// already filling the disk is left alone, so that repeating this is safe.
    public static let growDiskCommand = """
        $ErrorActionPreference = 'Stop'; Update-HostStorageCache; $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax; \
        if ((Get-Partition -DriveLetter C).Size -lt $max) { Resize-Partition -DriveLetter C -Size $max }
        """
    /// Drops what the build left, then hands the freed blocks back to the ASIF.
    public static let cleanupCommand = """
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue C:\\Windows\\Temp\\*, $env:TEMP\\*, $env:ProgramData\\Hobo\\gui\\*; \
        Optimize-Volume -DriveLetter C -ReTrim
        """

    /// Starts `exec.ps1`, which prints `marker` and its process ID (`GuestSSH.PIDMarker`), then runs `command`.
    public static func execLine(_ command: [String], marker: String) -> String {
        script("exec.ps1", marker, encoded(command))
    }

    /// `execLine` in the desktop session, through `gui-exec.ps1`.
    public static func guiExecLine(_ command: [String], marker: String) -> String {
        script("gui-exec.ps1", marker, encoded(command))
    }

    public static func cancelCommand(pid: Int32) -> String {
        script("cancel.ps1", String(pid))
    }

    /// Sets the clock to `date`. PowerShell turns the UTC time into local time itself.
    public static func setClockCommand(_ date: Date) -> String {
        "Set-Date -Date ([DateTime]::new(\(ticks(date)), [DateTimeKind]::Utc).ToLocalTime()) | Out-Null"
    }

    /// The command line for `set-display.ps1`, run in the desktop session.
    public static func setDisplayCommand(width: Int, height: Int) -> [String] {
        ["powershell.exe", "-NoProfile", "-File", "\(scriptsDirectory)\\set-display.ps1", String(width), String(height)]
    }

    public static let screenshotCommand = ["powershell.exe", "-NoProfile", "-File", "\(scriptsDirectory)\\screenshot.ps1"]

    /// A guest computer name for the VM: Windows allows 15 characters, of letters, digits and
    /// hyphens, and not all of them digits. Its host-side name stays what it was.
    public static func computerName(for vmName: String) -> String {
        let mapped = String(vmName.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }).prefix(15)
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if trimmed.isEmpty { return "hobo" }
        return trimmed.allSatisfy(\.isNumber) ? "hobo-\(trimmed.prefix(10))" : trimmed
    }

    /// A shell step's script as Windows PowerShell must receive it, or nil to send the file as it is.
    /// PowerShell reads a script with no byte order mark in the system's code page, which mangles
    /// UTF-8, so one that is valid UTF-8 gets a mark. One marked UTF-16, or in some other encoding, is
    /// what its author chose and goes unchanged.
    public static func powerShellScript(_ file: Data) -> String? {
        if file.starts(with: [0xFF, 0xFE]) || file.starts(with: [0xFE, 0xFF]) { return nil }
        let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = file.starts(with: mark) ? file.dropFirst(mark.count) : file
        return String(data: Data(body), encoding: .utf8).map(powerShellScript)
    }

    /// `powerShellScript(_:)` for text Hobo already has as a string.
    public static func powerShellScript(_ text: String) -> String { "\u{FEFF}" + text }

    /// A command as `common.ps1` reads it: base64 of a JSON array, needing no quoting on the way.
    static func encoded(_ command: [String]) -> String {
        // An array of strings always encodes.
        (try! JSONEncoder().encode(command)).base64EncodedString()
    }

    /// `exit`, since `powershell -c` otherwise turns the script's exit status into 0 or 1.
    private static func script(_ name: String, _ arguments: String...) -> String {
        "& '\(scriptsDirectory)\\\(name)' " + arguments.map { "'\($0)'" }.joined(separator: " ") + "; exit $LASTEXITCODE"
    }

    /// .NET ticks: 100 ns since 0001-01-01 UTC, which is 62135596800 seconds before the Unix epoch.
    private static func ticks(_ date: Date) -> Int64 {
        (Int64(date.timeIntervalSince1970) + 62_135_596_800) * 10_000_000
    }
}
