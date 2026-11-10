# Hobo design record

Hobo is a first-class CLI for virtual machines on Apple Silicon Macs: a command-line replacement for
VirtualBuddy, Parallels and VMware Fusion, built on Apple's Virtualization framework. VMs are built from recipes and every guest
gets the same conventions (a `hobo` user, SSH with a well-known key). Decisions
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
4. **Commands.** VM-centric verbs:
   `init [--os macos|linux] [--server] [<build-or-version>] [-o recipe] [--force]`,
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
   `ubuntu-desktop-minimal`, has GDM log `hobo` in at boot, masks GNOME's welcome wizards
   (`gnome-initial-setup`'s first-login and post-upgrade user services), turns off screen
   blanking and lock, and turns accessibility on for GUI testing (decision 21); `--server` leaves
   it out.
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
   owner, so `hobo` is created with the host user's uid and shared files are its own; the gid
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
   `diskGrowPending`. At the next boot the VM process runs the guest step once the agent answers, against
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
       (`hobo`/`hobo`, auto-login, Remote Login);
    3. conventions, over password SSH: passwordless sudo, hobo's own insecure ed25519 key (2026-11-08) in
       `authorized_keys`, no sleep/screensaver, no automatic updates, and hobo-agent's stub with its
       LaunchDaemon (decision 15). The insecure key stays: a
       per-VM key is deferred (decided 2026-11-01, Beads hobo-cip). The boot then waits (up to
       5 min) for the first auto-login to finish, signalled by the user's tccd opening its TCC.db:
       SSH answers well before then, and shutting down early left the next boot, where recipe steps
       run, with no GUI session at all (2026-11-02, macOS 27.2);
    4. `[security]` if it turns SIP off (decision 17): the one step that needs a person, in
       recoveryOS, then a boot to check it and set the AMFI boot-arg;
    5. TCC grants written from the host into the stopped guest's Data volume (decision 17): Full
       Disk Access for hobo-agent always, and `[gui_testing]`'s if enabled, checked through the
       agent on the next boot, where everything from here on goes through the agent;
    6. recipe `[[provision]]` steps (shell inline/path with `privileged` and `env`, and file), run
       once each. `hobo provision <name> [recipe]` runs a recipe's steps again, in
       order, on a running VM, in its VM process (decision 15): for iterating on steps without a
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
    runs again, since the disk then moves on, and sets the guest's clock through the guest channel (checked
    2026-11-02: a resumed guest is behind by the whole suspension). A macOS guest tries `sntp`, else
    takes the host's time; a Linux guest takes the host's time (`date -s @<epoch>`: Ubuntu 26.04's
    uutils `date` rejects the BSD form) and chrony refines it. A macOS guest's shares are also
    remounted through the guest channel: VZ's virtio-fs device restarts on the host, and its old handles fail lookups
    with ENOENT until the mount is replaced (files a guest process had open in a share are lost). A
    Linux guest's mount keeps working across the restore, but its lookups stay cached for a few
    seconds of guest time, which stood still: a file the host added during the suspension isn't
    found until then. Over SSH that time had passed before anything ran; the agent answers within
    a second, so the guest drops its dentry cache instead (`drop_caches`, checked 2026-11-08).
    Resume took about
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
    still, is then set through the guest channel, as a resume does, though its shares need no remount, since the
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
      waits for it. A forced stop powers the VM off at once, so a hung save can't keep it up, then
      gives the save up to 60 s before the process exits (hobo-rok): VZ's VM service finishes a save
      it was writing and holds the bundle's files until then, so an immediate `start` would fail to
      lock `aux.img`. A save that completes is kept; the disk hasn't changed since the pause.
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
15. **Guest channel.** hobo-agent over virtio-vsock for everything Hobo itself does in a guest, and
    SSH for people (`hobo ssh`, raw `ssh`) and for the steps of a create before the agent is in
    place (a macOS create's conventions step). SSH is the `hobo` user with
    hobo's insecure key; host keys aren't checked, since IPs are reused across VMs and rebuilds. `ssh`/`scp` are spawned with responsibility disclaimed
    (`responsibility_spawnattrs_setdisclaim`, as terminals do), so macOS's Local Network privacy
    sees Apple's `ssh` rather than hobo (decided 2026-11-02): the VM process runs under launchd as
    its own app, an ad-hoc build is a new app on every rebuild, and each one put up an Allow dialog
    that silently failed every SSH probe until someone clicked it. `hobo exec`/`cp`/`screenshot` go through the
    control socket, which renews leases (decision 18); agents should use them rather than raw `ssh`.
    **hobo-agent** (decided 2026-11-08, hobo-yis), replacing SSH for Hobo's own traffic:
    - Why: no network in the way (no DHCP lease to find, no Local Network prompt, a guest with its
      NIC down or wedged still answers, as Windows' does after a restore), readiness that is the
      agent answering rather than SSH polling, and one way into the desktop session per guest.
    - One Go program (`Agent/`), with no dependencies: it builds for each guest from the Mac with
      `GOOS`/`GOARCH` alone, in SwiftPM's sandbox (`HoboAgentPlugin`, like the Windows boot driver),
      and the binaries are resources of `HoboVM`, in Hobo.app's `Contents/Resources` (`Payloads`,
      decision 22). Building needs `brew install go`.
    - **The stub.** Create installs the agent's binary in the guest, run at boot by the guest's
      service manager as `hobo-agent stub`. The stub fetches the agent from the host on every boot
      (guest port → host port 1100: `{"fetch":"linux-arm64"}`, answered `{"size":n}` and the bytes)
      and execs it, so the agent in a guest is always the hobo running it, clones and old snapshots
      included, with no update step. That exchange is frozen: every stub installed must keep
      working. A stub could have been a script, but no guest has a tool that opens a vsock socket.
      Linux's is a systemd unit from the cloud-init seed (decision 21); macOS's is a LaunchDaemon
      (`com.hobo.agent`, logging to `/var/log/hobo-agent.log`) that create's conventions step
      installs over SSH; Windows' is a startup task as SYSTEM (`hobo-agent`, logging to
      `C:\ProgramData\Hobo\hobo-agent.log`), from the install media (decision 20). A stub that
      fails to fetch retries every second. Windows has no `exec`, so its stub runs the agent as a
      child, and fetches it again if it exits.
    - **vsock in each guest.** Linux and macOS have `AF_VSOCK` in the kernel; the agent calls
      `socket`/`bind`/`connect` itself, since Go's `syscall` has no sockaddr for it (and the agent
      takes no dependencies). Windows gets it from virtio-win's viosock driver, whose .inf also
      installs a Winsock provider: its address family is whatever the driver answers (an IOCTL),
      and the agent calls ws2_32 directly (2026-11-08, virtio-win 0.1.302).
    - **Requests.** The agent runs as root and listens on guest port 1101, accepting only the
      host's CID (2), so a guest process can't reach a root agent over vsock loopback. There is
      no other authentication: only the VM process can reach the device, and `hobo` has
      passwordless sudo anyway. Each request is a connection, opened by the host: one line of
      JSON (`ping`, `exec`, `put`, `get`), then frames both ways (a type byte, a 4-byte length, the
      bytes: stdout, stderr, tar data, the exit status, or why it couldn't run). Frames rather than
      the control socket's JSON lines, so output and copies go unencoded. Closing the connection
      cancels a request, and the agent kills the command's process group (`SIGTERM`, then
      `SIGKILL` after 5 s).
    - `exec` runs a command line in `hobo`'s login shell, as sshd does, with a login's
      environment (`HOME`, `USER`, `SHELL`, a system `PATH`, and on Linux the user's runtime
      directory), so the commands written for SSH (`sudo -n …`, the GUI scripts) run unchanged.
      On macOS the command goes through `launchctl asuser` into `hobo`'s launchd bootstrap (the
      agent starts it as root, then becomes `hobo`): a daemon's children are in the System
      bootstrap, where `nohup` fails ("can't detach from console") among other things. SSH logins
      got a Background session from pam_launchd, which has no public API, so plain `exec` is in
      the desktop's bootstrap (Aqua) once `hobo` is logged in, as `--gui` is; `--gui` still
      waits for that login (2026-11-08, macOS 27.2).
      On Windows the agent is a SYSTEM process in session 0, so it starts commands itself
      (checked 2026-11-08 on 11 build 26300): plain `exec` as a logon of `hobo`'s own, with the
      convention's password, elevated (UAC's linked token), through `CreateProcessWithTokenW`, whose
      secondary logon service loads the profile and gives the logon session 0's `winsta0\default`
      (left to inherit the task's window station, commands die with `STATUS_DLL_INIT_FAILED`).
      `--gui` is a `desktop` flag on the request: the console user's token (`WTSQueryUserToken`,
      once Explorer runs in that session, up to 60 s, then 125), elevated, through
      `CreateProcessAsUser` on `winsta0\default`, since `CreateProcessWithTokenW` puts a process in
      session 0 whatever its token's session. Either way the command is `exec.ps1` in PowerShell, as
      sshd ran it, starts suspended in a job object of its own, which a cancel terminates, and has
      no console window. This replaced a scheduled task per `--gui` command with its output tailed
      from files.
    - `cp` is a tar stream: the host's `tar` (no AppleDouble files or extended attributes) makes
      or extracts it, and the agent runs itself as `hobo` to extract or make the guest's side,
      so files belong to `hobo` and relative paths are from its home. Both sides give scp's
      meaning: into a directory that exists, or a single source becomes the destination; a
      directory without `-r`, or a missing source, is reported and fails the copy.
    - `hobo provision` runs in the VM process (a `provision` request, streaming progress and the
      steps' output), so its steps go through the agent too and hold an ephemeral VM's idle
      timeout like any request.
    - Readiness is a `ping` that answers, polled once a second; the guest refuses the connection
      until the agent listens. The DHCP lease is still read, for `hobo ip` and `hobo ssh`, but
      nothing waits for it beyond a few seconds so `start` can print it. A macOS guest's agent
      answers before its network and sshd do, so `hobo ssh` waits (up to a minute) for sshd.
    - Alternatives rejected: an agent per guest OS (three codebases); updating an installed agent
      by version handshake (atomic replace and restart under three service managers, and a broken
      agent can lock itself out); a second, per-user agent for the desktop session (each OS has a
      supported way for root to start a process in it); a fallback to SSH when the agent doesn't
      answer, which would hide its failures.

    Before hobo-agent (decided 2026-11-01), replaced by the above:
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
      someone is watching. A macOS guest has no mode under 1024×640 points, so its window can't be
      made smaller than that (decided 2026-11-08: below it the guest stayed at 1024×640 and the
      window scaled it down). `[gui_testing]` may turn resizing off if that matters. Windows guests
      follow it only with `[windows] resizable_display`; otherwise the display is a fixed 1024×768
      and the window scales it (decision 20).
    Agents drive the UI **inside the guest**:
    - Commands from hobo-agent (and from SSH) are outside the GUI session's own TCC approvals, and
      TCC blocks them from Accessibility and Screen Recording, so recipe `[gui_testing]` (opt-in)
      pre-grants them. **SIP stays on** (decided
      2026-11-01, replacing "boot to recovery and disable SIP", which needed keystroke scripting of
      recoveryOS): with the VM stopped after the conventions boot, create attaches the ASIF, mounts
      the guest's Data volume (unencrypted, and a regular user's mount ignores ownership, so no root;
      the host's SIP doesn't cover a foreign volume) and writes the rows itself. Inside the guest
      neither database is writable, even by root with Full Disk Access. Verified on a macOS 27.2
      guest (2026-11-01):
      - TCC attributes everything the agent runs to the path launchd started, the stub
        `/usr/local/libexec/hobo-agent`, not the agent it execs (tccd logs it as the request's
        subject; 2026-11-08, macOS 27.2), so its rows are what count, also through `launchctl
        asuser`. Over SSH that was `/usr/libexec/sshd-keygen-wrapper`, which `hobo ssh` users no
        longer get grants for. The defaults also grant `osascript`, `screencapture` and Terminal.
      - Every macOS create grants the agent Full Disk Access (`kTCCServiceSystemPolicyAllFiles`, in
        the system TCC.db): Remote Login gives sshd it by default, and without it the agent can't
        write other apps' containers (replayd's, below) or read much of `~/Library`. `[gui_testing] allow = [...]` adds clients: an absolute path
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
      - Create then checks through the agent, before the provision steps, that Accessibility
        (`AXIsProcessTrusted`), Screen Recording (`CGPreflightScreenCaptureAccess`; `screencapture`
        succeeds without the grant, leaving windows out) and System Events scripting work, and
        fails otherwise.
      - The grants don't stop replayd's own approval dialog ("requesting to bypass the system private
        window picker"): the first capture by a client with no record raises it, from plain `exec` or
        `--gui`, and it blocks the guest's UI and shows in later screenshots. So create then seeds
        that record through the agent, before anything captures: `ScreenCaptureApprovals.plist` in the
        user's replayd group container, with its alert dates in 2099, for the agent's stub path only,
        which everything the agent runs counts as (decided 2026-11-05, for `sshd-keygen-wrapper`). An app started on its own may count
        separately and still get the dialog when it captures. Checked on 27.2 for 5 captures over
        45 s; whether the record lasts for weeks or across macOS updates is unknown. A VM built
        before this needs rebuilding.
      - On a VM with the grants, `screencapture` (windows included), `open` and System Events
        scripting all work from plain `exec`, in the same way as from `--gui` (checked 2026-11-05 on
        27.2, over SSH's Background session; plain `exec` is now in the desktop's bootstrap anyway). Automation of
        Finder times out from both, since only System Events is granted.
    - Recipe `[security] sip = false` (and `amfi = false`, which needs it) turns SIP and AMFI off,
      for testing ad-hoc signed binaries that claim restricted entitlements (decided 2026-11-02;
      `[gui_testing]` doesn't need it). Checked on a macOS 27.2 guest (2026-11-02): `csrutil disable`
      works in a VZ guest's recoveryOS (Options → Continue, sometimes a language picker, no user
      picker seen, then Utilities › Terminal; it asks y/n, then hobo's password); paste from the host doesn't reach recoveryOS; once SIP is
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
    - `exec --gui` runs the command in the `hobo` user's Aqua session: `sudo launchctl asuser
      <uid> sudo -u hobo env PATH=… <cmd>` (`asuser` needs root; the inner `sudo` makes it the user
      again and resets the environment, hence `PATH`). It's a `gui` field on the `exec` request, so
      streaming, exit status, cancelling and leases are `exec`'s; killing the process group reaches
      through both `sudo`s (checked 2026-11-05 on 27.2). Auto-login can finish after the agent answers, so
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
    - Linux guests have their own `exec --gui` and `screenshot` (decision 21), and Windows guests
      theirs (decision 20).
    - A host-side framebuffer screenshot for wedged guests is deferred.
    - **`hobo ui <vm> <command>`** drives a macOS guest's apps through accessibility (decided
      2026-11-08; the interview is `designs/hobo-ui.md`). It replaces what agents improvised:
      System Events' `click at` returns without clicking in a guest, the guest has no compiler for
      a CGEvent tool, coordinates read off screenshots go stale, and waits were sleeps.
      - `hobo-ui`, a Swift executable in this package (pure logic in `HoboUICore`, unit-tested on
        synthetic trees), a resource of `HoboVM` by `HoboUIPlugin`: host and guest are both arm64
        macOS, so the tool SwiftPM builds for the host is the guest's binary. Not in the Go agent,
        which would need cgo for AX and CGEvent. It ships in Hobo.app with the other payloads
        (decision 22).
      - Delivery: a `ui` control request runs `exec --gui` of `hobo-ui` with a `tool` field, and the
        agent fetches the tool on first use each boot (`Agent/tool.go`), over the stub's fetch port
        by a name no stub sends (`ui-darwin-arm64`), into its run directory, root's, which a boot
        clears. So it always matches the hobo running the VM, clones and snapshots included, and
        costs nothing on VMs that never use it. TCC counts it as the agent's stub, which
        `[gui_testing]` grants; without them it fails saying so. macOS only: Linux (AT-SPI) and
        Windows (UIA) backends would take the same commands.
      - `hobo` parses the command with `HoboUI`'s definitions (for `--help` and usage errors), then
        sends the arguments unchanged; `hobo-ui` parses them again. One definition, two parsers.
      - Refs: `snapshot` gives each shown element a ref (`e12`) kept in a file per app (by bundle
        ID) in the agent's run directory, mapping it to a locator: the path from the app of (role,
        name, index among siblings with the same role and name), where the name is the identifier,
        else the title, else the label, never the value. A ref keeps its number while its locator
        matches, across snapshots and relaunches; a command walks the locator again and fails as
        stale if nothing is there. One-shot processes, no daemon in the guest.
      - Output is a compact text tree (Playwright's aria snapshots), which agents read for a
        fraction of JSON's tokens; `--json` is for scripts. Unnamed layout groups fold away; without
        `--all`, elements outside their scroll area, zero-size ones and children past 50 are counted.
        Coordinates in and out are screenshot pixels, so a point read off a `screenshot` is the one
        to click, with the VM's window open at Retina or not.
      - `click`, `drag`, `scroll`, `type` and `key` are real CGEvents, so focus, hit-testing and
        the responder chain behave as for a person: an agent testing Candela found that bare-key
        shortcuts didn't fire while a collection view had focus, which AXPress would have hidden.
        A click by ref first brings the app forward through AX and hit-tests the point, failing
        with what covers the element. `click --press` and `menu` use AXPress; `menu` refuses a
        disabled item and lists a menu's items with shortcuts in `key`'s syntax.
      - Calls take about 0.3 s over the agent (2026-11-08, macOS 27.2), so there is no batch
        command (`run`); hobo-cg1 revisits it. No launch/quit: `exec -- open -n --env … --args …`
        does that, and `wait --app` waits for a window. MCP tools wait for `hobo mcp` (hobo-i2j).
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
      (`--json` shapes, errors, exit status, the `hobo` user, where VMs live, guest capacity).
      It's plain text and not agent-specific. Reference lives here and nowhere else.
    - A Claude Code skill teaches the CLI path. Its description triggers on testing or UI-testing in
      a clean VM; its body is workflow and rules only (the ephemeral session pattern, test inside
      the guest through `hobo exec` and never drive the host UI, `exec --gui` for Aqua, the 2-macOS-guest
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
      image with DISM, adds the virtio-win drivers (viogpudo, NetKVM, viorng, Balloon, viofs,
      viosock),
      runs `bcdboot` and powers off, leaving its result on the media. The next boot, without the
      media, runs specialize and OOBE, and `SetupComplete.cmd` runs `setup.ps1` as SYSTEM. OOBE runs
      in a session of its own temporary user, `defaultuser0`: it restarts the machine about a minute
      after the first logon, then logs that user on again to finish, clearing the auto-login settings.
      A startup task (`finish-setup.ps1`) waits for that second session to end (up to 5 minutes),
      restores them, registers hobo-agent's startup task, enables sshd and restarts once more. The
      agent answering means it's done. Restarting without waiting raced OOBE by seconds, and when
      OOBE lost, it finished on the VM's first boot after create, logging hobo off (hobo-2o4).
      `OOBEInProgress` and the other Setup flags stay 0 throughout, so they can't be waited on. A
      whole `hobo create` takes about 8 minutes and about 11 GB of ASIF; a stopped VM then starts in
      about 16 s.
      The bypass of Setup is what makes it fast and is also why no TPM or Secure Boot is needed.
    - **Conventions.** `hobo`/`hobo` is an administrator, logged in at boot. The clock is
      `RealTimeIsUniversal`, since VZ's runs on UTC. Growing the disk restores the GPT disk GUID
      afterwards: `diskutil image resize` replaces it, and Windows' BCD names its disk by it. What
      Hobo sends is PowerShell (`WindowsGuest`), which the agent runs as sshd runs its shell
      (Win32-OpenSSH, a pinned MSI, with PowerShell 5.1 as `DefaultShell`), kept free of double
      quotes, which would need escaping on their way into PowerShell's command line; a command's
      argv travels as base64 of JSON. The ISO is the user's, and virtio-win, OpenSSH and WinFsp are
      pinned downloads through the image index.
    - **Display: 1024×768 unless the recipe opts in to a patched driver.** virtio-win's `viogpudo`
      can't leave its 1024×768 startup mode under VZ, so by default the VM's display is 1024×768,
      the driver doesn't follow the window, and the window scales it. `[windows] resizable_display
      = true` installs a patched viogpudo instead: the display is 1920×1200 like other guests', and
      follows the window. The cost is test signing (decided 2026-11-07, hobo-y70):
      - **The cause.** viogpudo's mode change (`SetCurrentMode`) detaches and unrefs the resource
        still on the scanout, then creates the new one. VZ refuses `RESOURCE_UNREF` for a resource
        on a scanout (`ERR_INVALID_PARAMETER`); the driver ignores responses and hands the ID back
        to its allocator, so the new resource's `CREATE_2D` fails (`ERR_INVALID_RESOURCE_ID`), as do
        `SET_SCANOUT` and every transfer after it. The host keeps the 1024×768 resource: at
        1920×1200 the window is almost black, at 1024×1000 rows past 768 are dropped, at 1920×768
        updates land with a 1024-pixel stride. Found with the driver's WPP trace; the window
        measurements are from hobo-n64 (2026-11-06/07).
      - **The fix**, Linux's order: create the new resource under a fresh ID and set the scanout to
        it, then unref the old one. Holding the old ID back without reordering isn't enough: VZ
        still refuses the unref, and it only looks right while two IDs alternate. Upstream PR
        virtio-win/kvm-guest-drivers-windows#1717, from the `vz-scanout` branch of a fork
        (`ggal625/kvm-guest-drivers-windows`), whose release `viogpudo-vz-1` Hobo pins: the .inf,
        .sys and .cat, built with the 26H1 EWDK in a Windows VM and signed with upstream's own test
        certificate. Nothing on the Mac can build it, so it's a pinned download, not source in git.
      - **Test signing.** A test-signed driver loads only with `testsigning` on, so `install.cmd`
        adds it with `DISM /ForceUnsigned` (in place of virtio-win's viogpudo, which would outrank
        it) and turns test signing on in the offline BCD. The guest trusts no certificate: test
        mode loads the driver without it. The cost is a "Test Mode" watermark on the desktop, in
        screenshots too, and a guest that loads any test-signed driver, which software checking
        code integrity may notice; hence opt-in. Once a signed virtio-win release has the fix, the
        default becomes resizable and the option goes (Beads tracks this).
      - **Following the window** (2026-11-08, hobo-s1u). VZ reconfigures the display, and the
        driver takes the new size as its custom mode and pulses a named event
        (`VioGpuResolutionEvent<id>`), but Windows switches modes only when something in the desktop
        session asks. virtio-win's helper (`vgpusrv` starting `viogpuap.exe` in the session) never
        does here: its search for the adapter stops at the first display device that isn't the
        virtio GPU, and under VZ the first is Microsoft Basic Display (the session lists it before
        the virtio GPU, which is the primary). Fixing that would mean a second binary built in a
        Windows VM, so Hobo has its own: `display-follower.ps1`, PowerShell with a little C#, which
        does what `viogpuap` does (the driver escape for its ID, which also creates the event; a
        wait on the event; the escape for the custom mode; `ChangeDisplaySettingsEx`) for every
        attached virtio GPU, checking every 2 s as well since the event is only pulsed. A logon task
        (`hobo-display-follower`, as `hobo`, interactive) runs it, so it follows from the first
        boot after create. Create also runs it once (`-Once`) through `exec --gui`: Windows starts
        at 1024×768 whatever the display offers, and the size it sets is saved, so later boots
        start at it.
      - Nothing outside the driver helped (hobo-n64): older releases have the same sequence; `bcdedit
        highestmode`, clearing Windows' saved display configuration and the driver's registry
        settings don't change the first commit; and restarting the display device makes VZ stop the
        VM, as uninstalling the driver does, so the driver goes in at create.
    - **Exec.** hobo-agent starts plain `exec` in session 0 and `exec --gui` (and `screenshot`) in
      `hobo`'s desktop session (decision 15). UI driving uses Windows' built-in UI Automation
      from PowerShell, in the guest; no WinAppDriver, which Microsoft no longer develops.
      `[security]` and `[gui_testing]` are rejected, since no grant is needed; `privileged = false`
      too, since the agent runs everything elevated, as SSH did.
    - **Network after a restore.** The virtio NIC doesn't pass traffic after a VM restore, and
      nothing on the host side fixes it; `Restart-NetAdapter` in the guest does. A startup task
      (`network-watchdog.ps1`) pings the gateway every second and restarts the adapter when it stops
      answering. The first plan was to also compare wall-clock jumps; the ping alone proved enough,
      with the network back about 10 s after a resume (which the agent, over vsock, never needed).
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
      read-only as a second disk for create's one boot only: `hobo`/`hobo` with passwordless
      sudo, the insecure key, password SSH, no unattended upgrades, the VM's name as hostname,
      `hobo`'s uid matching the host user's and the fstab line for shares (decision 9),
      and DHCP with `dhcp-identifier: mac`. That last is required: Ubuntu's default DUID client ID
      leaves bootpd's lease without the MAC Hobo looks it up by (and would be shared by a clone,
      since it comes from `/etc/machine-id`). The netplan matches the NIC by driver
      (`virtio_net`), not MAC, so a clone with a new MAC still gets a network, with nothing in the
      guest rewritten (cloud-init is off by then); `config.json` records `nicMatchedByDriver`. Linux
      VMs created before 2026-11-03 matched by MAC, and `clone` refuses them: create them again. The
      seed also writes hobo-agent's stub (`/usr/local/libexec/hobo-agent`, base64 in `write_files`)
      and its systemd unit, started from `runcmd`, so the whole create goes through the agent
      (decision 15). Create waits for `cloud-init status
      --wait` through it, runs the recipe's steps, and cleanup touches
      `/etc/cloud/cloud-init.disabled` and runs `fstrim`, so later boots and clones never re-run
      cloud-init. Recipe-supplied cloud-init user-data was rejected: `[[provision]]` is the one
      provisioning language. Boot to the agent answering takes about 8 s; a create, about 30 s.
    - `[security]` and `[gui_testing]` are macOS-only and fail validation on a Linux recipe: GUI
      testing needs no grant there, only the desktop `init --os linux` writes a step for (decision
      8), so `--server` is the only opt-out. Decided 2026-11-07 and verified on Ubuntu 26.04
      (GNOME 50, Wayland only):
      - `exec --gui` runs as `hobo` straight from its login shell, with no `sudo`, so streaming,
        exit status and cancelling (a kill of the process group, which reaches the app) are
        `exec`'s. It waits up to 60 s, like macOS, for `loginctl` to give `hobo` a graphical
        session and for the systemd user manager to hold its display, then imports that manager's
        environment, which GNOME fills and apps launched from the desktop get (`WAYLAND_DISPLAY`,
        `DISPLAY`, `XAUTHORITY`, `XDG_SESSION_TYPE=wayland` over SSH's `tty`, the accessibility
        variables), keeping the login's `PATH`. With no display manager enabled (`--server`) it exits 125
        at once rather than waiting.
      - `screenshot` goes through the desktop portal's Screenshot API (`interactive=false`), from a
        `python3` script using GLib, since GNOME's own Shell screenshot API refuses callers it
        doesn't know and there is no X session. Unsandboxed callers are app ID `""`, and without
        that ID's `screenshot` permission GNOME asks with a dialog that stays up, with later
        requests waiting behind it. So the script grants it first, each time, through the
        permission store, which covers clones and a grant someone withdrew with no recipe key. The
        portal saves to `~/Pictures`; the script sends the file to stdout and removes it.
      - UI driving is AT-SPI from Python (`gir1.2-atspi-2.0`), in the guest: walking trees, actions,
        and setting and reading text all work. Its synthetic key and mouse events don't reach
        Wayland apps, and raw input (`ydotool` via `/dev/uinput`) was left out. The desktop step
        sets `toolkit-accessibility` in the system dconf database and locks it, since `hobo`'s
        own settings end up holding `false`; Chromium and Electron expose their trees only with
        it on.
    - Rosetta for Linux (the `VZLinuxRosettaDirectoryShare` + binfmt) is
      deferred (hobo-zdb): Apple has said general Rosetta winds down after macOS 27.

### Engineering

22. **Install: Hobo.app.** (Decided 2026-11-08; the interview is `designs/hobo-app.md`.) Hobo
    ships as one app bundle: the GUI is `Contents/MacOS/Hobo`, the CLI `Contents/Helpers/hobo`, and
    the payloads (the agents, `hobo-ui`, the Windows boot driver and scripts, the VM icons' signs)
    are files in `Contents/Resources`. The CLI sits outside `MacOS` so that VM processes, which run
    it, aren't taken for the app (each has its own Dock icon), and so `Hobo` and `hobo` can't collide
    on a case-insensitive volume. `Payloads` reads the files from there, or from SwiftPM's resource
    bundle in a bare build (`swift build`, `swift test`); not through `Bundle.module`, whose accessor
    looks at the top of `Hobo.app`, where code signing allows nothing. `make app` assembles the
    bundle from SwiftPM's products (there is no Xcode project). `make sign` signs the CLI, then the
    app, with `entitlements.plist` (ad-hoc by default, `HOBO_SIGN_IDENTITY` for Developer ID).
    `make install` copies it to `/Applications` and links `/usr/local/bin/hobo` to the CLI, as the
    app's **Install Command Line Tool…** does with an administrator prompt (`osascript`, no
    privileged helper). A VM's launchd plist runs the CLI of the build that started it
    (`HoboInstall.cli`, symlinks resolved; from the GUI, its `Helpers/hobo`), so client and VM
    process are the same build. Notarized releases are Beads work.
    **The GUI** (`HoboApp`, its logic in `HoboAppModel`) is a library window over the same core:
    a sidebar of VMs and a detail pane with `set`'s settings. It keeps current through FSEvents on
    the store and hobo's home, plus a 5 s poll. It starts, stops, suspends, shows, clones, renames
    and deletes through `VMLifecycle`/`VMStore`. It creates in its own process through `VMCreator`,
    one build at a time; quitting during one asks, then cancels it as ^C does. New VM writes the
    recipe `hobo init` would (`RecipeDraft`) to a temporary directory. Recipes, snapshots and
    provisioning stay in the CLI.
    `start` refuses a binary without the virtualization entitlement, since a VM process failing
    that way would only say so in its log.
23. **Layout.** One Swift package, with the `hobo` and `HoboApp` executables that `make app` puts in
    Hobo.app (decision 22):
    - `HoboCore`: recipes, the VM store (`VMStore`: bundle paths, names, list, rename, delete) and
      `config.json` (`VMConfig`), image index, provisioners
    - `HoboVM`: VM bundles (`VMBundle`: `MacVMBundle`, `LinuxVMBundle`, `WindowsVMBundle`, each
      building its VZ configuration), VM creation, the VM
      process (`VMRunner`), display, and the host's side of the guest channel (`GuestShell`:
      `GuestAgent`, `GuestSSH`)
    - `Agent`: hobo-agent, in Go, built as resources of `HoboVM` by `HoboAgentPlugin` (decision 15)
    - `HoboUICore` and `hobo-ui`: `hobo ui`'s commands and the guest-side driver, a resource of
      `HoboVM` through `HoboUIPlugin` (decision 17)
    - `HoboControl`: client ↔ VM-process socket protocol, and the client side of `start`/`stop` (`VMLifecycle`)
    - `HoboMCP`: MCP tools
    - `hobo`: CLI plus hidden `_vm-run` and `mcp` subcommands
    - `HoboAppModel` and `HoboApp`: Hobo.app's GUI (decision 22)
    - `HoboVMTests` boot real VMs only with `HOBO_INTEGRATION=1`. The test runner can't hold the
      virtualization entitlement, so they drive the signed `hobo` binary (`make integration-test`).
      There is no CI; GitHub is a backup.
24. **Repo.** `ggal625/hobo`, private, Apache-2.0, `main`.
25. **Naming.** The hobo-and-trains metaphor (Boxcar, roundhouse, depot) was dropped on
    2026-11-01: the recipe is plain `Hobo.toml`.
26. **Logo.** A bindle, a stick with a tied red bandana bag, on a cream macOS icon tile (decided
    2026-11-03). `assets/icon.svg` is the master and `assets/icon-small.svg` the simplified drawing
    for 16-32 px; `swift assets/render.swift` regenerates everything else from them. `assets/Hobo.icns`
    is Hobo.app's icon, and the bindle is that app's alone.
    **VM icons.** Each VM window has its own icon, to find it among several in the Dock and ⌘Tab and to
    tell it from the GUI app (decided 2026-11-04): a hobo sign in chalk on a dark tile, with the VM's
    name in white under it. A SHA-256 of the name picks one of 24 signs and, from separate bits, one of
    8 colors, so a VM's icon never changes and needs no state, and a clone gets its own. Two VMs can
    share a sign or a color, and the name settles it. Long names shrink, then lose their middle, since
    clones differ only in their last characters. The signs (from `assets/draw_signs.py`) are files in
    Hobo.app's resources, read through `Payloads`.
    `VMIcon` draws the icon, and `VMWindow` sets it right after the process turns regular and appears
    in the Dock (the Dock ignores one set earlier). The name stays even though it's unreadable in a
    small Dock: ⌘Tab shows icons at about 128 pt, where it reads well, and a process has one image, so
    the two can't differ (2026-11-04: of an image's sizes the Dock shows only the largest, and
    `NSDockTile`'s custom view changes ⌘Tab as well). The drawings are our own, and whether hobos ever
    used these signs is doubtful, so they aren't presented as history.
27. **Docs.** Every feature is described once, in `docs/features/<slug>.md` (decided 2026-11-08):
    frontmatter (`title`, `description`, `sidebar.order`), a short part (a paragraph, an example,
    a screenshot if there is one), a `<!-- more -->` line, then the full guide. `make readme`
    (`site/scripts/readme.mjs`) pastes the short parts, in order, between README.md's
    `features:start`/`features:end` markers, each linking to its page; `make test` and the site
    build fail if the README is out of date, so the two can't disagree. The site,
    hobo.gsquared.app, is Astro Starlight in `site/`, reading `docs/features` and `docs/site` (home
    and getting-started pages) directly, so the files stay plain Markdown that reads well on GitHub;
    a remark plugin turns their links to each other into site URLs. Cloudflare Workers Builds
    deploys it from this repo (`Cloudflare.md`). Starlight over MkDocs Material, which is in
    maintenance mode, and over a hand-rolled generator, which would have to rebuild search and
    navigation. Screenshots live in `docs/images/`; regenerating them with demo VMs is Beads work.

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
- **M4, Linux guests:** done (2026-11-02): `[source] image`, cloud-init conventions, `images`/`init --os linux`; GUI testing (`exec --gui`, `screenshot`, AT-SPI) on 2026-11-07.
- **M5, Windows guests:** on VZ (decision 20): `[source] iso`, `init --os windows`, install with our
  own WinPE script, `exec --gui` in the desktop session, UI Automation.
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
| Guest channel | SSH; `tart exec` via a vsock guest agent | SSH; Cua computer server | vsock agent, fetched from the host each boot; SSH for people |
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
isolation (Softnet) and bridged mode. The maturity of tools proven at scale.

**To borrow.** Tart runs clones of one macOS VM side by side. Its `clone` regenerates the MAC,
and the machine identifier only for Linux guests; `tart set --random-serial` gives a macOS VM a new
identifier and keeps its aux storage, which is what Hobo's `clone` does (decision 12).

## Prior art

- [Tart](https://github.com/cirruslabs/tart): Swift VZ CLI with named VMs; reference for macOS installs.
- [Lume](https://github.com/trycua/cua): Swift VZ CLI and daemon behind the Cua computer-use agents.
- [VirtualBuddy](https://github.com/insidegui/VirtualBuddy), [Mist](https://github.com/ninxsoft/Mist):
  macOS guest GUI and IPSW/installer fetching.
- [UTM](https://github.com/utmapp/UTM): QEMU + HVF for Windows on Arm.
- Howard Oakley's [Virtualisation on Apple silicon](https://eclecticlight.co/virtualisation-on-apple-silicon/)
  articles: guest limits, machine identity, shares, ASIF, version gates (reviewed 2026-11-01).
- WWDC26 session 224, "Expand the capabilities of your Virtualization app" (macOS 27 APIs).
