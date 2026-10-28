# Hobo

Vagrant-style CLI for macOS hosts on Apple's Virtualization framework. The design record is
`docs/design.md`; read it before architectural changes, and update it when a decision changes.
Deferred work lives in `TODO.md`.

## Build and test

- `swift build` / `swift test` for day-to-day work.
- `make sign` / `make install`: the binary needs the `com.apple.security.virtualization`
  entitlement (`entitlements.plist`) to create VMs, so anything that boots a VM must use a signed build.
- VM-booting tests live in `Tests/HoboVMTests` and run only with `HOBO_INTEGRATION=1` (`make integration-test`).

## Architecture rules

- All logic lives in `HoboCore`/`HoboVM`. The CLI (`Sources/hobo`) and MCP (`HoboMCP`) are thin
  frontends and must not diverge.
- Each VM is owned by its own `hobo _vm-run` process under launchd. Clients talk to it via
  `HoboControl` over a Unix socket. On-disk state is the source of truth; no central daemon.
- VM processes never take focus (`.accessory` activation policy). Agents test inside guests via
  SSH, never by driving the host UI.
- Target platform is macOS 27; `Package.swift` is pinned to 26 until the 27 SDK is available.
  Gate 27-only APIs with `@available(macOS 27, *)` meanwhile.
