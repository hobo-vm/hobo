# Hobo

Vagrant-style development and test VMs for Apple Silicon Macs, built on Apple's
Virtualization framework. Your machines ride in a `Boxcar`.

```sh
hobo init greg/macos-27   # write a Boxcar
hobo up                   # boot (headless; never steals focus)
hobo ssh
hobo run -- ./run-tests.sh   # pristine throwaway VM, exit code passed through
hobo mcp                  # let an agent drive VMs over MCP
```

> Status: **M1 in progress.** `hobo init`, `hobo validate` and `hobo box build` are implemented.
> See [docs/design.md](docs/design.md) for the design and milestones.

## Requirements

- Apple Silicon Mac, macOS 27+
- Xcode 27 (Swift 6.4+)

## Build

```sh
make install                 # release build, ad-hoc signed, installs to ~/.local/bin/hobo
HOBO_SIGN_IDENTITY="Developer ID Application: …" make install
make test                    # unit tests
make integration-test        # boots real VMs; full box build with the depot's 27.2 IPSW or HOBO_TEST_IPSW=…
make box RECIPE=Recipes/macos-27.toml
```

## License

Apache-2.0
