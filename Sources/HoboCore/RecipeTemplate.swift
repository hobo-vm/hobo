extension Recipe {
    /// The starter `Hobo.toml` written by `hobo init`: a pinned macOS 27.2 base. Update the pin when
    /// a newer IPSW ships.
    public static let template = """
    # Hobo recipe: build a VM from it with `hobo create <name> --from Hobo.toml`.
    # The guest gets the Vagrant conventions (vagrant/vagrant, passwordless sudo, SSH, no sleep or
    # automatic updates); add your own setup as [[provision]] steps.

    cpus   = 4
    memory = "8GB"
    disk   = "80GB"

    [source]
    # A URL or a local path, with its SHA-256. ipsw = "latest" picks the newest IPSW this Mac supports.
    ipsw   = "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw"
    sha256 = "6613b34e8589db2202a01ec37a2648afb141ece13428175183f8f3e38438534f"

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
