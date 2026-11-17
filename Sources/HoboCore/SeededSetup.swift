import Foundation

/// Unattended setup for a macOS guest older than 27, which ignores
/// `VZMacGuestProvisioningOptions` and would stay on Setup Assistant. Create writes it into the
/// installed guest's Data volume, mounted on the host before the first boot (`GuestDataVolume`):
/// the cookie that says Setup Assistant has run, and a LaunchDaemon that does at that boot what the
/// provisioning options do in a newer guest: the `Conventions` user, auto-login and Remote Login
/// (checked on macOS 15.6.1, 2026-11-17).
public enum SeededSetup {
    /// The first macOS whose guests take `VZMacGuestProvisioningOptions`.
    public static let firstMajorWithProvisioningOptions = 27

    public static func isNeeded(guestMajor: Int) -> Bool { guestMajor < firstMajorWithProvisioningOptions }

    static let setupDoneCookie = "private/var/db/.AppleSetupDone"
    static let daemonLabel = "com.hobo.setup"
    static let daemonPlist = "Library/LaunchDaemons/\(daemonLabel).plist"
    /// What the daemon's script writes, for when a seeded boot never answers.
    public static let log = "/var/log/hobo-setup.log"

    /// Empty files a macOS install leaves in `/etc` and nothing reads, any of which can lend the
    /// daemon its inode (`apply`).
    static let placeholders = ["private/etc/find.codes", "private/etc/kern_loader.conf", "private/etc/rmtab", "private/etc/hosts.equiv"]

    /// Seeds the never-booted guest Data volume mounted at `dataVolume`.
    ///
    /// launchd only loads a LaunchDaemon that root owns, and a file made through the host's mount
    /// belongs to nobody (uid 99), since the mount ignores ownership. Renaming a file keeps its
    /// owner, though, and so does writing into it. So the daemon's plist is one of the install's
    /// own root-owned `placeholders`, moved into `/Library/LaunchDaemons` and filled in; the script
    /// empties it and moves it back when it is done.
    public static func apply(dataVolume: URL) throws {
        let files = FileManager.default
        guard let placeholder = placeholders.first(where: { isUsablePlaceholder(dataVolume.appending(path: $0)) }) else {
            throw SeededSetupError.noPlaceholder
        }
        let plist = dataVolume.appending(path: daemonPlist)
        let daemon = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": daemonLabel,
                "ProgramArguments": ["/bin/sh", "-c", script(placeholder: "/" + placeholder)],
                "RunAtLoad": true,
            ] as [String: Any],
            format: .xml, options: 0
        )
        try files.moveItem(at: dataVolume.appending(path: placeholder), to: plist)
        // Through a handle, not `Data.write`, which may replace the file and with it the owner.
        let handle = try FileHandle(forWritingTo: plist)
        defer { try? handle.close() }
        try handle.write(contentsOf: daemon)
        guard files.createFile(atPath: dataVolume.appending(path: setupDoneCookie).path, contents: nil) else {
            throw SeededSetupError.cookieNotWritten
        }
    }

    /// An empty regular file only its owner can write, as launchd asks of a LaunchDaemon.
    private static func isUsablePlaceholder(_ file: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.size] as? Int == 0,
              let mode = attributes[.posixPermissions] as? Int
        else { return false }
        return mode & 0o022 == 0
    }

    /// The daemon's root script, run once at the first boot. Remote Login comes last, so SSH
    /// answering means the rest is done. The user is made in a loop because the daemon can start
    /// before the directory service answers. Auto-login is the two files System Settings writes
    /// (`sysadminctl -autologin` fails here, with SACSetAutoLoginPassword error 22), and loginwindow
    /// is usually up before them, so the login happens at the next boot. The Setup Assistant
    /// preferences keep its per-user panes (Apple Account, Siri, Screen Time…) from covering the
    /// desktop at that first login; the set was checked as a whole, not key by key.
    static func script(placeholder: String) -> String {
        let user = Conventions.username
        let seen = [
            "DidSeeCloudSetup", "DidSeeSiriSetup", "DidSeePrivacy", "DidSeeAppearanceSetup", "DidSeeScreenTime",
            "DidSeeApplePaySetup", "DidSeeTouchIDSetup", "DidSeeAccessibility", "DidSeeAppStore", "DidSeeTrueTone",
            "DidSeeActivationLock", "DidSeeLockdownMode", "DidSeeTermsOfAddress", "DidSeeIntelligence", "DidSeeSyncSetup",
            "DidSeeSyncSetup2", "DidSeeiCloudLoginForStorageServices", "SkipFirstLoginOptimization",
        ]
        let kcpassword = kcpassword(Conventions.password).map { String(format: "\\%03o", $0) }.joined()
        return """
            exec >> \(log) 2>&1
            set -x
            attempt=0
            until id \(user) >/dev/null 2>&1; do
              sysadminctl -addUser \(user) -fullName \(shellQuote(Conventions.fullName)) -password \(shellQuote(Conventions.password)) -admin
              attempt=$((attempt + 1))
              [ $attempt -ge 30 ] && break
              id \(user) >/dev/null 2>&1 || sleep 2
            done
            createhomedir -c -u \(user)
            printf '\(kcpassword)' > /etc/kcpassword
            chmod 600 /etc/kcpassword
            defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser \(user)
            prefs=/Users/\(user)/Library/Preferences/com.apple.SetupAssistant.plist
            for key in \(seen.joined(separator: " ")); do
              defaults write $prefs $key -bool true
            done
            defaults write $prefs LastSeenCloudProductVersion "$(sw_vers -productVersion)"
            defaults write $prefs LastSeenSiriProductVersion "$(sw_vers -productVersion)"
            defaults write $prefs LastSeenBuddyBuildVersion "$(sw_vers -buildVersion)"
            chown \(user):staff $prefs
            : > /\(daemonPlist)
            mv /\(daemonPlist) \(placeholder)
            launchctl enable system/com.openssh.sshd
            launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist

            """
    }

    /// `/etc/kcpassword` for `password`: what loginwindow logs `autoLoginUser` in with, the
    /// password XORed with a fixed key and zero-padded to a multiple of 12 bytes.
    static func kcpassword(_ password: String) -> [UInt8] {
        let key: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
        var bytes = Array(password.utf8)
        bytes += Array(repeating: 0, count: (12 - bytes.count % 12) % 12)
        return bytes.enumerated().map { $1 ^ key[$0 % key.count] }
    }
}

public enum SeededSetupError: Error, Equatable, CustomStringConvertible {
    case noPlaceholder
    case cookieNotWritten

    public var description: String {
        switch self {
        case .noPlaceholder:
            "the installed macOS has none of the empty /etc files (\(SeededSetup.placeholders.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", "))) its first-boot setup is installed through"
        case .cookieNotWritten: "could not write /var/db/.AppleSetupDone into the guest"
        }
    }
}
