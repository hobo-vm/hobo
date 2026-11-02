# TODO

Only 2 macOS guests can run per host, so a `create` plus a boot test fill both slots.

- M1: `hobo set` (cpus, memory, disk grow, persistent virtio-fs shares), `start --share`, `hobo provision <name> [recipe]`
- M1 [parallel]: Windows spike: Windows 11 on Arm on `qemu-system-aarch64 -accel hvf`, unattended install via `autounattend.xml`, headless boot, OpenSSH, screenshot from the interactive session
- M2 [spike first]: can a cloned macOS VM take a new machine identifier and still boot (fresh identifier alone, then with fresh aux storage; check Tart)? If not, a clone and its source can't run concurrently: same identifier means network on only one and Apple ID re-auth
- M2: `hobo clone` (APFS clone, new machine identifier + MAC, source stopped), `--ephemeral` on `clone` and `start`
- M2: `hobo suspend`, resume on `start`, `start --cold`
- M2: `hobo snapshot save|restore|list|delete`, live (saved state + disk clone) and stopped
- M2: `hobo df`: sizes of bundles, snapshots, saved state and indexed images
- M3: ephemeral idle-timeout leases renewed by control-socket calls; `hobo mcp` stops its ephemeral VMs on exit
- M3: `exec --gui` (Aqua session via `launchctl asuser`), `hobo screenshot`
- M3: `hobo mcp` stdio server (lifecycle, exec, copy_in/out, screenshot, view, clone, snapshot, set, provision, list)
- M4: Linux guests (cloud image + cloud-init recipes); optional Rosetta (virtio-fs Rosetta share + binfmt)
- M5: QEMU engine (`engine = "qemu"`) for Windows: same bundle, clone, snapshot, suspend, leases; `exec --gui` via scheduled task; UI Automation/WinAppDriver
- Later: per-VM SSH key: generate one at the end of `create`, replace the insecure keys in `authorized_keys`, keep it in the bundle (deferred 2026-11-01)
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
