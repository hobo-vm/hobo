extension Recipe {
    /// The starter `Hobo.toml` written by `hobo init`. It starts unpinned (`ipsw = "latest"`): the
    /// first `create` prints the pin to paste in.
    public static let template = """
    # Hobo recipe: build a VM from it with `hobo create <name> --from Hobo.toml`.
    # The guest gets the Vagrant conventions (vagrant/vagrant, passwordless sudo, SSH, no sleep or
    # automatic updates); add your own setup as [[provision]] steps.

    cpus   = 4
    memory = "8GB"
    disk   = "80GB"

    [source]
    # A URL or a local path, with its SHA-256. "latest" is the newest IPSW this Mac supports; it is
    # unpinned, so `hobo create` warns and prints the URL and sha256 to pin it with. Replace this
    # with those lines so every build uses the same macOS.
    ipsw = "latest"

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
