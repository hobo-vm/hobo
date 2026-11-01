# TODO

Only 2 macOS guests can run per host, so a `create` plus a boot test fill both slots.

- M1: pivot code: delete `box build/validate-recipe`, packaging, `BoxMetadata`, roundhouse checkpoints and the project Boxcar parser/template; `Recipe` → `.boxcar` parser (drop `name`/`version`), `hobo boxcar validate`, `hobo init [name]` writes a starter `.boxcar`
- M1: image index: IPSW downloads to `~/Downloads` via `.part`, `~/.hobo/images.json` (URL → SHA → path, size + mtime), re-download when missing; replaces `Depot`
- M1: VM bundles in `~/Virtual Machines/<name>.hobovm` (`HOBO_VMS`), `config.json`, `hobo create --from` building in place (`building` state, `--hold-on-failure`), `hobo list`, `delete`, `rename`
- M1: `hobo _vm-run` VM process + LaunchAgent registration + `HoboControl` socket protocol; headless `start`, `stop [--force]`
- M1: `hobo view` on-demand window (`.accessory` NSApplication), `start --gui`
- M1: `ssh` / `exec` / `cp` / `ip`, shared vmnet NAT with Hobo-controlled DHCP
- M1: `hobo set` (cpus, memory, disk grow, persistent virtio-fs shares), `start --share`, `hobo provision --from`
- M1: `hobo df`: sizes of bundles, snapshots, saved state and indexed images
- M1 [parallel]: Windows spike: Windows 11 on Arm on `qemu-system-aarch64 -accel hvf`, unattended install via `autounattend.xml`, headless boot, OpenSSH, screenshot from the interactive session
- M2: `hobo clone` (APFS clone, new machine identifier + MAC, source stopped), `--ephemeral` on `clone` and `start`
- M2: `hobo snapshot save|restore|list|delete`, live (saved state + disk clone) and stopped
- M2: `hobo suspend`, resume on `start`, `start --cold`
- M3: ephemeral idle-timeout leases renewed by control-socket calls; `hobo mcp` stops its ephemeral VMs on exit
- M3: Boxcar `[gui_testing]`: SIP off via recovery boot + TCC pre-grants (Accessibility, Screen Recording)
- M3: `exec --gui` (Aqua session via `launchctl asuser`), `hobo screenshot`
- M3: `hobo mcp` stdio server (lifecycle, exec, copy_in/out, screenshot, clone, snapshot, set, provision, list)
- M3: `--json` output on every command
- M4: Linux guests (cloud image + cloud-init Boxcars)
- M5: QEMU engine (`engine = "qemu"`) for Windows: same bundle, clone, snapshot, suspend, leases; `exec --gui` via scheduled task; UI Automation/WinAppDriver
- Later: host-side framebuffer screenshot for wedged guests
- Later: project-level file attaching VMs and shares to a directory
- Later: Boxcar IPSW sources by version (`ipsw = "27.1"`) via a catalog, as Mist does
- Later: `Recipes/macos-27-xcode.boxcar` (Xcode)
- Later: `hobo sim` for host iOS Simulator (headless simctl; input via idb/XCUITest) and Android Emulator (`-no-window`, adb)
- Later: Developer ID + notarization, private Homebrew tap, `.app` bundle for VM window identity
- Later: `hobo-agent` over virtio-vsock
- Later: external provisioner JSON contract, Ansible plugin
- Later: Android emulator inside Linux guests via nested virtualization (M3+ hosts)
- Later: port forwards and bridged networking (`public_network`) via privileged helper
