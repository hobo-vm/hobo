<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="Hobo" width="340">
  </picture>
</h1>

A command-line tool for named macOS, Linux and Windows VMs on Apple Silicon Macs,
built on Apple's Virtualization framework. Vagrant-inspired, not a Vagrant clone.

```sh
hobo init                          # write a starter Hobo.toml
hobo validate                      # check it without building
hobo create dev                    # build a VM from ./Hobo.toml
hobo list
hobo start dev                     # headless under launchd; never steals focus
hobo ssh dev
hobo stop dev                      # clean shutdown; --force powers off
```

> Status: **M1 in progress.** `init`, `validate`, `create`, `list`, `start`, `stop`, `rename` and
> `delete` are implemented. VMs live in `~/Hobo/<name>.hobovm` (`HOBO_VMS` overrides the directory).
> See [docs/design.md](docs/design.md) for the design and milestones.

## Recipes

A recipe is a TOML file, conventionally `Hobo.toml`, describing how to build a VM. Every VM gets
the Vagrant conventions (`vagrant`/`vagrant`, passwordless sudo, SSH, no sleep or automatic
updates); recipe steps add the rest.

```toml
cpus   = 4          # defaults: 4 cpus, 8GB memory, 80GB disk
memory = "8GB"
disk   = "80GB"

[source]
ipsw   = "https://updates.cdn-apple.com/…/UniversalMac_27.2_…_Restore.ipsw"  # or a path, or "latest"
sha256 = "…"        # required unless ipsw = "latest"

[[provision]]       # run once each, in order; paths are relative to the recipe
type   = "shell"    # inline or path; privileged (default true), env
inline = "softwareupdate --install-rosetta --agree-to-license"

[[provision]]
type        = "file"
source      = "files/zshrc"
destination = "/Users/vagrant/.zshrc"
```

## Requirements

- Apple Silicon Mac, macOS 27+
- Xcode 27 (Swift 6.4+)
- `brew install lld`, to build: the Windows boot driver is compiled from source during the build
- To run Windows guests, a Windows on Arm ISO from [Microsoft](https://www.microsoft.com/en-us/software-download/windows11arm64). Windows runs through a private Virtualization framework setting a macOS update could remove, and Microsoft authorizes only Parallels for Windows 11 on Apple Silicon, so check the licence before relying on it for work ([design decision 20](docs/design.md))

## Build

```sh
make install                 # release build, ad-hoc signed, installs to ~/.local/bin/hobo
HOBO_SIGN_IDENTITY="Developer ID Application: …" make install
make test                    # unit tests
make integration-test        # tests that drive the signed binary
```

## License

Apache-2.0
