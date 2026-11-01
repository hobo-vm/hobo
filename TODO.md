# TODO

Only 2 macOS guests can run per host, so a `create` plus a boot test fill both slots.

- M1: `hobo _vm-run` VM process + LaunchAgent registration + `HoboControl` socket protocol; headless `start`, `stop [--force]`
- M1: `hobo view` on-demand window (`.accessory` NSApplication), `start --gui`
- M1: `ssh` / `exec` / `cp` / `ip`, shared vmnet NAT with Hobo-controlled DHCP; replace the insecure key with a per-VM key at the end of `create` (design decision 10.3)
- M1 [verify]: ASIF space reclaim from inside a macOS guest (create a file, delete it, check the bundle's disk size on the host); if it doesn't shrink, revisit the no-compaction decision
- M1 [verify]: disk grow end to end: resize the ASIF, then grow the guest's APFS container without removing Recovery (needed by `[gui_testing]`)
- M1: `hobo set` (cpus, memory, disk grow, persistent virtio-fs shares), `start --share`, `hobo provision <name> [recipe]`
- M1: `hobo df`: sizes of bundles, snapshots, saved state and indexed images
- M1 [parallel]: Windows spike: Windows 11 on Arm on `qemu-system-aarch64 -accel hvf`, unattended install via `autounattend.xml`, headless boot, OpenSSH, screenshot from the interactive session
- M2 [spike first]: can a cloned macOS VM take a new machine identifier and still boot (fresh identifier alone, then with fresh aux storage; check Tart)? If not, a clone and its source can't run concurrently: same identifier means network on only one and Apple ID re-auth
- M2: `hobo clone` (APFS clone, new machine identifier + MAC, source stopped), `--ephemeral` on `clone` and `start`
- M2: `hobo snapshot save|restore|list|delete`, live (saved state + disk clone) and stopped
- M2: `hobo suspend`, resume on `start`, `start --cold`
- M3: ephemeral idle-timeout leases renewed by control-socket calls; `hobo mcp` stops its ephemeral VMs on exit
- M3: recipe `[gui_testing]`: SIP off via recovery boot + TCC pre-grants (Accessibility, Screen Recording)
- M3: `exec --gui` (Aqua session via `launchctl asuser`), `hobo screenshot`
- M3: `hobo mcp` stdio server (lifecycle, exec, copy_in/out, screenshot, clone, snapshot, set, provision, list)
- M3: `--json` output on every command
- M4: Linux guests (cloud image + cloud-init recipes); optional Rosetta (virtio-fs Rosetta share + binfmt)
- M5: QEMU engine (`engine = "qemu"`) for Windows: same bundle, clone, snapshot, suspend, leases; `exec --gui` via scheduled task; UI Automation/WinAppDriver
- Later: host-side framebuffer screenshot for wedged guests
- Later: project-level file attaching VMs and shares to a directory
- Later: an Xcode recipe (macOS 27 + Xcode, pinned `.xip`; the Mac App Store doesn't work in VMs)
- Later: USB passthrough (`VZUSBPassthroughDevice`, macOS 27 host and guest)
- Later: `hobo sim` for host iOS Simulator (headless simctl; input via idb/XCUITest) and Android Emulator (`-no-window`, adb)
- Later: Developer ID + notarization, private Homebrew tap, `.app` bundle for VM window identity
- Later: `hobo-agent` over virtio-vsock
- Later: external provisioner JSON contract, Ansible plugin
- Later: Android emulator inside Linux guests via nested virtualization (M3+ hosts)
- Later: port forwards and bridged networking (`public_network`) via privileged helper
