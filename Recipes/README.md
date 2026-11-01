# Recipes

First-party box recipes for `hobo box build` (M1). `hobo box validate-recipe <file>` checks one
without building. Format:

```toml
name = "greg/macos-27"
version = "1.0.0"
description = "macOS 27 base"
cpus = 4            # defaults: 4 cpus, 8GB memory, 80GB disk
memory = "8GB"
disk = "80GB"

[source]
ipsw = "https://updates.cdn-apple.com/…/UniversalMac_27.1_…_Restore.ipsw"  # or a path, or "latest"
sha256 = "…"        # required unless ipsw = "latest"

[[provision]]       # Boxcar provisioner syntax; paths are relative to the recipe
type = "shell"
inline = "softwareupdate --install-rosetta --agree-to-license"
```

- `macos-27.toml`: base macOS 27.2 guest with Vagrant conventions (`make box` builds it)

Planned:

- `macos-27-xcode.toml` (later): adds Xcode and GUI-testing prep (SIP off, TCC pre-grants)
- `ubuntu-24.04.toml`: arm64 cloud image with cloud-init
