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

    /// The starter `Hobo.toml` written by `hobo init --os linux`, pinned to `image`.
    public static func template(pinnedTo image: UbuntuCatalog.Image) -> String {
        """
        # Hobo recipe: build a VM from it with `hobo create <name>`.
        # The guest gets the Vagrant conventions (vagrant/vagrant, passwordless sudo, SSH, no automatic
        # updates) from cloud-init on its first boot; add your own setup as [[provision]] steps.

        cpus   = 4
        memory = "4GB"
        disk   = "32GB"

        [source]
        # A cloud image's URL or local path, with its SHA-256. Pick another from `hobo images --os linux`
        # and run `hobo init --os linux <version> --force` (before adding steps here).
        \(image.sourceLines)

        # Steps run once each, in order, over SSH. Paths are relative to this file.
        #
        # A desktop, for `hobo view` (the server image boots to a text console). It starts from the next boot.
        # [[provision]]
        # type   = "shell"
        # inline = "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal"
        #
        # [[provision]]
        # type       = "shell"
        # path       = "setup.sh"
        # privileged = false        # run as vagrant instead of root
        # env        = { GREETING = "hello" }
        #
        # [[provision]]
        # type        = "file"
        # source      = "files/bashrc"
        # destination = "/home/vagrant/.bashrc"

        """
    }

    private static func template(source: String) -> String {
        """
        # Hobo recipe: build a VM from it with `hobo create <name>`.
        # The guest gets the Vagrant conventions (vagrant/vagrant, passwordless sudo, SSH, no sleep or
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
        # Let SSH sessions (exec, screenshot, agents) drive the guest UI: grants Accessibility,
        # Screen Recording and System Events automation to sshd, osascript, screencapture and
        # Terminal, plus any absolute paths or bundle IDs in allow. Works with SIP on.
        #
        # [gui_testing]
        # enabled = true
        # allow   = ["com.example.AppUITests.xctrunner"]
        #
        # Steps run once each, in order, over SSH. Paths are relative to this file.
        #
        # [[provision]]
        # type   = "shell"
        # inline = "softwareupdate --install-rosetta --agree-to-license"
        #
        # [[provision]]
        # type       = "shell"
        # path       = "setup.sh"
        # privileged = false        # run as vagrant instead of root
        # env        = { GREETING = "hello" }
        #
        # [[provision]]
        # type        = "file"
        # source      = "files/zshrc"
        # destination = "/Users/vagrant/.zshrc"

        """
    }
}
