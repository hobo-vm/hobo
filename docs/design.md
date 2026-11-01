# Hobo design record

Hobo is a Vagrant-style CLI for macOS hosts built on Apple's Virtualization framework,
in the spirit of [Mech](https://mechboxes.github.io/mech/docs/welcome/). Decisions below
were reached in a design interview on 2026-10-28.

## Goals

- Fast, reproducible dev and test VMs on Apple Silicon Macs, with your own boxes.
- Let agents (Claude via MCP) create, drive and test inside VMs **without stealing host focus**.
- Pristine, identical test runs: every run starts from the same box state, no leftovers.
- Boxes built from declarative recipes, AI-assisted, following HashiCorp box conventions.

## Decisions

### Product

1. **Host and guests.** macOS hosts only. Guests: macOS first-class, Linux second. Windows guests out of scope.
2. **Compatibility.** Standalone CLI using Vagrant's command vocabulary (`init`, `up`, `ssh`, `halt`, `destroy`,
   `status`, `box`, `snapshot`, `provision`, `package`…) and box conventions. It does not read Vagrantfiles
   and is not a Vagrant plugin.
3. **Config file.** `Boxcar`, TOML. `[defaults]` plus ordered `[[machine]]` tables (array order = boot order).
   A single-machine Boxcar may put settings at top level (machine name `default`). `hobo init` writes a
   `# vim: ft=toml` modeline.
4. **Language.** Swift: swift-argument-parser, TOMLKit, modelcontextprotocol/swift-sdk.
5. **Platform.** Apple Silicon only, macOS 27+, for `VZMacGuestProvisioningOptions` (unattended macOS
   setup with SSH), vmnet topologies + port forwarding + cross-process network serialization, DiskImageKit
   layered images, and USB passthrough. Apple's licence (enforced by the framework) caps hosts at
   2 concurrent macOS guests; Linux guests are uncapped.

### Architecture

6. **Process model.** One process per VM: `hobo up` registers a per-user LaunchAgent running
   `hobo _vm-run <id>`, which owns the `VZVirtualMachine` and serves a Unix control socket. CLI and
   `hobo mcp` are thin clients over a shared library. On-disk state (`.hobo/` per project, `~/.hobo/`
   global) is the source of truth; there is no central daemon.
7. **Guest channel.** SSH only in v1 (`vagrant` user, insecure key replaced on first `up`). IPs are known
   from Hobo-controlled vmnet DHCP. A vsock `hobo-agent` may come later.
8. **Synced folders.** virtio-fs by default, `type = "rsync"` for one-way copies, `readonly` supported.
   Default guest path: `/vagrant` on Linux, `/Users/vagrant/project` on macOS (root volume is read-only).
9. **Networking.** Per-project vmnet shared (NAT) network; `forwarded_port` via vmnet port forwarding;
   `private_network` via vmnet host mode shared across VM processes, static IPs via DHCP. Bridged
   (`public_network`) deferred, since it would need a restricted entitlement or a root helper.
10. **Provisioners.** `shell` (inline/path, `privileged`, `run = once|always|never`, `env`) and `file`.
    Run state recorded in `.hobo/`. External provisioners (Ansible, pyinfra) later via a JSON plugin contract.
11. **Display.** VMs are headless by default; the VM process is an `NSApplication` with `.accessory`
    activation policy, so it never takes focus. `hobo view <machine>` opens a window on demand over the
    control socket; `gui = true` opens one at boot. No VNC (only private API exists).
12. **MCP.** `hobo mcp` is a stdio server with typed tools mirroring the CLI: lifecycle, `exec`,
    `copy_in`/`copy_out`, `screenshot` (image content, taken in-guest), `provision`, `snapshot`,
    `box_list`, `box_build`, later `sim_*`. Destructive tools go through the client's normal permission
    prompts. Every CLI command also supports `--json`.

### Boxes and testing

13. **Pristine runs.** Boxes are installed read-only in `~/.hobo/boxes/<name>/<version>/`. Each machine is
    copy-on-write:
    - persistent machine in `.hobo/machines/<name>/`, an APFS clone of the box files (plain copy across
      volumes), removed on `destroy` (decided 2026-10-30; DiskImageKit overlays are only for the two
      cases below, where stacking matters);
    - `hobo snapshot save|restore <tag>` freezes and stacks overlays;
    - `hobo run [--machine m] -- <cmd>` boots a throwaway overlay, rsyncs folders in, runs the command,
      copies declared outputs back, destroys the VM, and passes through the exit code.
14. **Box building.** `hobo box build <recipe.toml> [--output dir] [--fresh] [--hold-on-failure]`
    (decided 2026-10-30):
    1. source: `[source] ipsw = "latest"` (`VZMacOSRestoreImage.latestSupported`, warns as unpinned and
       prints the pin) or a URL/local path with a required `sha256`. Version lookup ("27.1") is deferred.
       Downloads land in the **depot**, `~/.hobo/depot/<sha256>.ipsw` (via `download.part`, renamed once
       verified); `index.json` maps URL → hash so `latest` downloads once;
    2. base install: `VZMacOSInstaller`, then a first boot with `VZMacGuestProvisioningOptions`
       (`vagrant`/`vagrant`, auto-login, Remote Login);
    3. conventions, over password SSH: passwordless sudo, Vagrant's insecure keys (ed25519 + RSA) in
       `authorized_keys`, no sleep/screensaver, no automatic updates. The disk is then checkpointed in the
       **roundhouse** (`~/.hobo/roundhouse/checkpoints/<key>`, keyed by IPSW hash, disk size and
       `Conventions.fingerprint`, a hash of the conventions script and unattended-setup options) and
       rebuilds clone it (APFS clone) unless `--fresh`;
    4. recipe steps: Boxcar `[[provision]]` steps (shell/file), run once each over key SSH;
    5. optional GUI-testing prep (opt-in `[gui_testing]`, deferred to Later): disable SIP via recovery
       boot, pre-grant Accessibility and Screen Recording in TCC.db so ephemeral runs never prompt;
    6. cleanup: caches, logs, history, temp files, then a clean guest shutdown. The disk is ASIF, which
       returns blocks to the host when the guest's APFS TRIMs them, so no zero-fill or compaction pass
       (zero-filling would inflate an ASIF, and `diskutil image` has no compact). Verified on the host
       (an attached ASIF shrinks from 1 GB to 14 MB after delete + unmount); the build logs the
       resulting disk size so a VZ path that drops TRIM is visible;
    7. package `<name>-<version>.box` (slash → dash), an uncompressed tar of `disk.asif`, `aux.img`,
       `hardware-model.bin`, `machine-identifier.bin` and `metadata.json` (provider `hobo`, guest OS +
       version, arch, min host, default cpus/memory/disk, content and recipe hashes), plus a `.sha256`.
       Installing into the box store is `hobo box add`'s job.

    The build VM runs in-process in the foreground on VZ NAT; the guest IP comes from
    `/var/db/dhcpd_leases` by its (random) MAC. SSH is the system `ssh`/`scp`, with the password supplied
    through `SSH_ASKPASS` until the insecure key is in place. A failed build keeps its roundhouse
    directory; `--hold-on-failure` keeps the VM up and prints the SSH command. `hobo box validate-recipe`
    checks a recipe without building. `hobo package` (Vagrant-style package-from-running-machine) is
    also exposed.
15. **Sharing.** Recipe-first. Recipes must pin sources (IPSW build + SHA, image URL + SHA, Xcode
    version + SHA), unpinned fetches produce warnings, and built boxes carry a content hash. A static
    box catalog (Vagrant-style versioned metadata JSON on S3/HTTPS, `hobo box publish`, resumable
    downloads) comes later for team/QA distribution of identical artifacts.

### Engineering

16. **Install.** Build from source: `make install` builds release, signs with `entitlements.plist`
    (ad-hoc by default, `HOBO_SIGN_IDENTITY` for Developer ID), installs to `$(PREFIX)/bin`
    (default `~/.local/bin`). launchd plists reference this stable path.
17. **Layout.** One Swift package, one `hobo` executable:
    - `HoboCore`: Boxcar, state, box store, recipes, provisioners
    - `HoboVM`: Virtualization framework, overlays, vmnet, display
    - `HoboControl`: client ↔ VM-process socket protocol
    - `HoboMCP`: MCP tools
    - `hobo`: CLI plus hidden `_vm-run` and `mcp` subcommands
    - `HoboVMTests` boot real VMs only with `HOBO_INTEGRATION=1`. The test runner can't hold the
      virtualization entitlement, so they drive the signed `hobo` binary (`make integration-test`).
      There is no CI; GitHub is a backup.
18. **Repo.** `ggal625/hobo`, private, Apache-2.0, `main`.
19. **Naming.** "Hobo" plays on "Vagrant"; new names follow the hobo-and-trains metaphor (depot,
    roundhouse). Built artifacts stay `box`es and the project file stays the `Boxcar`.

## Milestones

- **M0, skeleton:** package layout, Boxcar parsing, `hobo init`/`validate`, signing Makefile, docs.
- **M1, macOS guest end to end:** `box build` from recipe, `up`/`ssh`/`halt`/`destroy`/`status`, launchd
  VM processes, NAT, virtio-fs, `hobo view`. Ordered for an early GUI boot (2026-10-30): `box add` and
  a foreground `up` that boots in-process with a window come first; `_vm-run` later makes `up` headless
  and detached and moves the window to `hobo view`.
- **M2, agent mode:** `hobo mcp`, `--json`, `hobo run`, snapshots.
- **M3:** Linux guests, forwarded ports, private networks, multi-machine, rsync folders, full provisioners.
- **Later:** see `TODO.md`.

## Prior art

- [Mech](https://mechboxes.github.io/mech/docs/welcome/): the workflow model.
- [Tart](https://github.com/cirruslabs/tart): Swift VZ CLI for CI; reference for macOS installs.
- [VirtualBuddy](https://github.com/insidegui/VirtualBuddy), [Mist](https://github.com/ninxsoft/Mist):
  macOS guest GUI and IPSW/installer fetching.
- WWDC26 session 224, "Expand the capabilities of your Virtualization app" (macOS 27 APIs).
