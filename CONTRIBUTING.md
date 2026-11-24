# Contributing to hobo

hobo is a CLI for named macOS, Linux and Windows VMs on Apple Silicon Macs, built on Apple's
Virtualization framework. This file covers building it, testing it, and getting a change merged.
The design record is [`docs/design.md`](docs/design.md): read it before an architectural change,
and update it when a decision changes.

## Setup

- An Apple Silicon Mac on macOS 27 or later, with Xcode 27 (Swift 6.4+).
- `brew install lld go node`. The Windows boot driver (`Firmware/WindowsBoot`) and the guest agent
  (`Agent/`, Go) are compiled during the Swift build. Node runs the docs scripts and the site.

## Building and testing

| Command | What it does |
| --- | --- |
| `swift build` | Debug build |
| `make test` | README and Windows backend checks, the docs-script tests, `swift test`, and `go test` in `Agent/` |
| `make sign` | Release build staged in `.build/hobo` (`bin/hobo`, `share/hobo`), signed with the virtualization entitlement |
| `make install` | `make sign`, then copies it under `/usr/local` (`PREFIX`), uninstalling a hobo Homebrew installed |
| `make help` | Every target |

`make test` is what a change has to pass. It needs no VMs.

### Tests that boot VMs

Creating or starting a VM needs the `com.apple.security.virtualization` entitlement
(`entitlements.plist`), which only a signed build has. The test runner can't hold it, so the
VM tests in `Tests/HoboVMTests` drive the signed binary from `make sign`, and run only through
`make integration-test`.

Most of them run on throwaway clones of three kept VMs: `macos27`, `ubuntu26` and `windows11`.
Build any that are missing first:

```sh
make test-vms HOBO_WINDOWS_ISO=~/Downloads/Win11_Arm64.iso   # Windows needs a Windows on Arm ISO
make integration-test
```

- `HOBO_MACOS_VM=`, `HOBO_LINUX_VM=` or `HOBO_WINDOWS_VM=` set empty leaves that guest out. A kept VM
  that is missing fails its tests rather than skipping them.
- A Mac runs at most two macOS guests at once, so `make integration-test` takes a host-wide lock,
  and runs from different checkouts queue.
- Run it for a change that touches VMs, guests or the agent. Say in the PR which guests you ran.

### hobo ui's Windows backend

`Sources/HoboVM/Resources/UI/hobo-ui-windows.exe` is built from `UIWindows/` and committed, and
`make test` fails while it is older than its sources. After changing `UIWindows/`, rebuild it
with `make windows-ui`. That runs the build in a Windows VM called `windows-build`;
`scripts/windows-ui.sh` says how to make one.

## Releasing

A release is a `v<version>` tag, a GitHub release with a tarball of the staged tree, and the
formula in [`hobo-vm/homebrew-tap`](https://github.com/hobo-vm/homebrew-tap), which is what
`brew install hobo-vm/tap/hobo` installs. A maintainer cuts one on `main`:

```sh
make release                 # the next minor after the latest tag
make release VERSION=0.1.1   # or a version you choose
```

No file states the version: a build takes it from the checkout's tags (`git describe`, in
`scripts/version.sh`), so `hobo --version` prints `0.2.0` when built at `v0.2.0` and
`0.2.0-3-g1a2b3c4` three commits later.

`scripts/release.sh` tags `HEAD` locally and runs `make test`, `make integration-test` (so it
needs the kept VMs) and `make release-test`. It then shows what it would publish and asks. If you
say no, or anything failed, the tag is deleted and nothing has left your machine. If you say yes,
it pushes the tag, creates the GitHub release, commits the formula to the tap, and pushes `main`
last.

`make release-test` is the part to run when you change the packaging. It writes the tarball and
the formula to `.build/dist`, installs the formula with Homebrew from the local tarball (through
a local tap, `hobo-vm/release-test`) and runs `brew test`. Nothing is published. If Homebrew
already had a hobo installed, this build replaces it; otherwise the test uninstalls its own, so
it doesn't shadow a `make install` build.

The formula is generated from `packaging/hobo.rb.in`: edit that, never the tap's copy, which the
next release overwrites.

## Rules of the codebase

- **All logic lives in `HoboCore` and `HoboVM`.** The CLI (`Sources/hobo`) and the MCP server
  (`HoboMCP`) are thin frontends over them and must not diverge.
- **Each VM is owned by its own `hobo _vm-run` process under launchd.** Clients talk to it over a
  Unix socket (`HoboControl`). State on disk is the source of truth; there is no central daemon.
- **hobo never takes focus on the host.** VM processes use the `.accessory` activation policy, and
  tests never open host windows or touch the Dock. Test inside guests over SSH or the agent, never
  by driving the host's UI.
- **Never `await` between a `Process`'s `run()` and `waitUntilExit()`.** `waitUntilExit` on a
  thread other than the one that launched the process can block for good. Wait on a
  `terminationHandler` instead (`spikes/waituntilexit`).
- **macOS 27 is the minimum** (`Package.swift`), so macOS 27 APIs need no availability checks.
- hobo hasn't shipped, so there are no older VMs or builds to stay compatible with yet.

## Docs

Each feature has a page in `docs/features/`, and README.md's feature tour is generated from them.
When a change alters what a user sees, update that feature's page and run `make readme`;
`make test` fails while the README is stale. `make site-preview` serves the docs site,
[hobo.gsquared.app](https://hobo.gsquared.app/), with live reload.

## Issues

Work is tracked in GitHub Issues.

| Label | Meaning |
| --- | --- |
| `P0`–`P4` | Priority, `P0` the most urgent |
| `bug`, `enhancement`, `spike` | The kind of work; a spike finds out whether something can work |
| `deferred`, `later` | Shelved, or planned after the current milestone |
| `slot:macos-vm` | Needs to boot macOS VMs by hand. Only one such issue is in progress at a time, since a Mac runs two macOS guests at most |

Assign an issue to yourself when you start on it. Blocked-by links show what has to land first.

## Pull requests

- Branch from `main`, and open a PR back to it. A maintainer reviews it; one approval merges it.
- Keep a PR to one change, with its tests and its docs.
- Commit messages describe the behavior that changed, as one sentence, e.g. "cp makes the
  directories above a file's destination in the guest, as it already did for a directory".

## The name

The code is Apache-2.0, and forks are welcome. The name "Hobo" and the logo are not covered by
the license (its section 6), so please give a fork that you distribute a different name.
