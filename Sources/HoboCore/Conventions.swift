import Foundation

/// The guest conventions applied to every macOS VM: `hobo`/`hobo`, passwordless sudo, the
/// insecure key, and no sleep or screensaver.
public enum Conventions {
    public static let username = "hobo"
    public static let password = "hobo"
    public static let fullName = "Hobo"
    /// Unattended-setup options for the first boot (`VZMacGuestProvisioningOptions`).
    public static let logsInAutomatically = true
    public static let enablesRemoteLogin = true

    /// Hobo's own key pair, published in its source on purpose: VMs are local and disposable, and one
    /// shared key lets any host reach any VM with no per-VM state.
    public static let insecurePublicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNxejdMRRDAvDfZhcYhz/dax+uK0cYeU/eUn/EmozqI hobo insecure public key"

    /// The private half of `insecurePublicKey`, used for every connection after setup.
    public static let insecurePrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBzcXo3TEUQwLw32YXGIc/3WsfritHGHlP3lJ/xJqM6iAAAAKBQHdzfUB3c
    3wAAAAtzc2gtZWQyNTUxOQAAACBzcXo3TEUQwLw32YXGIc/3WsfritHGHlP3lJ/xJqM6iA
    AAAEAz+7IomIikIOx82yDyLfsiy0UqoNVCcl7vXsdYVwJRE3NxejdMRRDAvDfZhcYhz/da
    x+uK0cYeU/eUn/EmozqIAAAAGGhvYm8gaW5zZWN1cmUgcHVibGljIGtleQECAwQF
    -----END OPENSSH PRIVATE KEY-----

    """

    /// Where create uploads hobo-agent before `script` runs, which installs it as the stub
    /// (decision 15) at `agentPath`, run at boot by the `agentDaemon` LaunchDaemon. The stub
    /// fetches the agent and execs it, but launchd made the stub's path the responsible process,
    /// and an exec doesn't change that: TCC sees `agentPath` as the client for everything the agent
    /// runs (`GUITestingGrants`; checked in tccd's log on 27.2, 2026-11-08).
    public static let agentUpload = "/tmp/hobo-agent"
    public static let agentPath = "/usr/local/libexec/hobo-agent"
    public static let agentDaemon = "com.hobo.agent"

    /// `hobo ui`'s driver in a macOS guest, which the agent fetches from the host on first use each
    /// boot (`Agent/tool.go`) into its run directory, which a boot clears.
    public static let uiToolPath = "/var/run/hobo-agent/hobo-ui"
    /// Where hobo-ui keeps the `username` user's refs between commands, made by the agent.
    public static let uiStateDirectory = "/var/run/hobo-agent/ui/\(username)"

    /// The guest command for `hobo ui <vm> <arguments>`.
    public static func uiCommand(_ arguments: [String]) -> [String] {
        ["/usr/bin/env", "HOBO_UI_STATE=\(uiStateDirectory)", uiToolPath] + arguments
    }

    /// Root script run once, over password SSH, right after unattended setup.
    public static var script: String {
        """
        set -eu
        echo '\(username) ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/\(username)
        chmod 0440 /etc/sudoers.d/\(username)
        install -d -m 700 -o \(username) -g staff /Users/\(username)/.ssh
        cat > /Users/\(username)/.ssh/authorized_keys <<'EOF'
        \(insecurePublicKey)
        EOF
        chown \(username):staff /Users/\(username)/.ssh/authorized_keys
        chmod 600 /Users/\(username)/.ssh/authorized_keys
        pmset -a sleep 0 displaysleep 0 disksleep 0
        sudo -u \(username) defaults -currentHost write com.apple.screensaver idleTime -int 0
        defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime -int 0
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
        install -d -m 755 \((agentPath as NSString).deletingLastPathComponent)
        install -m 755 \(agentUpload) \(agentPath)
        rm -f \(agentUpload)
        cat > /Library/LaunchDaemons/\(agentDaemon).plist <<'EOF'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(agentDaemon)</string>
        <key>ProgramArguments</key><array><string>\(agentPath)</string><string>stub</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>StandardErrorPath</key><string>/var/log/hobo-agent.log</string>
        </dict></plist>
        EOF
        launchctl bootstrap system /Library/LaunchDaemons/\(agentDaemon).plist

        """
    }

    /// Root script run at the end of the conventions boot: waits up to 5 minutes for the first
    /// auto-login to finish, signalled by the user's tccd opening the TCC.db it creates then (also
    /// what `[gui_testing]` writes into). SSH answers well before the login is done, and shutting
    /// down before it is leaves the next boot, the one recipe steps run in, with no GUI session at
    /// all (checked on macOS 27.2, 2026-11-02); later boots log in either way.
    public static let waitForLoginScript = """
        for attempt in $(seq 60); do
          lsof -c tccd 2>/dev/null | grep -q '/ProtectedSystem/.*/TCC\\.db$' && exit 0
          sleep 5
        done
        echo 'the first login did not finish within 5 minutes' >&2
        exit 1

        """

    /// Root script run after recipe steps: drop caches, logs, history and temp files so the new VM
    /// is small and carries nothing from the build. Freed blocks return to the ASIF via TRIM.
    public static let cleanupScript = """
    rm -rf /Library/Caches/* /Users/\(username)/Library/Caches/* /Library/Updates/* 2>/dev/null
    find /private/var/log -type f -exec rm -f {} + 2>/dev/null
    rm -rf /Users/\(username)/.zsh_history /Users/\(username)/.zsh_sessions /Users/\(username)/.bash_history
    rm -rf /var/root/.zsh_history /var/root/.zsh_sessions /var/root/.bash_history
    rm -rf /private/var/folders/*/*/T/* /private/tmp/hobo-* 2>/dev/null
    true

    """
}
