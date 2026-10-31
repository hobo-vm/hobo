# TODO

Parallel tracks A/B/C are independent. Only 2 macOS guests can run per host, so a recipe build plus a B boot test fill both slots.

- M1 [parallel A]: `Recipes/macos-27.toml`: base box with Vagrant conventions, pinned to the depot's 27.2 IPSW; build it
- M1 [parallel B]: minimal `hobo box add` (untar into `~/.hobo/boxes/`) + foreground `hobo up`: APFS clone (copy fallback across volumes) into `.hobo/machines/<name>/`, boot in-process with a window, Ctrl-C/close stops the guest
- M1 [parallel C]: `hobo df` and `hobo prune [--depot|--boxes|--machines] [--all]` across the depot, installed boxes, machine dirs and roundhouse (build dirs + checkpoints), like `docker system df/prune`
- M1: `hobo _vm-run` VM process + LaunchAgent registration + `HoboControl` socket protocol; `up` goes headless and detached
- M1: `hobo view` on-demand window (`.accessory` NSApplication)
- M1: `ssh` / `halt` / `destroy` / `status`, NAT via vmnet, virtio-fs synced folders
- M2: `hobo mcp` stdio server (lifecycle, exec, copy_in/out, screenshot, provision, snapshot, box_list, box_build)
- M2: `--json` output on every command
- M2: `hobo run -- <cmd>` ephemeral runs with declared copy-out paths (DiskImageKit throwaway overlay)
- M2: `hobo snapshot save|restore|list|delete` (DiskImageKit stacked overlays)
- M3: Linux guests (cloud image + cloud-init recipes, `/vagrant` mount)
- M3: forwarded ports, private networks across VM processes, multi-machine boot order
- M3: provisioner run-state tracking, `hobo provision`, rsync synced folders
- Later: `hobo sim` for host iOS Simulator (headless simctl; input via idb/XCUITest) and Android Emulator (`-no-window`, adb)
- Later: static box catalog, `hobo box publish|outdated|update`, resumable checksum-verified downloads
- Later: Developer ID + notarization, private Homebrew tap, `.app` bundle for VM window identity
- Later: `hobo-agent` over virtio-vsock
- Later: external provisioner JSON contract, Ansible plugin
- Later: `hobo init --from-vagrantfile` importer for simple Vagrantfiles
- Later: Android emulator inside Linux guests via nested virtualization (M3+ hosts)
- Later: bridged networking (`public_network`) via privileged helper
- Later: recipe IPSW sources by version (`ipsw = "27.1"`) via a catalog, as Mist does
- Later: `Recipes/macos-27-xcode.toml` (Xcode)
- Later: recipe `[gui_testing]`: SIP off via recovery boot + TCC pre-grants
