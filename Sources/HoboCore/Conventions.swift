import Foundation

/// Vagrant conventions applied to every macOS VM: `vagrant`/`vagrant`, passwordless sudo, the
/// insecure key, and no sleep or screensaver.
public enum Conventions {
    public static let username = "vagrant"
    public static let password = "vagrant"
    public static let fullName = "Vagrant"
    /// Unattended-setup options for the first boot (`VZMacGuestProvisioningOptions`).
    public static let logsInAutomatically = true
    public static let enablesRemoteLogin = true

    /// https://github.com/hashicorp/vagrant/tree/main/keys
    public static let insecurePublicKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1YdxBpNlzxDqfJyw/QKow1F+wvG9hXGoqiysfJOn5Y vagrant insecure public key",
        "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key",
    ]

    /// The private half of the ed25519 insecure key, used for every connection after setup.
    public static let insecurePrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDdWHcQaTZc8Q6nycsP0CqMNRfsLxvYVxqKosrHyTp+WAAAAJj2TBMT9kwT
    EwAAAAtzc2gtZWQyNTUxOQAAACDdWHcQaTZc8Q6nycsP0CqMNRfsLxvYVxqKosrHyTp+WA
    AAAEAveRHRHSCjIxbNKHDRzezD0U3R3UEEmS7R33fzvPQAD91YdxBpNlzxDqfJyw/QKow1
    F+wvG9hXGoqiysfJOn5YAAAAEHNwb3hAdmFncmFudC1kZXYBAgMEBQ==
    -----END OPENSSH PRIVATE KEY-----

    """

    /// Root script run once, over password SSH, right after unattended setup.
    public static var script: String {
        """
        set -eu
        echo '\(username) ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/\(username)
        chmod 0440 /etc/sudoers.d/\(username)
        install -d -m 700 -o \(username) -g staff /Users/\(username)/.ssh
        cat > /Users/\(username)/.ssh/authorized_keys <<'EOF'
        \(insecurePublicKeys.joined(separator: "\n"))
        EOF
        chown \(username):staff /Users/\(username)/.ssh/authorized_keys
        chmod 600 /Users/\(username)/.ssh/authorized_keys
        pmset -a sleep 0 displaysleep 0 disksleep 0
        sudo -u \(username) defaults -currentHost write com.apple.screensaver idleTime -int 0
        defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime -int 0
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false

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
