# Hobo design record

Hobo is a first-class CLI for virtual machines on Apple Silicon Macs: a command-line replacement for
VirtualBuddy, Parallels and VMware Fusion, built on Apple's Virtualization framework. It is
Vagrant-inspired (recipes, guest conventions, a `vagrant` user) but not a Vagrant clone. Decisions
were first reached in a design interview on 2026-10-28; the box/project model was replaced by named
global VMs on 2026-11-01.

## Goals

- Build a VM from a declarative recipe, then live in it: start, stop, SSH, snapshot, restore.
- Cheap experiments: clone a VM instantly, try something, discard the clone.
- Let agents (Claude via MCP or the CLI) drive and UI-test inside clean, disposable VMs **without
  stealing host focus**.
- Test cross-platform desktop apps: macOS, Linux and Windows guests from one CLI.
- Never hide tens of gigabytes: large files live where the user can see and delete them.

## Decisions

### Product

1. **Host and guests.** macOS hosts only. Guests: macOS first-class, then Linux, then Windows 11 on Arm
   (on a second engine, decision 20).
2. **Model.** Hobo manages **named, global VMs**. There are no boxes, no box store, no box packaging or
   catalog, and no project-scoped machines (decided 2026-11-01). macOS IPSWs and VMs are 20 GB+, so a
   build → `.box` tar → untarred box → machine pipeline tripled disk use for no benefit when nobody
   shares built artifacts: people share the recipe and build it themselves. A project-level file that
   attaches VMs to a directory can be added later without changing the core.
3. **Recipe.** A TOML file, conventionally `Hobo.toml` (written by `hobo init`), though `create`
   takes any path. It holds what is needed to build a VM: `[source]`, disk size, default `cpus`
   and `memory`, ordered `[[provision]]` steps, and optional `[gui_testing]`. It contains no host
   state, so it can be handed to someone else to build. A recipe is an input to `create`, not the
   VM's record (the bundle keeps a copy, decision 7): it can live in a project, or an agent or the
   GUI can write one to a temp directory and discard it; the GUI edits a VM through `hobo set`,
   not its recipe. Relative `path`/`source` values resolve against the recipe's directory. Recipes
   should pin sources (IPSW URL + SHA, image URL + SHA, Xcode version + SHA); unpinned sources
   warn. A bare `hobo init` writes `ipsw = "latest"` and says to paste in the pin the first
   `create` prints (decided 2026-11-01: Apple publishes no SHA-256, so pinning there would mean a
   20 GB download); `hobo init <build>` pins a build from `hobo images` (decision 8).
4. **Commands.** VM-centric verbs, no Vagrant aliases:
   `init [<build>] [--force]`, `images [<build>] [--latest]`, `validate [recipe]`,
   `create <name> [recipe] [--hold-on-failure]`, `list`,
   `start [--ephemeral] [--gui] [--cold] [--share path] [--idle-timeout d]`, `stop [--force]`,
   `suspend`, `ssh <name> [-- cmd]`, `exec <name> [--gui] -- cmd`, `cp`, `ip`, `view`, `screenshot`,
   `clone <src> <dst> [--ephemeral]`, `delete <name> [--yes]`, `rename <old> <new>`,
   `set <name> --cpus/--memory/--disk/--share/--unshare`, `snapshot save|restore|list|delete`,
   `provision <name> [recipe]` (re-run steps on an existing VM), `df`. A recipe argument defaults
   to `./Hobo.toml`; there is no `--from` and no `--ipsw` override (decided 2026-11-01: the recipe
   names its source). Every command supports `--json`.
5. **Language.** Swift: swift-argument-parser, TOMLKit, modelcontextprotocol/swift-sdk.
6. **Platform.** Apple Silicon only, macOS 27+, for `VZMacGuestProvisioningOptions` (unattended macOS
   setup with SSH), vmnet, and ASIF disks. Apple's licence (enforced by the framework) caps hosts at
   2 concurrent macOS guests; Linux and Windows guests are uncapped.

### Storage

7. **VM bundles.** Each VM is a visible directory bundle, `~/Hobo/<name>.hobovm`, like
   `~/Parallels` and clear of Fusion's `~/Virtual Machines` (`HOBO_VMS` overrides the directory,
   e.g. for an external SSD), holding the disk, aux and identifier files, `config.json`, the recipe
   it was built from (`recipe.toml`, verbatim), `snapshots/`, and any saved state. Finder shows
   sizes and can move or delete bundles; a vanished bundle is a deleted VM, and Hobo refuses to
   start, rename or delete a bundle that is being built or whose VM process is still running.
   Names match `[A-Za-z0-9][A-Za-z0-9._-]{0,62}` (a filename, launchd label and socket name) and
   collide case-insensitively; `create` and `rename` refuse a taken name, with no `--force`.
   `delete` asks for confirmation on a terminal, refuses without one unless `--yes`, and `rename`
   is a directory move (nothing inside the bundle records the name). `~/.hobo/` holds only small
   state: the IPSW index, logs, sockets, launchd plists.
   A macOS guest's Apple ID identity derives from the host's Secure Enclave and host user, so a
   bundle moved to another Mac or user (e.g. on an external SSD) makes the guest re-authenticate.
8. **Install images.** Downloads land in `~/Downloads` under the vendor's filename (e.g.
   `UniversalMac_27.2_26B123_Restore.ipsw`) via `<name>.part`, renamed once the SHA-256 verifies, so
   users can see and delete them. `~/.hobo/images.json` maps each source (URL, or a local file's
   path) → SHA → path with size and mtime, so a 25 GB file isn't rehashed on every use; a changed
   size or mtime rehashes, and a missing or moved file is downloaded again. An unindexed file
   already in `~/Downloads` under the vendor's name is hashed and adopted if it matches; otherwise
   the download takes a Finder-style free name (`<name> 2.ipsw`) and never overwrites it. A stale
   `.part` restarts from scratch; there is no resume, and concurrent downloads of one URL are
   unsupported. A local path in `[source]` is used in place, never copied.
   `ipsw = "latest"` uses `VZMacOSRestoreImage.latestSupported`, warns as unpinned and prints the pin.
   Choosing a version replaces Mist (decided 2026-11-01): `hobo images` lists the macOS IPSWs
   (name, version, build, release date, size; `--latest` keeps the newest of each major;
   `images <build>` shows one build's details, URL and SHA-256 included) from
   ipsw.me's `v4/device/VirtualMac2,1?type=ipsw`, fetched live with no cache, hiding guests newer
   than the host's macOS. Apple publishes only the newest IPSW (what `latestSupported` reads), and
   `softwareupdate --list-full-installers` lists installer apps, not IPSWs, so ipsw.me is the only
   source of the history; it includes each file's SHA-256. `hobo init <build>` looks the build up
   there and writes `[source]` pinned to its URL and SHA-256. Only `images` and `init` read the
   catalog; recipes always hold a URL, so builds never depend on it. Later, `images --os` adds
   Linux, Windows and simulator images.
9. **Runtime config.** The recipe supplies defaults; `create` copies them into the bundle's
   `config.json`, which is the truth thereafter: `engine`, `os`, `cpus`, `memory` and `disk` (bytes),
   `macAddress` (fixed at create, so the DHCP lease and `hobo ip` are stable), `guestOSVersion`,
   `created`, `recipeSHA256` and `sourceSHA256`. `hobo set` changes CPUs, memory, disk (grow only) and
   persistent shares (virtio-fs; macOS default mount `/Volumes/My Shared Files/<tag>`, `readonly`
   supported). `start --share` adds a share for that run only. Clones inherit `config.json`.
   Shares must be folders: virtio-fs rejects volume roots, so Hobo refuses them up front. Guests
   don't Spotlight-index shares, and some guests have shown shared files' creation dates as
   2001-01-01. Growing the disk image doesn't grow the guest's APFS container, and in a macOS VM the
   Recovery container after it may block `diskutil apfs resizeContainer`; how grow finishes inside
   the guest is open (see `TODO.md`), and it must keep Recovery, which `[gui_testing]` needs.

### VM lifecycle

10. **Create.** `hobo create dev` builds in place in the bundle, which holds a `building` marker
    with the creating process's PID until done; `config.json` is written only on success. `hobo list`
    shows `building` while that process lives and `failed` once it is gone (`delete` removes it), and
    `broken` for a bundle with neither a valid `config.json` nor a marker. There are no checkpoints: every create is a full install (decided
    2026-11-01; clone covers "another one like this"). Steps for a macOS guest:
    1. source: resolve and verify the IPSW (decision 8). A guest newer than the host needs Apple's
       Device Support package (or the matching Xcode beta) on the host; without it the install fails
       obscurely, so `create` names the missing package. Disks under ~50 GB can fail macOS updates;
       the default is 80 GB;
    2. base install: `VZMacOSInstaller`, then a first boot with `VZMacGuestProvisioningOptions`
       (`vagrant`/`vagrant`, auto-login, Remote Login);
    3. conventions, over password SSH: passwordless sudo, Vagrant's insecure keys (ed25519 + RSA) in
       `authorized_keys`, no sleep/screensaver, no automatic updates; the insecure key is replaced by
       a per-VM key;
    4. `[gui_testing]` if enabled (decision 17);
    5. recipe `[[provision]]` steps (shell inline/path with `privileged` and `env`, and file), run
       once each over key SSH;
    6. clean guest shutdown. The disk is ASIF, which returns blocks to the host when the guest's APFS
       TRIMs them, so there is no zero-fill or compaction pass (verified on the host: an attached ASIF
       shrinks from 1 GB to 14 MB after delete + unmount); the build logs the resulting disk size.
       Not yet verified from inside a macOS guest: a report on eclecticlight.co says macOS 26 guests
       didn't reclaim ASIF space while RAW did (see `TODO.md`).

    During create the guest IP comes from `/var/db/dhcpd_leases` by MAC; SSH is the system `ssh`/`scp`,
    with the password supplied through `SSH_ASKPASS` until the key is in place. A failed or
    interrupted (^C, SIGTERM) create deletes the bundle; `--hold-on-failure` first keeps the failed VM
    up and prints the SSH command, and deletes it on ^C.
11. **Start, stop, suspend.** `start` boots, or resumes saved state if suspended (`--cold` discards
    it). It returns once the guest answers SSH (10 min timeout; a timeout or ^C leaves it booting),
    and if the VM process exits first it prints the tail of its log. Starting a running VM is a
    no-op; a `building`, `failed` or `broken` bundle is refused. `stop` is a clean shutdown, run by
    the VM process so a ^C on the client can't strand it halfway: SSH `sudo shutdown -h now` (2 min)
    if the guest answers SSH, else `requestStop` (30 s), then force. SSH comes first because
    `requestStop` (a virtual power-button press) doesn't shut a macOS guest down, which made every
    stop wait out its timeout (checked 2026-11-01). `--force`
    powers off at once, and kills a VM process that doesn't answer its socket (`launchctl kill
    SIGKILL`). A guest that shuts itself down ends its VM process too. `suspend` saves memory and
    device state and exits the VM process; `hobo list` shows suspended VMs and their state size.
12. **Clone.** `hobo clone dev exp` APFS-clones the bundle (full copy with a warning across volumes)
    and gives the clone a new machine identifier and MAC so both can run. The source must be stopped.
    **Open, spike before M2:** Howard Oakley reports that replacing an installed VM's machine
    identifier freezes boot (Apple: hardware model, identifier and aux storage must keep their
    install-time values), while two running VMs sharing an identifier get network on only one and,
    on macOS 15+, force Apple ID re-authentication. If a clone can't take a new identifier, a clone
    and its source can't run concurrently.
    `--ephemeral` (on `clone`, or `start dev --ephemeral`, which clones to an auto-named VM and starts
    it) deletes the clone when it stops; a suspended ephemeral clone is kept until it is stopped.
13. **Snapshots.** `hobo snapshot save|restore|list|delete <tag>`, stored in the bundle's
    `snapshots/<tag>/` as APFS clones of the disk and aux files, deleted with the VM. A running VM is
    paused, its state saved (`saveMachineStateTo`), its disk cloned at the same instant, and resumed;
    restoring such a snapshot returns to that running moment. Stopped VMs get disk-only snapshots.
    Saved state is only valid for the same CPU/memory config; after a change, restore boots from the
    disk with a warning. (Replaces the earlier DiskImageKit overlay plan.)

### Architecture

14. **Process model.** One process per VM: `hobo start` registers a per-user LaunchAgent running
    `hobo _vm-run <name>`, which owns the VM and serves a Unix control socket. CLI and `hobo mcp` are
    thin clients over a shared library. On-disk state is the source of truth; there is no central daemon.
    Every VM runs under launchd, and launchd's job table (one `launchctl list`) is how Hobo knows a
    VM is running; `_vm-run` refuses to run unless its parent is launchd (PID 1). Decided 2026-11-01:
    - The label is `com.hobo.vm.<key>`, where the key is `<first 8 hex of SHA-256 of the store's
      realpath>.<name>`, so two stores (`HOBO_VMS`) can each run a `dev`. The key also names
      `~/.hobo/<key>.sock`, `~/.hobo/<key>.log` (the process's stdout/stderr) and
      `~/.hobo/launchd/<key>.plist`.
    - The job is transient: `RunAtLoad`, no `KeepAlive`, and not in `~/Library/LaunchAgents`, so
      nothing starts at login. After the process exits the job stays loaded, and a nonzero last
      exit status shows as `crashed` in `hobo list` until the next `start` or `stop`. `start`,
      `stop`, `rename` and `delete` boot out a leftover job (bootstrapping a loaded label fails).
    - The control socket (mode 0600) carries one request per connection: a line of JSON with the
      protocol version, answered by a line of JSON (later streaming calls send several). A VM
      process refuses other versions. Paths over `sun_path`'s 103 bytes fail rather than truncate.
    - `_vm-run` is an `NSApplication` (`.accessory`) from the start. It runs AppKit's event loop
      from a synchronous `main`: started inside Swift's async main, the loop never services the
      main actor.
15. **Guest channel.** SSH (`vagrant` user, per-VM key). `hobo exec`/`cp`/`screenshot` go through the
    control socket, which renews leases (decision 18); agents should use them rather than raw `ssh`.
    A vsock `hobo-agent` may come later.
16. **Networking.** One shared vmnet NAT network with Hobo-controlled DHCP, so `hobo ip` is exact and
    VMs reach each other and the host. No port forwards or private networks (decided 2026-11-01);
    bridged (`public_network`) is deferred, since it needs a restricted entitlement or a root helper.
17. **Display and UI testing.** VMs are headless by default; the VM process is an `NSApplication` with
    `.accessory` activation policy, so it never takes focus. `hobo view` opens a window on demand;
    `start --gui` opens one at boot. No VNC. Agents drive the UI **inside the guest**:
    - SSH sessions run outside the GUI session and TCC blocks them from Accessibility and Screen
      Recording, so recipe `[gui_testing]` boots to recovery to disable SIP and pre-grants those
      services in TCC.db for `osascript`, `screencapture`, `sshd-keygen-wrapper`, the XCUITest runner
      and a configurable list. VMs built with it have SIP off; it is opt-in per recipe.
    - `exec --gui` runs the command in the `vagrant` user's Aqua session (`launchctl asuser`).
    - `screenshot` runs `screencapture` that way and returns the PNG.
    - A host-side framebuffer screenshot for wedged guests is deferred.
18. **Agent sessions and leases.** Agents work in sessions, not one-shot commands: `start --ephemeral`,
    many `exec`/`screenshot` calls, `stop`. There is no `hobo run`. Ephemeral VMs carry an idle
    timeout (`--idle-timeout`, default 30 min; off for normal VMs), renewed by every control-socket
    call; on expiry the VM process stops itself, deleting the clone. `hobo list` shows time
    remaining. `hobo mcp` also stops the ephemeral VMs it started when its session ends.
19. **MCP.** `hobo mcp` is a stdio server with typed tools mirroring the CLI: lifecycle, `exec`
    (with `gui`), `copy_in`/`copy_out`, `screenshot` (image content), `clone`, `snapshot`, `set`,
    `provision`, `list`. Destructive tools go through the client's normal permission prompts.
20. **Engines.** `config.json` records `engine = "vz" | "qemu"`. macOS and Linux use VZ. Windows 11
    on Arm needs QEMU (`qemu-system-aarch64 -accel hvf`, as UTM does), because VZ's only display
    device is virtio-gpu, which Windows on Arm can't drive. The QEMU engine keeps the same bundle,
    CLI, clone, snapshot (QEMU state save for running snapshots), suspend, leases and MCP; it runs
    under the same launchd process model, and QEMU is a Homebrew dependency. Windows recipes use
    `[source] iso` + `sha256` and an `autounattend.xml` that creates the `vagrant` user and enables
    OpenSSH. SSH runs in session 0, so `exec --gui` goes through a scheduled task in the interactive
    session; UI driving uses UI Automation or WinAppDriver. Gated by a spike (decision 24).
    **Licensing:** Microsoft's authorized way to virtualize Windows 11 on Arm on Apple Silicon is
    Parallels; check this before relying on the QEMU engine for work use.
21. **Linux guests.** Recipe `[source] image` + `sha256` (cloud image), set up by cloud-init on VZ;
    all lifecycle commands work the same.

### Engineering

22. **Install.** Build from source: `make install` builds release, signs with `entitlements.plist`
    (ad-hoc by default, `HOBO_SIGN_IDENTITY` for Developer ID), installs to `$(PREFIX)/bin`
    (default `~/.local/bin`). A VM's launchd plist runs the `hobo` binary that started it (symlinks
    resolved), so client and VM process are the same build; for an install that is this stable path.
    `start` refuses a binary without the virtualization entitlement, since a VM process failing
    that way would only say so in its log.
23. **Layout.** One Swift package, one `hobo` executable:
    - `HoboCore`: recipes, the VM store (`VMStore`: bundle paths, names, list, rename, delete) and
      `config.json` (`VMConfig`), image index, provisioners
    - `HoboVM`: engines (Virtualization framework, later QEMU), VM creation, the VM process (`VMRunner`), display
    - `HoboControl`: client ↔ VM-process socket protocol, and the client side of `start`/`stop` (`VMLifecycle`)
    - `HoboMCP`: MCP tools
    - `hobo`: CLI plus hidden `_vm-run` and `mcp` subcommands
    - `HoboVMTests` boot real VMs only with `HOBO_INTEGRATION=1`. The test runner can't hold the
      virtualization entitlement, so they drive the signed `hobo` binary (`make integration-test`).
      There is no CI; GitHub is a backup.
24. **Repo.** `ggal625/hobo`, private, Apache-2.0, `main`.
25. **Naming.** "Hobo" plays on "Vagrant". The hobo-and-trains metaphor (Boxcar, roundhouse,
    depot) was dropped on 2026-11-01: the recipe is plain `Hobo.toml`.

## Milestones

The 2026-11-01 pivot removed `hobo box build/validate-recipe`, packaging, `BoxMetadata`, roundhouse
checkpoints and the project-scoped Boxcar (`[[machine]]`, `[defaults]`, `forwarded_port`, `run`).
`Recipe` is the `Hobo.toml` parser (no `name`/`version`) and `BoxBuilder` became `VMCreator`, which
builds in a given directory; `ImageIndex` (the `~/Downloads` + `images.json` index) replaced `Depot`.

- **M0, skeleton:** done.
- **M1, a VM you live in:** `init`, `create`, `list`, `start` (headless under launchd via
  `_vm-run`), `stop`, `ssh`, `exec`, `cp`, `ip`, `view`, `delete`, `rename`, `set`, `provision`, `df`.
- **M2, experiments:** `clone`, `--ephemeral`, live and stopped snapshots, `suspend`/resume.
- **M3, agents:** leases, `[gui_testing]`, `exec --gui`, `screenshot`, `hobo mcp`, `--json`.
- **M4:** Linux guests.
- **M5:** Windows on the QEMU engine. The Windows spike (unattended install, headless boot, SSH,
  GUI-session screenshot) runs in parallel any time after M1, to prove the engine seam before M2/M3
  harden the model.
- **Later:** see `TODO.md`.

## Prior art

- [Tart](https://github.com/cirruslabs/tart): Swift VZ CLI with named VMs; reference for macOS installs.
- [VirtualBuddy](https://github.com/insidegui/VirtualBuddy), [Mist](https://github.com/ninxsoft/Mist):
  macOS guest GUI and IPSW/installer fetching.
- [UTM](https://github.com/utmapp/UTM): QEMU + HVF for Windows on Arm.
- [Mech](https://mechboxes.github.io/mech/docs/welcome/) and Vagrant: recipe and guest conventions.
- Howard Oakley's [Virtualisation on Apple silicon](https://eclecticlight.co/virtualisation-on-apple-silicon/)
  articles: guest limits, machine identity, shares, ASIF, version gates (reviewed 2026-11-01).
- WWDC26 session 224, "Expand the capabilities of your Virtualization app" (macOS 27 APIs).
