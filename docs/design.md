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
   (decision 20).
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
   `[source]` holds exactly one of `ipsw` (a macOS guest) or `image` (a Linux cloud image,
   decision 21), so the key is the guest OS; an `image` is always pinned, since there is no
   "latest" to resolve. Defaults follow the OS: 4 CPUs, 8 GB and 80 GB for macOS, 4 CPUs, 4 GB
   and 32 GB for Linux (enough for a desktop added by a step).
4. **Commands.** VM-centric verbs, no Vagrant aliases:
   `init [--os macos|linux] [--server] [<build-or-version>] [--force]`,
   `images [--os macos|linux] [<build-or-version>] [--all]`, `validate [recipe]`,
   `create <name> [recipe] [--hold-on-failure]`, `list [-v]`,
   `start [--ephemeral] [--gui] [--cold] [--share path] [--idle-timeout d]`, `stop [--force]`,
   `suspend`, `discard`, `ssh <name> [--print] [-- cmd]`, `exec <name> [--gui] -- cmd`, `cp [-r] <src>... <dst>`, `ip <name>`, `view`, `screenshot`,
   `clone <src> <dst> [--ephemeral]`, `delete <name> [--yes] [--force]`, `rename <old> <new>`,
   `set <name> --cpus/--memory/--disk/--share/--unshare/--keep`, `snapshot save|restore [--force]|list|delete <name> <tag>`,
   `provision <name> [recipe]` (re-run steps on an existing VM), `usage`,
   `claude install|uninstall [--project] [--force]`. A recipe argument defaults
   to `./Hobo.toml`; there is no `--from` and no `--ipsw` override (decided 2026-11-01: the recipe
   names its source). Every command supports `--json` (decided 2026-11-01): a command that finishes
   quickly prints one JSON document; `create`, `start` and `stop`, which take minutes, print JSON
   Lines instead, `{"event":"log","message":…}` as they go and a final `{"event":"result","result":…}`,
   so an agent sees progress. A failure is JSON on stdout too (`{"error":…}`, or an `error` event)
   with exit status 1; usage errors stay text on stderr. Sizes are bytes, dates ISO 8601, and the
   shapes (`VMSummary`, `RecipeSummary`, the lifecycle results) live in the core so `hobo mcp` returns
   the same ones. A CLI command gets all of this by conforming to `OutputCommand`, returning its
   result rather than printing it. `delete --json` needs `--yes` or `--force`, since it can't prompt. `ip --json`
   gives the name and IP; `exec --json` and `cp --json` send the guest's output (or scp's) to stderr
   and print `{"exitStatus":…}`, still exiting with that status. `ssh` has no `--json`: it hands the
   terminal to ssh, and `exec` is the scriptable way to run a command. `usage` has no `--json`
   either: its output is reference text (decision 19).
5. **Language.** Swift: swift-argument-parser, TOMLKit, modelcontextprotocol/swift-sdk.
6. **Platform.** Apple Silicon only, macOS 27+, for `VZMacGuestProvisioningOptions` (unattended macOS
   setup with SSH) and ASIF disks. Apple's licence (enforced by the framework) caps hosts at
   2 concurrent macOS guests; Linux and Windows guests are uncapped.

### Storage

7. **VM bundles.** Each VM is a visible directory bundle, `~/Hobo/<name>.hobovm`, like
   `~/Parallels` and clear of Fusion's `~/Virtual Machines` (`HOBO_VMS` overrides the directory,
   e.g. for an external SSD), holding the disk, aux and identifier files, `config.json`, the recipe
   it was built from (`recipe.toml`, verbatim), `snapshots/`, and any saved state. Finder shows
   sizes and can move or delete bundles; a vanished bundle is a deleted VM, and Hobo refuses to
   start, rename or delete a bundle that is being built or whose VM process is still running
   (`delete --force` powers a running VM off first, as `stop --force` does).
   Names match `[A-Za-z0-9][A-Za-z0-9._-]{0,62}` (a filename, launchd label and socket name) and
   collide case-insensitively; `create` and `rename` refuse a taken name, with no `--force`.
   `delete` asks for confirmation on a terminal and refuses without one, unless `--yes` or `--force`
   skips it, and `rename` is a directory move (nothing inside the bundle records the name).
   `~/.hobo/` holds only small state: the IPSW index, logs, sockets, launchd plists.
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
   (name, version, build, release date, size; the newest build of each major by default, every
   build with `--all` (decided 2026-11-02, replacing `--latest`);
   `images <build>` shows one build's details, URL and SHA-256 included) from
   ipsw.me's `v4/device/VirtualMac2,1?type=ipsw`, fetched live with no cache, hiding guests newer
   than the host's macOS. Apple publishes only the newest IPSW (what `latestSupported` reads), and
   `softwareupdate --list-full-installers` lists installer apps, not IPSWs, so ipsw.me is the only
   source of the history; it includes each file's SHA-256. `hobo init <build>` looks the build up
   there and writes `[source]` pinned to its URL and SHA-256. Only `images` and `init` read the
   catalog; recipes always hold a URL, so builds never depend on it.
   `images --os linux` (decided 2026-11-02) lists Ubuntu's arm64 server cloud images from Canonical's
   simplestreams index (`cloud-images.ubuntu.com/releases/streams/v1/com.ubuntu.cloud:released:download.json`,
   one fetch with every release's URL, size and SHA-256): the newest release (dated serial, e.g.
   `20261016`, at a URL that never changes) of each supported series by default, every release
   with `--all`, and unsupported series hidden. `images --os linux 26.04` shows one series' newest
   release; `hobo init --os linux [<version>]` pins it, the newest supported LTS without one.
   Ubuntu publishes no desktop cloud images, so a Linux recipe gets a desktop from a step:
   `init --os linux` writes one first, by default (decided 2026-11-02), that installs
   `ubuntu-desktop-minimal`, has GDM log `vagrant` in at boot, masks GNOME's welcome wizards
   (`gnome-initial-setup`'s first-login and post-upgrade user services) and turns off screen
   blanking and lock; `--server` leaves it out.
   `--os windows` has no catalog: Microsoft offers no download Hobo could pin, so `init` takes the
   path of an ISO the user downloaded, and hashes and checks it. Simulator images may join `--os` later.
9. **Runtime config.** The recipe supplies defaults; `create` copies them into the bundle's
   `config.json`, which is the truth thereafter: `os`, `cpus`, `memory` and `disk` (bytes),
   `macAddress` (fixed at create, so the DHCP lease and `hobo ip` are stable), `guestOSVersion`,
   `created`, `recipeSHA256` and `sourceSHA256` (`guestOSVersion` is `27.2.0 (26B123)` for
   macOS, and names the distribution for Linux, e.g. `Ubuntu 26.04` from `/etc/os-release`),
   `ephemeral` (decision 12) and, for Linux, `nicMatchedByDriver` (decision 21).
   `hobo set` changes CPUs, memory, disk (grow only) and
   persistent shares, all on a stopped VM, and `--keep` clears `ephemeral`, on a running or
   suspended VM too. `start --share` adds a share for that run only. Clones inherit `config.json`
   but for a new MAC, `created` and `ephemeral`.
   Shares are virtio-fs on the macOS automount tag, so the guest mounts each at
   `/Volumes/My Shared Files/<name>` with nothing to run inside it; the host can't change that
   path, and a provision step can symlink a share somewhere nicer (decided 2026-11-02, over
   per-share tags mounted over SSH, which a reboot inside the guest would lose). A Linux guest
   gets the same multiple-directory share on one fixed tag, `hobo`, which an fstab line written by
   the cloud-init seed at create (`hobo /mnt/hobo virtiofs defaults,nofail 0 0`) mounts at
   `/mnt/hobo`, so shares added later appear at `/mnt/hobo/<name>` with nothing changed in the
   guest. A Linux VM always attaches the device, empty without shares, so `/mnt/hobo` is always a
   mount and nothing written there lands on the guest's disk. The guest sees a shared file's host
   owner, so `vagrant` is created with the host user's uid and shared files are its own; the gid
   is left alone (host `staff`, 20, shows as `dialout` on Ubuntu). A macOS guest needs no such
   match: its virtio-fs mount ignores ownership, showing every shared file as the calling user's
   (gid 20; `root` sees 99:99) whatever the host owner, while still enforcing the host's mode bits,
   and files the guest creates belong to the host user (checked 2026-11-02 on a 27.2 guest with a
   uid-502 guest user and root-owned host files, hobo-2gi). Both commands take
   `--share <folder>[:ro]`, named by the folder's basename; names must be unique
   case-insensitively, and a clash is refused with a hint to rename or symlink a folder.
   `set --unshare <name|folder>` runs before `--share`, so one call can make a share read-only.
   `config.json` keeps `shares: [{name, path, readOnly}]` with absolute paths. Shares change only
   on a stopped VM, like the rest of `set`, and `start --share` refuses a running one (live
   changes are deferred, Beads hobo-z12). A persistent share whose folder has gone (an unplugged
   drive) is left out of that run with a warning and stays in `config.json`; a missing
   `start --share` folder is refused. Recipes declare no shares (host state, decision 3); defaults
   with recipe-relative paths are deferred (Beads hobo-a0t).
   Shares must be folders: virtio-fs rejects volume roots, so Hobo refuses them up front. Guests
   don't Spotlight-index shares, and some guests have shown shared files' creation dates as
   2001-01-01. A macOS guest's disk grow is two steps, verified end to end on a macOS 27.2 guest (2026-11-01, 80 →
   100 GB). On the host, with the VM stopped, `diskutil image resize --image-only --size <n>
   disk.asif` grows the image and moves the trailing `Apple_APFS_Recovery` container to the new
   end, so the free space directly follows the main container. Then in the guest, `sudo diskutil apfs
   resizeContainer disk0s2 0` grows the container live, without a reboot. Recovery is kept: its
   container is intact, the guest still boots normally, and booting with
   `startUpFromMacOSRecovery` reaches the recoveryOS startup options.
   `hobo set --disk` does the host step and updates `config.json`'s `disk`, setting
   `diskGrowPending`. At the next boot the VM process runs the guest step once SSH answers, against
   the boot volume's APFS physical store (looked up with `diskutil info /`, not assumed to be
   `disk0s2`), before `start` reports the VM running, and clears the flag. A Linux guest's host
   step moves the backup GPT instead, and its guest step is `growpart` on the root partition then
   `resize2fs`, both live (cloud-init's growpart, which grew it at create, is off by then). A
   failure is logged and leaves the flag set, so the next start retries. `set` only changes a
   stopped VM, so `config.json` always matches a running one. CPUs and memory are checked against
   the Virtualization framework's host limits. The disk never shrinks (decided 2026-11-02): ASIF
   already returns the guest's freed blocks to the host, so a smaller virtual size saves nothing,
   and shrinking would mean shrinking APFS in the guest and moving Recovery first.

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
       `authorized_keys`, no sleep/screensaver, no automatic updates. The insecure key stays: a
       per-VM key is deferred (decided 2026-11-01, Beads hobo-cip). The boot then waits (up to
       5 min) for the first auto-login to finish, signalled by the user's tccd opening its TCC.db:
       SSH answers well before then, and shutting down early left the next boot, where recipe steps
       run, with no GUI session at all (2026-11-02, macOS 27.2);
    4. `[security]` if it turns SIP off (decision 17): the one step that needs a person, in
       recoveryOS, then a boot to check it and set the AMFI boot-arg;
    5. `[gui_testing]` if enabled (decision 17): TCC grants written from the host into the stopped
       guest's Data volume, then checked over SSH on the next boot;
    6. recipe `[[provision]]` steps (shell inline/path with `privileged` and `env`, and file), run
       once each over key SSH. `hobo provision <name> [recipe]` runs a recipe's steps again, in
       order, on a running VM, from the client over key SSH: for iterating on steps without a
       30-minute rebuild, or bringing a VM up to date with its recipe. The rest of the recipe is
       ignored, steps should be safe to repeat, and the bundle's `recipe.toml` and `recipeSHA256`
       stay the record of what the VM was built from (decided 2026-11-02);
    7. clean guest shutdown. The disk is ASIF, which returns blocks to the host when the guest's APFS
       TRIMs them, so there is no zero-fill or compaction pass; the build logs the resulting disk size.
       Verified on the host (an attached ASIF shrinks from 1 GB to 14 MB after delete + unmount) and
       from inside a macOS 27.2 guest (2026-11-01: a 5 GB random file grew `disk.asif` by 5.25 GB
       allocated, and deleting it returned all of it within 5 s, with the VM still running). A report
       on eclecticlight.co said macOS 26 guests didn't reclaim ASIF space; that no longer holds on 27.

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
    The VM process pauses the VM, saves into the bundle's `suspending/` (VZ's state plus `run.json`,
    the run's shares, run-only ones included) and renames it to `suspended/`, then powers the paused
    VM off: the guest never runs past the save, so the disk stays as the state expects. A failed
    save resumes the VM and `suspend` reports it. Resuming restores the state with exactly the
    recorded shares (VZ refuses any other configuration), deletes `suspended/` before the guest
    runs again, since the disk then moves on, and sets the guest's clock over SSH (checked
    2026-11-02: a resumed guest is behind by the whole suspension). A macOS guest tries `sntp`, else
    takes the host's time; a Linux guest takes the host's time (`date -s @<epoch>`: Ubuntu 26.04's
    uutils `date` rejects the BSD form) and chrony refines it. A macOS guest's shares are also
    remounted over SSH: VZ's virtio-fs device restarts on the host, and its old handles fail lookups
    with ENOENT until the mount is replaced (files a guest process had open in a share are lost). A
    Linux guest's mount keeps working across the restore, so it is left alone. Resume took about
    6 s and a suspend about 8 s for an 8 GB guest using 1.5 GB. A resume that fails (a share
    folder gone, state the host's VZ can't read) keeps the state and points to `start --cold`.
    Discarding memory is always explicit: `stop` refuses a suspended VM, and `hobo discard` (or
    `start --cold`) throws the state away, leaving it stopped.
    `set` and `start --share` refuse a suspended VM, whose state fits only its old configuration;
    `rename` and `delete` don't.
12. **Clone.** `hobo clone dev exp` APFS-clones the bundle (full copy with a warning across volumes)
    and gives the clone a new machine identifier and MAC so both can run. The source must be stopped.
    The clone keeps the source's aux storage and hardware model; only the identifier and MAC are
    new. Spiked 2026-11-02 on a 27.2 guest and host (hobo-3w5): a clone with a new identifier boots
    to SSH and a GUI login on every boot, reports a new serial number and platform UUID, and runs
    beside its source with network on both. Howard Oakley's boot freeze after replacing the
    identifier did not reproduce. Fresh aux storage as well never leaves firmware (no DHCP lease,
    no disk writes), so aux must be copied. Sharing an identifier also worked, given distinct MACs
    (Tart's way: it keeps a macOS clone's identifier), but the guest's serial is then duplicated,
    which Apple services can notice (Apple ID re-auth, untested here), so Hobo regenerates it.
    Decided 2026-11-03 (hobo-9if): a clone copies the bundle's platform files (`VMBundle.platformFiles`:
    disk, aux or EFI vars, hardware model, identifier, then a new identifier written over it) with
    `COPYFILE_CLONE`, which makes a full copy where it can't clone, plus `recipe.toml` and a
    rewritten `config.json`. `console.log`, snapshots and anything else stay behind. A clone always
    lands in the source's directory, so it is a full copy only if the source bundle is a symlink to
    another volume, which warns. The clone is marked as being built while it copies. The source
    must also be built and readable; a Linux source must match its NIC by driver (decision 21).
    `--ephemeral` (on `clone`, or `start dev --ephemeral`, which clones to `dev-<4 hex>` and starts
    it, printing the name and returning it as `name` in the JSON) records `ephemeral` in
    `config.json`. One rule deletes it, in one place (`VMStore.removeIfEphemeral`; decided
    2026-11-03 after a review found exit paths that each had to remember the call, and
    `discard` that didn't): once it has booted, whenever it has neither a process nor saved state.
    Its VM process writes a `started` marker in the bundle as it boots, so a `clone --ephemeral`
    waits, stopped, for its first start. The VM process applies the rule as it exits, however it
    stops (`hobo stop`, the guest shutting down, a crash, or (hobo-r86) a lease expiring), and the
    store applies it whenever it reads a VM, so a VM whose process was killed, or went with a host
    reboot, or whose saved state was discarded, goes the next time any command looks: with no
    daemon, nothing else could. The rule reads `config.json` then, so `hobo set --keep` keeps it.
    It deletes the bundle and the job's plist and socket, and the job's log after a clean exit;
    after a failure the log stays, so a failed `start` can still show why (an auto-named clone's
    name never comes back, so clean logs would pile up). A suspended ephemeral VM is kept, and
    `hobo discard` deletes it. `hobo stop` and `hobo discard` report the deletion
    (`"outcome":"deleted"`), and `hobo list` marks ephemeral VMs.
13. **Snapshots.** `hobo snapshot save|restore|list|delete <vm> <tag>`, stored in the bundle's
    `snapshots/<tag>/` as APFS clones of the platform files (`VMBundle.platformFiles`), deleted with
    the VM. A running VM is paused, its state saved (`saveMachineStateTo`), its disk cloned at the
    same instant, and resumed (`.snapshot` on the control socket); its guest clock, which stood
    still, is then set over SSH, as a resume does, though its shares need no remount, since the
    device never restarts. A suspended VM's state and disk are cloned as they lie, which also makes
    a live snapshot. Stopped VMs get disk-only snapshots. (Replaces the earlier DiskImageKit overlay plan.)
    Decided 2026-11-03 (hobo-di8), and checked then on a 27.2 guest and host: a VM runs on normally
    after `saveMachineStateTo`, and a disk cloned while it is paused matches the state, even for
    unsynced writes read back with the guest's caches dropped. A save took about 9 s and a
    restore over a running VM about 14 s for an 8 GB guest using 2.5 GB.
    The same testing found a macOS guest, now and then and only in the integration test, ahead of
    the host after a resume by about the time it was frozen, though `sntp` had succeeded (cause not
    found; a dozen restores by hand never showed it). So the clock is compared with the host's
    after NTP, and more than 2 s off takes the host's time.
    - A snapshot's `suspended/` is laid out like a bundle's (`SavedState`), and `snapshot.json`
      records the time, CPUs, memory, disk size and `diskGrowPending`. It is written to
      `snapshots/.saving-<tag>` and renamed into place; the next save or boot deletes a leftover.
    - Restoring clones the files into the bundle's `restoring/`, so running out of space fails
      before the VM loses anything, then renames them over the VM's, the saved state last; the next
      restore or boot deletes what a restore that died left in that folder. A live
      snapshot's state becomes the VM's saved state, and `restore` starts the VM, so the one resume
      path does the clock, the share remount and `start --cold`; if the resume fails the VM stays
      suspended. A window showing on a running VM reopens when a live snapshot comes back. A
      disk-only snapshot leaves it stopped. The snapshot stays, to restore again.
      Fusion's GUI also resumes running, though its `vmrun revertToSnapshot` leaves that to `start`.
    - Over a running or suspended VM, `restore` refuses without `--force`, which powers it off or
      discards its state: discarding memory stays explicit (decision 11), but a guest about to be
      thrown away isn't worth a graceful shutdown. A stopped VM's disk is replaced with no flag.
    - Saved state is only valid for the same CPU/memory config; after a change, restore boots from
      the disk with a warning, keeping the current CPUs and memory. The disk's size goes back with
      the disk (`disk` and `diskGrowPending` in `config.json`): the state still fits it, and
      re-growing would invalidate the state for an unrelated setting.
    - Ephemeral VMs can't have snapshots: `restore --force` must end the process, and with no
      process and no state the rule in decision 12 deletes the VM, snapshots included.
    - A tag follows a VM name's rules, is required, and can't be reused until deleted, since a
      snapshot may be the only copy of a good state. `snapshot delete` works in any VM state.
    - While a save runs, `exec`, `cp`, `suspend` and another save are refused, and a graceful stop
      waits for it; a forced stop doesn't, so a hung save can't keep a VM up.
    - Disk usage is reported by `hobo list` (decided 2026-11-04, hobo-vqi), not a `df` command, a
      name that on macOS means free space. `USED` is the VM's own files, in full even where a clone
      shares them; `SNAPSHOTS` is the count and the bytes they hold that the VM's own files don't;
      `TOTAL` counts every block once, so it can be less than the rows add up to. `list -v` and
      `snapshot list` give each snapshot's unique bytes, what deleting it alone frees, so a VM's
      rows can add up to less than its `SNAPSHOTS` figure when snapshots share blocks. `delete`'s
      prompt shows `USED` plus `SNAPSHOTS`. Install images aren't reported: they sit in
      `~/Downloads`, in plain sight.
      All of it comes from comparing physical blocks (`F_LOG2PHYS_EXT`, per volume), because
      nothing cheaper is exact: `ATTR_CMNEXT_PRIVATESIZE` leaves out blocks shared by some but not
      all clones, and `ATTR_CMNEXT_CLONEID` stops matching as soon as a clone diverges (both checked
      2026-11-04). Files whose blocks can't be looked up count as unshared. It reads only metadata:
      a release build's whole `list` took 0.12 s over two clones of a 30 GB disk and two snapshots.
      `VMLifecycle.listing()` and `VMStore.snapshots(of:)` produce these results, so `hobo mcp` gets
      the same ones: usage is only ever measured over every VM, and a frontend only renders.

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
15. **Guest channel.** SSH (`vagrant` user, Vagrant's insecure key; host keys aren't checked, since
    IPs are reused across VMs and rebuilds). `ssh`/`scp` are spawned with responsibility disclaimed
    (`responsibility_spawnattrs_setdisclaim`, as terminals do), so macOS's Local Network privacy
    sees Apple's `ssh` rather than hobo (decided 2026-11-02): the VM process runs under launchd as
    its own app, an ad-hoc build is a new app on every rebuild, and each one put up an Allow dialog
    that silently failed every SSH probe until someone clicked it. `hobo exec`/`cp`/`screenshot` go through the
    control socket, which renews leases (decision 18); agents should use them rather than raw `ssh`.
    A vsock `hobo-agent` may come later. Decided 2026-11-01:
    - `hobo ip` asks the VM process, which knows the guest's lease; a stopped VM, or one without a
      lease yet, is an error.
    - `hobo ssh` gets the IP the same way and `execv`s the system `ssh`, so sessions, TTYs and exit
      statuses are plain ssh's; `-- cmd` is passed to ssh as is, and `--print` prints the command.
    - `hobo exec` runs in the VM process over its SSH, without stdin or a TTY; the argv is
      shell-quoted for the guest's login shell. Output streams back as `output` messages (base64
      stdout/stderr chunks), ending with `exited`; the client exits with that status. A client that
      hangs up (^C) cancels the request. Closing a non-TTY ssh session doesn't signal the guest
      command, so the guest shell first prints its PID (a process group leader, since sshd starts
      a new session) and execs the command; on cancel the VM process kills that group over SSH.
    - `hobo cp` is scp-style, `[-r] <src>... <dst>`, with exactly one side naming the guest as
      `<vm>:<path>` (a colon after a slash is a host path). The VM process runs `scp` on the
      client's absolute host paths (same user, same machine) and streams its messages like `exec`.
16. **Networking.** The system's shared NAT (`VZNATNetworkDeviceAttachment`): every VM is on the same
    bridge (192.168.64.0/24), so VMs reach each other and the host. Each VM's MAC is fixed at create,
    so bootpd keeps giving it the same lease, and its IP is read from `/var/db/dhcpd_leases` by MAC,
    which makes `hobo ip` exact. No port forwards or private networks (decided 2026-11-01);
    bridged (`public_network`) is deferred, since it needs a restricted entitlement or a root helper.
    vmnet custom networks (`VZVmnetNetworkDeviceAttachment` with DHCP reservations) were rejected
    (decided 2026-11-01): a VM can only use a network created in its own process, which rules out
    one network shared by per-VM processes, and creating one needs an entitlement.
17. **Display and UI testing.** VMs are headless by default; a headless VM process is an `NSApplication`
    with `.accessory` activation policy, so it never takes focus on its own. `hobo view` opens a window on
    demand; `start --gui` opens one once the guest is ready. No VNC. Decided 2026-11-01:
    - `view` is a control-socket request (no protocol bump: an older VM process just refuses it). It
      errors on a stopped VM rather than booting it, and works while the VM is booting. `start --gui`
      passes `--gui` to `_vm-run`, which opens the window once the guest answers SSH (decided
      2026-11-02: a login prompt or login window shows well before then, so an earlier window
      looked ready when it wasn't), or after the SSH wait times out, so a stuck boot can be looked
      at; on a running VM it sends `view`. `status` reports whether the window is showing.
    - Showing the window brings it to the front and asks for focus, since a human asked for it;
      cooperative activation may still leave focus with the terminal. It captures system keys
      (⌘Tab, ⌘Space go to the guest). While the window shows, the process switches to `.regular`
      (Dock, ⌘Tab, its own menu bar, a full-screen Space): as `.accessory` it never owned the menu
      bar, so clicking it sent the window behind the active app. Hidden, it goes back to `.accessory`.
      Its menu has Keep Running in Background, Suspend and Shut Down, but no Quit, which would kill
      the VM. `hobo list` shows `running (window)` while it shows, and what the VM process is doing
      when it isn't plainly running, such as `stopping (saving state)` during a suspend.
    - Closing it asks: Keep Running (hides it; the next `view` re-shows the same window), Suspend
      (the `suspend` sequence; the window hides while the state saves, and comes back with the
      reason if the save fails), Shut Down (the `stop` sequence), or Cancel. The dialog is a sheet,
      so the socket keeps being served.
    - The guest display follows the window's size while it shows, and is set back to the configured
      1920×1200 when it is hidden, so headless runs and screenshots always see that size unless
      someone is watching. `[gui_testing]` may turn resizing off if that matters. Windows guests
      are the exception: fixed at 1024×768, with the window scaling it (decision 20).
    Agents drive the UI **inside the guest**:
    - SSH sessions run outside the GUI session and TCC blocks them from Accessibility and Screen
      Recording, so recipe `[gui_testing]` (opt-in) pre-grants them. **SIP stays on** (decided
      2026-11-01, replacing "boot to recovery and disable SIP", which needed keystroke scripting of
      recoveryOS): with the VM stopped after the conventions boot, create attaches the ASIF, mounts
      the guest's Data volume (unencrypted, and a regular user's mount ignores ownership, so no root;
      the host's SIP doesn't cover a foreign volume) and writes the rows itself. Inside the guest
      neither database is writable, even by root with Full Disk Access. Verified on a macOS 27.2
      guest (2026-11-01):
      - TCC attributes everything run over SSH to `/usr/libexec/sshd-keygen-wrapper`, so its rows are
        what count (also through `sudo launchctl asuser`); the defaults also grant `osascript`,
        `screencapture` and Terminal. `[gui_testing] allow = [...]` adds clients: an absolute path
        or a bundle ID (e.g. an `.xctrunner`).
      - Each client gets Accessibility and Screen Recording (`kTCCServiceAccessibility`,
        `kTCCServiceScreenCapture`) in the system TCC.db, and Automation of System Events
        (`kTCCServiceAppleEvents`), which UI scripting needs, in the user's TCC.db. A row in the system
        database doesn't satisfy Automation. On macOS 27 the user's database moved into tccd's
        container in `/private/var/containers/Data/ProtectedSystem`, found by its metadata. tccd
        creates it during the first auto-login, which the conventions boot waits for (step 3).
      - Apple clients get their designated requirement as `csreq` (`identifier "…" and anchor
        apple`, compiled on the host to the same blob tccd writes). Recipe clients get a NULL `csreq`,
        which tccd honours, so they need not exist yet when the grants are written (provision steps
        run after).
      - MDM was ruled out: `VZMacGuestProvisioningOptions` has no enrollment option, and a PPPC profile
        can't grant Screen Recording anyway.
      - Create then checks over SSH, before the provision steps, that Accessibility
        (`AXIsProcessTrusted`), Screen Recording (`CGPreflightScreenCaptureAccess`; `screencapture`
        succeeds without the grant, leaving windows out) and System Events scripting work, and
        fails otherwise.
      - The grants don't stop replayd's own approval dialog ("requesting to bypass the system private
        window picker"): the first capture by a client with no record raises it, from plain `exec` or
        `--gui`, and it blocks the guest's UI and shows in later screenshots. So create then seeds
        that record over SSH, before anything captures: `ScreenCaptureApprovals.plist` in the user's
        replayd group container, with its alert dates in 2099, for `sshd-keygen-wrapper` only, which
        everything run over SSH counts as (decided 2026-11-05). An app started on its own may count
        separately and still get the dialog when it captures. Checked on 27.2 for 5 captures over
        45 s; whether the record lasts for weeks or across macOS updates is unknown. A VM built
        before this needs rebuilding.
      - Running outside the GUI session cuts plain `exec` off less than that might suggest: on a VM
        with the grants, `screencapture` (windows included), `open` and System Events scripting all
        work from it, in the same way as from `--gui` (checked 2026-11-05 on 27.2). Automation of
        Finder times out from both, since only System Events is granted.
    - Recipe `[security] sip = false` (and `amfi = false`, which needs it) turns SIP and AMFI off,
      for testing ad-hoc signed binaries that claim restricted entitlements (decided 2026-11-02;
      `[gui_testing]` doesn't need it). Checked on a macOS 27.2 guest (2026-11-02): `csrutil disable`
      works in a VZ guest's recoveryOS (Options → Continue, sometimes a language picker, no user
      picker seen, then Utilities › Terminal; it asks y/n, then vagrant's password); paste from the host doesn't reach recoveryOS; once SIP is
      off, `sudo nvram boot-args="amfi_get_out_of_my_way=1"` works over SSH, and after a reboot an
      ad-hoc binary with `com.apple.developer.endpoint-security.client` runs instead of being killed.
      With SIP off the system TCC.db is writable inside the guest too.
      - It can't be unattended, so it is the one manual step of a create, and the recipe stays the
        whole record. `create` warns before installing and fails at once outside a GUI session
        (`create` runs under AppKit's loop only when it has one). After the conventions boot it boots
        recoveryOS with the VM window in front (Dock bounce and terminal bell; an unbundled binary
        can't post notifications) and a floating panel of typed steps (no Copy buttons, since paste
        doesn't work) with Cancel Build; closing the window also offers to cancel. The person shutting
        the guest down means done; a normal boot then checks `csrutil status` and sets the boot-arg,
        and if SIP is still on it goes back to recoveryOS with a note on the panel.
      - The provisioning boot checks what the guest runs with (`csrutil status`, `kern.bootargs`),
        fails if it isn't what the recipe asked, and records it as `sip`/`amfi` in `config.json`
        (missing means on, for older bundles). Clones inherit it as guest state.
    - `exec --gui` runs the command in the `vagrant` user's Aqua session: `sudo launchctl asuser
      <uid> sudo -u vagrant env PATH=… <cmd>` (`asuser` needs root; the inner `sudo` makes it the user
      again and resets the environment, hence `PATH`). It's a `gui` field on the `exec` request, so
      streaming, exit status, cancelling and leases are `exec`'s; killing the process group reaches
      through both `sudo`s (checked 2026-11-05 on 27.2). Auto-login can finish after SSH answers, so
      it waits up to 60 s for `/dev/console` and the `gui/<uid>` domain to be the user's, then exits
      125; holding `running` back instead would slow every start, and leave a VM with broken
      auto-login unreachable by plain `exec`. Decided 2026-11-05.
    - `screenshot [-o path]` is `exec --gui` of a script, in `GuestChannel`, with no request of its
      own: `screencapture -x` to a temp file (it can't write to stdout), then `cat`. It first asks
      `CGPreflightScreenCaptureAccess` in the guest and fails without the grant, since a capture
      without it succeeds with the windows left out, and that desktop could pass for an app that
      never opened. Asking the guest covers withdrawn grants and clones, which a host-side check of
      the recipe wouldn't. By default the PNG goes to a new `./<vm>-<timestamp>.png`, numbered if
      taken, so a session's shots never replace each other; `-o -` is stdout, and it prints the path
      (`--json`: `{name, path}`). Decided 2026-11-05.
    - On a Linux guest the VM process refuses both (`VMBundle.guiExecLine` is nil) until hobo-938.
    - A host-side framebuffer screenshot for wedged guests is deferred.
18. **Agent sessions and leases.** Agents work in sessions, not one-shot commands: `start --ephemeral`,
    many `exec`/`screenshot` calls, `stop`. There is no `hobo run`. An agent that dies or forgets
    leaves a clone running and holding one of the 2 macOS guest slots, and with no daemon only its
    own VM process can notice. So an ephemeral VM holds a lease on running: an idle timeout (nothing
    to do with the guest's DHCP lease), after which the VM process runs the normal graceful stop,
    which deletes the clone. `hobo mcp` also stops the ephemeral VMs it started when its session
    ends (hobo-i2j); the timeout is what covers a server that is killed, and CLI agents. Decided
    2026-11-04 (hobo-r86):
    - Only ephemeral VMs have one; normal VMs were kept on purpose, and aren't deleted anyway.
      `start --idle-timeout <d>` takes a whole number and a unit (`90s`, `30m`, `2h`) or `off`, and
      anything else is an error, so a typo can't turn the cleanup off; the default is 30 min. It
      lasts one run, as an argument to `_vm-run`, not in `config.json`: a resume starts over from
      the default. It is an error on a normal VM and on one already running.
    - `hobo set --keep` ends it: the VM process rereads `config.json` before acting on an expiry
      and when reporting the time left. If the file is unreadable, it stays up and warns.
    - Using the VM renews it, looking doesn't. `status` alone doesn't, or a polling `hobo list`
      would keep every forgotten clone alive, so `list` and the wait loops stay passive. Every other
      request does, including `renew` (`status` that counts), which `hobo ip`, `hobo ssh` and
      `start` on a running VM send. Their own SSH never reaches the socket, so these renew once, and
      a long `hobo ssh` session or raw `ssh` can expire underneath itself. `hobo provision` has a
      process to do better with: it sends `renew` every second while its steps run.
    - A running request holds it (a client that hangs up cancels its request, so an abandoned one
      can't), as does a showing window, whose clicks and keys never reach the socket; the full
      timeout restarts when they end. A window left open is a VM someone can see, not a forgotten one.
    - It counts from the end of the boot sequence, however that ended, so a short timeout can't end
      a guest still booting and a stuck boot still gets cleaned up; and only the host's awake time
      (`SuspendingClock`), so closing a laptop lid mid-session doesn't cost the session its VM.
    - `hobo list` shows `running, ephemeral, 28m left`, `busy` while held by a request, or
      `no timeout`, and `--json` `idleTimeoutSeconds` and `idleSecondsRemaining`. `start` states
      the timeout, since an expiry leaves nothing behind to say why the VM is gone (a kept log or
      record would pile up, as decision 12 says of logs); `hobo usage` and `AgentGuidance` say a VM
      not found mid-session has probably expired.
19. **MCP.** `hobo mcp` is a stdio server with typed tools mirroring the CLI: lifecycle, `exec`
    (with `gui`), `copy_in`/`copy_out`, `screenshot` (image content), `view`, `clone`, `snapshot`, `set`,
    `provision`, `list`. Destructive tools go through the client's normal permission prompts.
    **Agent discovery.** Decided 2026-11-02:
    - `hobo usage` prints the whole reference: every visible command's `--help` (generated by
      ArgumentParser from the same configurations, so it can't drift), then a conventions section
      (`--json` shapes, errors, exit status, the `vagrant` user, where VMs live, guest capacity).
      It's plain text and not agent-specific. Reference lives here and nowhere else.
    - A Claude Code skill teaches the CLI path. Its description triggers on testing or UI-testing in
      a clean VM; its body is workflow and rules only (the ephemeral session pattern, test inside
      the guest over SSH and never drive the host UI, `exec --gui` for Aqua, the 2-macOS-guest
      limit) and says "run `hobo usage`" for flags. MCP clients get the same guidance from the
      server's `instructions` field, built from the same text in `HoboCore` (`AgentGuidance`), so
      there is no MCP skill.
    - `hobo claude install [--project]` and `hobo claude uninstall [--project]` write or remove
      `~/.claude/skills/hobo/SKILL.md`, or `<git root>/.claude/skills/hobo/` with `--project` (an
      error outside a git repo). The text is embedded in the binary; the file carries a
      `hobo-version` frontmatter line. That line marks the file as hobo's: `install` overwrites it
      and `uninstall` removes the directory only when it's present, otherwise both refuse without
      `--force`. Re-running `install` refreshes it, and `make install` refreshes an existing global
      copy. The namespace is named for Claude rather than a generic `skill --target`: add a sibling
      namespace if another agent ever matters.
    - `usage` ships in M1; the skill, `hobo claude` and the shared text ship in M3 with `hobo mcp`,
      since the workflow they teach (ephemeral clones, `exec --gui`, `screenshot`) is M3's.
20. **Windows guests.** Windows 11 on Arm runs on the Virtualization framework like the others, so
    there is one engine and `config.json` doesn't name one. This replaces the plan of a QEMU engine
    (spike 2026-11-02), dropped 2026-11-05 once `spikes/windows-qemu/README.md` (findings 19 to 21)
    had Windows running on VZ, after [Mustafa Akın's post](https://mustafaakin.dev/blog/windows-on-tart/)
    named the two obstacles. Its fork of Tart is FSL-licensed, so nothing is copied from it.
    - **A private API, the main risk.** Windows' boot loader spins forever on one vCPU without PMU
      emulation, which VZ offers only through `VZGenericPlatformConfiguration`'s private
      `_setPerformanceMonitoringUnitEmulationEnabled:`. Hobo checks for the selector and fails with
      a clear error. A macOS release may remove it, which ends Windows guests until there's another
      way; Beads hobo-9ni rechecks on each release, with QEMU the fallback.
    - **A framebuffer driver of our own.** Windows Boot Manager needs a linear framebuffer, and VZ's
      GOP is Blt-only. `Firmware/WindowsBoot` holds a small UEFI driver and a loader, built from
      source by a SwiftPM build plugin with `clang` and `lld-link` (`brew install lld`), so no binary
      is in git. The driver registers itself as `Driver####` by a bare file path, so an installed
      disk needs no loader of its own but does need its NVRAM: `efi-vars.fd` is a platform file,
      which clones and snapshots copy.
    - **Install with no Setup.** `create` builds a raw disk image with a FAT32 partition (boot files)
      and an exFAT one (the whole ISO, which Setup looks for, then the answer file, drivers and guest
      files), attached as USB storage. Setup's windowsPE pass calls our `install.cmd`, which
      partitions the NVMe disk with Windows last (so `hobo set --disk` can grow it), applies the
      image with DISM, adds the virtio-win drivers (viogpudo, NetKVM, viorng, Balloon, viofs),
      runs `bcdboot` and powers off, leaving its result on the media. The next boot, without the
      media, runs specialize and OOBE, and `SetupComplete.cmd` runs `setup.ps1` as SYSTEM. OOBE then
      restarts the machine about a minute after the first logon, clearing the auto-login settings,
      so a startup task (`finish-setup.ps1`) restores them after that restart, enables sshd and
      restarts once more. SSH answering means it's done. A whole `hobo create` takes about 8 minutes and about 11 GB of ASIF; a clone then boots to SSH in about 11 s.
      The bypass of Setup is what makes it fast and is also why no TPM or Secure Boot is needed.
    - **Conventions.** `vagrant`/`vagrant` is an administrator, logged in at boot. The clock is
      `RealTimeIsUniversal`, since VZ's runs on UTC. Growing the disk restores the GPT disk GUID
      afterwards: `diskutil image resize` replaces it, and Windows' BCD names its disk by it. Win32-OpenSSH
      (pinned MSI) has PowerShell 5.1 as its shell, so what Hobo sends is PowerShell
      (`WindowsGuest`), kept free of double quotes, which sshd would have to escape; a command's argv
      travels as base64 of JSON. The ISO is the user's, and virtio-win, OpenSSH and WinFsp are
      pinned downloads through the image index.
    - **Display: 1024×768, fixed.** `viogpudo` offers its 1024×768 startup mode and the VM display's
      own size, and through the window only the first works. At 1920×1200, 2048×1280, 1600×1000 and
      1280×800, Windows accepts the mode and in-guest screenshots look right, but the window is
      96–99% black, with smeared fragments at some sizes (measured 2026-11-06; row pitch isn't the
      cause). So the VM's display is 1024×768, the driver doesn't follow the window, and the window
      scales it. Investigated 2026-11-07 (hobo-n64), comparing the window with in-guest captures:
      - What's lost is the driver's transfers to the host after a mode change from 1024×768, not
        the mode. Small updates arrive and big ones don't, so a static desktop stays black. At
        1024×769, 1024×800 and 1024×1000, any update touching row 768 or below is dropped and the
        rest arrives intact; at 1920×768 updates land shifted and striped, as if read with a
        1024-pixel stride. 1152×768 works fully; 1280×800, 1360×768, 1376×768 and 1920×1200 don't.
        It's the same after a reboot into the saved mode, since Windows commits 1024×768 first.
      - The likely cause is viogpudo's mode change (`SetCurrentMode`): it detaches and unrefs the
        resource still on the scanout, then creates the new size under the same resource ID (its
        allocator hands the freed ID straight back) and sets the scanout to it. Linux, which
        resizes fine on VZ, creates the new resource first and unrefs the old one after the
        scanout moves. Unconfirmed without a driver build.
      - Nothing outside the driver helps: older releases have the same sequence and ID reuse (back
        to 2023's source, so they weren't installed); `bcdedit highestmode`, clearing Windows'
        saved display configuration and the driver's registry settings don't change the first
        commit; and restarting the display device makes VZ stop the VM, as uninstalling the
        driver does. Beads hobo-y70 tracks patching viogpudo.
    - **Exec.** SSH runs in session 0, so `exec --gui` (and `screenshot`) go through a one-shot
      scheduled task in `vagrant`'s desktop session, with output tailed from files. UI driving
      uses Windows' built-in UI Automation from PowerShell, in the guest; no WinAppDriver, which
      Microsoft no longer develops. `[security]` and `[gui_testing]` are rejected, since no grant
      is needed; `privileged = false` too, since SSH gives an elevated token.
    - **Network after a restore.** The virtio NIC doesn't pass traffic after a VM restore, and
      nothing on the host side fixes it; `Restart-NetAdapter` in the guest does. A startup task
      (`network-watchdog.ps1`) pings the gateway every second and restarts the adapter when it stops
      answering. The first plan was to also compare wall-clock jumps; the ping alone proved enough,
      with SSH back about 10 s after a resume.
    - **Shares** use viofs and WinFsp: one virtio-fs tag, `hobo`, always attached, with each share a
      folder of `Z:\`. `read_only` holds.
    - **Licensing.** Microsoft's authorized way to virtualize Windows 11 on Arm on Apple Silicon is
      Parallels; check this before relying on Windows guests for work use. Hobo downloads no Windows.
21. **Linux guests.** Recipe `[source] image` + `sha256` (cloud image), set up by cloud-init on VZ;
    all lifecycle commands work the same. Decided 2026-11-02 and verified with Ubuntu 26.04:
    - Ubuntu LTS arm64 server cloud images are the verified distro. Nothing is Ubuntu-specific
      beyond `apt` in the conventions and cleanup, so other cloud-init images may work unverified.
    - The disk: Ubuntu ships compressed qcow2, which VZ can't attach. `qemu-img convert` (Homebrew
      `qemu`, for this tool only; `create` names it if missing) makes a raw image, `diskutil
      image create from --format ASIF` converts that (it stores the zeros too, so a 940 MB image
      becomes 3.6 GB until the guest TRIMs), and `diskutil image resize --image-only` grows it to the
      recipe's `disk`, moving the backup GPT; cloud-init's growpart grows the root filesystem on
      first boot. Each step takes seconds.
    - The bundle holds `disk.asif`, `efi-vars.fd` (`VZEFIVariableStore`) and
      `machine-identifier.bin` (`VZGenericMachineIdentifier`). The VM boots with `VZEFIBootLoader`,
      virtio-gpu at the same 1920×1200 (so `view` works), USB keyboard and pointer, and a virtio
      console written to the bundle's `console.log`; the conventions add `console=hvc0` to the
      kernel command line. The window sizes a Linux guest's display in points, not Retina pixels
      (`VMBundle.hiDPIDisplay`), since Linux doesn't scale its UI by itself; macOS keeps Retina.
      The text console runs at its 1920×1200 boot mode or at the window's size in points, so the
      conventions give it the kernel's built-in Terminus 10×18 font (`fbcon=font:TER10x18`, and
      console-setup's Terminus 10×20, which would otherwise load 8×16 back during boot): 8×16 was
      tiny at the first, 16×32 huge at the second. A failed create logs the console's tail, since the bundle goes with it.
      The disk uses `.cached` caching with `.fsync`, as Lima does, against ext4 corruption seen with
      VZ's default. TRIM works either way: `fstrim` returned 1 GB to the host about 30 s later.
    - Conventions come from a NoCloud seed, a `cidata` ISO (`hdiutil makehybrid`) attached
      read-only as a second disk for create's one boot only: `vagrant`/`vagrant` with passwordless
      sudo, both insecure keys, password SSH, no unattended upgrades, the VM's name as hostname,
      `vagrant`'s uid matching the host user's and the fstab line for shares (decision 9),
      and DHCP with `dhcp-identifier: mac`. That last is required: Ubuntu's default DUID client ID
      leaves bootpd's lease without the MAC Hobo looks it up by (and would be shared by a clone,
      since it comes from `/etc/machine-id`). The netplan matches the NIC by driver
      (`virtio_net`), not MAC, so a clone with a new MAC still gets a network, with nothing in the
      guest rewritten (cloud-init is off by then); `config.json` records `nicMatchedByDriver`. Linux
      VMs created before 2026-11-03 matched by MAC, and `clone` refuses them: create them again. Create waits for `cloud-init status
      --wait` over key SSH, runs the recipe's steps, and cleanup touches
      `/etc/cloud/cloud-init.disabled` and runs `fstrim`, so later boots and clones never re-run
      cloud-init. Recipe-supplied cloud-init user-data was rejected: `[[provision]]` is the one
      provisioning language. Boot to SSH takes about 10 s; a create, about a minute.
    - `[security]` and `[gui_testing]` are macOS-only and fail validation on a Linux recipe. Linux
      GUI testing (a desktop session, `exec --gui`, `screenshot`) waits for the macOS design
      (Beads hobo-938). Rosetta for Linux (the `VZLinuxRosettaDirectoryShare` + binfmt) is
      deferred (hobo-zdb): Apple has said general Rosetta winds down after macOS 27.

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
    - `HoboVM`: VM bundles (`VMBundle`: `MacVMBundle`, `LinuxVMBundle`, `WindowsVMBundle`, each
      building its VZ configuration), VM creation, the VM
      process (`VMRunner`), display
    - `HoboControl`: client ↔ VM-process socket protocol, and the client side of `start`/`stop` (`VMLifecycle`)
    - `HoboMCP`: MCP tools
    - `hobo`: CLI plus hidden `_vm-run` and `mcp` subcommands
    - `HoboVMTests` boot real VMs only with `HOBO_INTEGRATION=1`. The test runner can't hold the
      virtualization entitlement, so they drive the signed `hobo` binary (`make integration-test`).
      There is no CI; GitHub is a backup.
24. **Repo.** `ggal625/hobo`, private, Apache-2.0, `main`.
25. **Naming.** "Hobo" plays on "Vagrant". The hobo-and-trains metaphor (Boxcar, roundhouse,
    depot) was dropped on 2026-11-01: the recipe is plain `Hobo.toml`.
26. **Logo.** A bindle, a stick with a tied red bandana bag, on a cream macOS icon tile (decided
    2026-11-03). `assets/icon.svg` is the master and `assets/icon-small.svg` the simplified drawing
    for 16-32 px; `swift assets/render.swift` regenerates everything else from them. `assets/Hobo.icns`
    is for the planned GUI wrapper; nothing uses it yet, and the bindle is that app's icon alone.
    **VM icons.** Each VM window has its own icon, to find it among several in the Dock and ⌘Tab and to
    tell it from the GUI app (decided 2026-11-04): a hobo sign in chalk on a dark tile, with the VM's
    name in white under it. A SHA-256 of the name picks one of 24 signs and, from separate bits, one of
    8 colors, so a VM's icon never changes and needs no state, and a clone gets its own. Two VMs can
    share a sign or a color, and the name settles it. Long names shrink, then lose their middle, since
    clones differ only in their last characters. The binary isn't an app bundle and `make install` copies
    only the binary, so `HoboVM` compiles in the signs (`.embedInCode`, from `assets/draw_signs.py`).
    `VMIcon` draws the icon, and `VMWindow` sets it right after the process turns regular and appears
    in the Dock (the Dock ignores one set earlier). The name stays even though it's unreadable in a
    small Dock: ⌘Tab shows icons at about 128 pt, where it reads well, and a process has one image, so
    the two can't differ (2026-11-04: of an image's sizes the Dock shows only the largest, and
    `NSDockTile`'s custom view changes ⌘Tab as well). The drawings are our own, and whether hobos ever
    used these signs is doubtful, so they aren't presented as history.

## Milestones

The 2026-11-01 pivot removed `hobo box build/validate-recipe`, packaging, `BoxMetadata`, roundhouse
checkpoints and the project-scoped Boxcar (`[[machine]]`, `[defaults]`, `forwarded_port`, `run`).
`Recipe` is the `Hobo.toml` parser (no `name`/`version`) and `BoxBuilder` became `VMCreator`, which
builds in a given directory; `ImageIndex` (the `~/Downloads` + `images.json` index) replaced `Depot`.

- **M0, skeleton:** done.
- **M1, a VM you live in:** `init`, `create`, `list`, `start` (headless under launchd via
  `_vm-run`), `stop`, `ssh`, `exec`, `cp`, `ip`, `view`, `delete`, `rename`, `set`, `provision`,
  `usage`.
- **M2, experiments:** `clone`, `--ephemeral`, `suspend`/resume, live and stopped snapshots,
  disk usage in `list` (it reports snapshot sizes, so it follows them).
- **M3, agents:** leases, `[gui_testing]`, `exec --gui`, `screenshot`, `hobo mcp`, the Claude
  skill and `hobo claude install|uninstall`.
- **M4, Linux guests:** done (2026-11-02): `[source] image`, cloud-init conventions, `images`/`init --os linux`.
- **M5, Windows guests:** on VZ (decision 20): `[source] iso`, `init --os windows`, install with our
  own WinPE script, `exec --gui` through a scheduled task, UI Automation.
- **Later:** see Beads (`bd list --status deferred`).

## Comparison with Tart and Lume

Both are Swift CLIs on the Virtualization framework with named VMs, so the core overlaps. Compiled
2026-11-01 from knowledge as of mid-2026; re-check before relying on a detail.

| | Tart (Cirrus Labs) | Lume (trycua/cua) | Hobo |
|---|---|---|---|
| Focus | CI fleets (Orchard, Cirrus Runners) | computer-use agents (Cua) | personal VMs, cross-platform app testing, agents |
| Getting a VM | clone a prebuilt OCI image (e.g. macOS + Xcode) | `lume pull` an OCI image | full install from a recipe |
| Image building | Packer plugin; macOS setup types `boot_command` keys over VNC | unattended presets, also scripting Setup Assistant over VNC | `VZMacGuestProvisioningOptions`, no UI scripting |
| Sharing | push/pull OCI | push/pull OCI | the recipe only (decision 2) |
| Storage | `~/.tart/` (hidden) | `~/.lume/`, configurable | `~/Hobo/<name>.hobovm`, visible |
| Process model | `tart run` in the foreground | `lume serve` HTTP daemon | one `_vm-run` per VM under launchd, no daemon |
| Display | window or VNC | VNC | headless `.accessory`, `view` on demand, no VNC |
| Guest channel | SSH; `tart exec` via a vsock guest agent | SSH; Cua computer server | SSH; vsock agent deferred |
| Snapshots | none (clone instead) | none known | live and stopped |
| Ephemeral VMs | left to Orchard/CI | Cua sandboxes | `--ephemeral` + idle-timeout leases |
| Networking | NAT, bridged, Softnet isolation | NAT, bridged | shared NAT only |
| MCP | no | yes | `hobo mcp` |
| Windows | no | no | yes, through a private VZ setting (M5) |
| Host | macOS 13+ | macOS 13+ | macOS 27+ |
| Licence | Fair Source | MIT | Apache-2.0 |

**Where Hobo differs on purpose.** Unattended macOS setup through Apple's API instead of VNC
keystroke scripts that break each macOS release (the reason for the macOS 27 floor); live
snapshots; a launchd-owned lifecycle that never takes focus; agents driving the UI from inside the
guest with real automation APIs (`[gui_testing]`, `exec --gui`, XCUITest) rather than Lume's
host-side screenshots and clicks; Windows guests; visible storage.

**What Hobo gives up.** Time to the first VM: a Tart user runs macOS + Xcode from a prebuilt image
in minutes, while every Hobo user downloads, installs and provisions (accepted in decision 2; an
optional bundle push/pull could be added later without reviving boxes). Older hosts. Network
isolation (Softnet) and bridged mode. A guest agent. The maturity of tools proven at scale.

**To borrow.** Tart runs clones of one macOS VM side by side. Its `clone` regenerates the MAC,
and the machine identifier only for Linux guests; `tart set --random-serial` gives a macOS VM a new
identifier and keeps its aux storage, which is what Hobo's `clone` does (decision 12).

## Prior art

- [Tart](https://github.com/cirruslabs/tart): Swift VZ CLI with named VMs; reference for macOS installs.
- [Lume](https://github.com/trycua/cua): Swift VZ CLI and daemon behind the Cua computer-use agents.
- [VirtualBuddy](https://github.com/insidegui/VirtualBuddy), [Mist](https://github.com/ninxsoft/Mist):
  macOS guest GUI and IPSW/installer fetching.
- [UTM](https://github.com/utmapp/UTM): QEMU + HVF for Windows on Arm.
- [Mech](https://mechboxes.github.io/mech/docs/welcome/) and Vagrant: recipe and guest conventions.
- Howard Oakley's [Virtualisation on Apple silicon](https://eclecticlight.co/virtualisation-on-apple-silicon/)
  articles: guest limits, machine identity, shares, ASIF, version gates (reviewed 2026-11-01).
- WWDC26 session 224, "Expand the capabilities of your Virtualization app" (macOS 27 APIs).
