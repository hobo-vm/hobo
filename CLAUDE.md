# Hobo

First-class CLI for named VMs (macOS, Linux, later Windows) on Apple Silicon hosts, built on Apple's
Virtualization framework: a command-line replacement for VirtualBuddy/Parallels/Fusion. Vagrant-inspired,
not a Vagrant clone; VMs are built from `Hobo.toml` recipes, and there are no boxes. The design record is
`docs/design.md`; read it before architectural changes, and update it when a decision changes.
Deferred work lives in `TODO.md`.

## Build and test

- `swift build` / `swift test` for day-to-day work.
- `make sign` / `make install`: the binary needs the `com.apple.security.virtualization`
  entitlement (`entitlements.plist`) to create VMs, so anything that boots a VM must use a signed build.
- VM-booting tests live in `Tests/HoboVMTests` and run only with `HOBO_INTEGRATION=1` (`make integration-test`).
- `make integration-test` holds a host-wide lock, so runs from different worktrees queue.
- Manual VM testing isn't locked: only one worktree boots macOS VMs by hand at a time.

## Architecture rules

- All logic lives in `HoboCore`/`HoboVM`. The CLI (`Sources/hobo`) and MCP (`HoboMCP`) are thin
  frontends and must not diverge.
- Each VM is owned by its own `hobo _vm-run` process under launchd. Clients talk to it via
  `HoboControl` over a Unix socket. On-disk state is the source of truth; no central daemon.
- VM processes never take focus (`.accessory` activation policy). Agents test inside guests via
  SSH, never by driving the host UI.
- Target platform is macOS 27 (`Package.swift` minimum); no availability gating needed for 27 APIs.
