extension Recipe {
    /// The starter `Hobo.toml` written by `hobo init`. It starts unpinned (`ipsw = "latest"`): the
    /// first `create` prints the pin to paste in.
    public static let template = template(source: """
        # A URL or a local path, with its SHA-256. "latest" is the newest IPSW this Mac supports; it is
        # unpinned, so `hobo create` warns and prints the URL and sha256 to pin it with. Replace this
        # with those lines so every build uses the same macOS, or pick a build from `hobo images`
        # and run `hobo init <build> --force` (before adding steps here) to start pinned.
        ipsw = "latest"
        """)

    /// The starter `Hobo.toml` written by `hobo init <build>`, pinned to `image`.
    public static func template(pinnedTo image: IPSWCatalog.Image) -> String {
        template(source: image.sourceLines)
    }

    /// The starter `Hobo.toml` written by `hobo init --os linux`, pinned to `image`. With `desktop`
    /// (the default; `--server` turns it off), its first step installs Ubuntu's desktop.
    public static func template(pinnedTo image: UbuntuCatalog.Image, desktop: Bool) -> String {
        let desktopStep = desktop ? """
            # The desktop, for `hobo view` and GUI testing (`hobo exec --gui`, `hobo screenshot`): Ubuntu's
            # minimal desktop, hobo logged in at boot, no screen blanking or lock, and accessibility on
            # for AT-SPI. It starts from the next boot.
            [[provision]]
            type   = "shell"
            inline = '''
            \(desktopScript)'''


            """ : ""
        let desktopHint = desktop ? "" : """
            # No desktop: this guest boots to a text console. For one, run `hobo init --os linux --force`
            # (before adding steps here).
            #

            """
        return """
        # Hobo recipe: build a VM from it with `hobo create <name>`.
        # The guest gets the standard conventions (hobo/hobo, passwordless sudo, SSH, no automatic
        # updates) from cloud-init on its first boot; add your own setup as [[provision]] steps.

        cpus   = 4
        memory = "4GB"
        disk   = "32GB"

        [source]
        # A cloud image's URL or local path, with its SHA-256. Pick another from `hobo images --os linux`
        # and run `hobo init --os linux <version> --force` (before adding steps here).
        \(image.sourceLines)

        \(desktopStep)# Steps run once each, in order, in the guest. Paths are relative to this file.
        #
        \(desktopHint)# [[provision]]
        # type       = "shell"
        # path       = "setup.sh"
        # privileged = false        # run as hobo instead of root
        # env        = { GREETING = "hello" }
        #
        # [[provision]]
        # type        = "file"
        # source      = "files/bashrc"
        # destination = "/home/hobo/.bashrc"

        """
    }

    /// The starter `Hobo.toml` written by `hobo init --os windows <iso>`, pinned to that ISO.
    public static func template(windowsISO path: String, sha256: String) -> String {
        let quotedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        # Hobo recipe: build a VM from it with `hobo create <name>`.
        # The install adds the guest conventions (hobo/hobo, an administrator, SSH with PowerShell
        # as its shell, logged in to the desktop at boot) and hobo-agent; add your own setup as [[provision]] steps.

        cpus   = 4
        memory = "8GB"
        disk   = "64GB"

        [source]
        # A Windows on Arm installer's URL or local path, with its SHA-256.
        iso    = "\(quotedPath)"
        sha256 = "\(sha256)"

        # The display is 1024x768, which the window scales. 1920x1200, following the window, needs a
        # patched display driver, test-signed, so Windows runs in Test Mode: a watermark on the
        # desktop, and any test-signed driver loads.
        #
        # [windows]
        # resizable_display = true

        # Steps run once each, in order, as hobo. Scripts are PowerShell. Paths are relative to this file.
        #
        # [[provision]]
        # type = "shell"
        # path = "setup.ps1"
        # env  = { GREETING = "hello" }
        #
        # [[provision]]
        # type        = "file"
        # source      = "files/settings.json"
        # destination = "C:/Users/hobo/settings.json"

        """
    }

    /// Installs `ubuntu-desktop-minimal` and sets it up for unattended use: GDM logs hobo in at
    /// boot, GNOME's first-login and post-upgrade welcome wizards never run (the second ignores
    /// `gnome-initial-setup-done`), and the session never blanks or locks, so screenshots and UI
    /// tests see the desktop. For GUI testing, toolkits that only expose their accessibility tree
    /// when asked (Chromium, Electron) always do, and the Python bindings that `hobo screenshot`
    /// and AT-SPI scripts use are installed by name rather than relied on as the desktop's
    /// dependencies, which they are today. For `hobo ui` (designs/hobo-ui-linux-windows.md): hobo
    /// gets `/dev/uinput`, for real input events that reach Wayland apps, and hobo's GNOME Shell
    /// extension, which says where windows are, is installed and enabled.
    static let desktopScript = """
        set -eu
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y -o DPkg::Lock::Timeout=300 ubuntu-desktop-minimal python3-gi gir1.2-atspi-2.0 python3-evdev
        echo uinput > /etc/modules-load.d/hobo.conf
        echo 'KERNEL=="uinput", SUBSYSTEM=="misc", OWNER="\(Conventions.username)", MODE="0600"' > /etc/udev/rules.d/70-hobo-uinput.rules
        \(CloudInit.agentPath) gnome-extension
        cat > /etc/gdm3/custom.conf <<'EOF'
        [daemon]
        AutomaticLoginEnable=true
        AutomaticLogin=\(Conventions.username)
        EOF
        mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
        printf 'user-db:user\\nsystem-db:local\\n' > /etc/dconf/profile/user
        cat > /etc/dconf/db/local.d/00-hobo <<'EOF'
        [org/gnome/desktop/session]
        idle-delay=uint32 0

        [org/gnome/desktop/screensaver]
        lock-enabled=false

        [org/gnome/desktop/interface]
        toolkit-accessibility=true

        [org/gnome/shell]
        enabled-extensions=['hobo@gsquared.app']
        disable-user-extensions=false
        EOF
        # Locked: hobo's own settings end up holding false (seen on 26.04), which would otherwise win.
        mkdir -p /etc/dconf/db/local.d/locks
        printf '%s\\n' /org/gnome/desktop/interface/toolkit-accessibility /org/gnome/shell/enabled-extensions /org/gnome/shell/disable-user-extensions > /etc/dconf/db/local.d/locks/00-hobo
        dconf update
        systemctl --global mask gnome-initial-setup-first-login.service gnome-initial-setup-upgrade-login.service

        """

    private static func template(source: String) -> String {
        """
        # Hobo recipe: build a VM from it with `hobo create <name>`.
        # The guest gets the standard conventions (hobo/hobo, passwordless sudo, SSH, no sleep or
        # automatic updates); add your own setup as [[provision]] steps.

        cpus   = 4
        memory = "8GB"
        disk   = "80GB"

        [source]
        \(source)

        # After installing macOS, create applies [security], then [gui_testing], then the [[provision]]
        # steps, wherever they are in this file.
        #
        # Turn off System Integrity Protection, and AMFI so ad-hoc signed binaries may use restricted
        # entitlements (turning AMFI off needs SIP off too). SIP only turns off by hand: create
        # stops after installing macOS and opens the VM in recoveryOS for you to type one command.
        #
        # [security]
        # sip  = false
        # amfi = false
        #
        # Let exec, screenshot and agents drive the guest UI: grants Accessibility, Screen
        # Recording and System Events automation to hobo-agent, osascript, screencapture and
        # Terminal, plus any absolute paths or bundle IDs in allow. Works with SIP on.
        #
        # [gui_testing]
        # enabled = true
        # allow   = ["com.example.AppUITests.xctrunner"]
        #
        # Steps run once each, in order, in the guest. Paths are relative to this file.
        #
        # [[provision]]
        # type   = "shell"
        # inline = "softwareupdate --install-rosetta --agree-to-license"
        #
        # [[provision]]
        # type       = "shell"
        # path       = "setup.sh"
        # privileged = false        # run as hobo instead of root
        # env        = { GREETING = "hello" }
        #
        # [[provision]]
        # type        = "file"
        # source      = "files/zshrc"
        # destination = "/Users/hobo/.zshrc"

        """
    }
}
