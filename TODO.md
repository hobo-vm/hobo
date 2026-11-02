# TODO

Only 2 macOS guests can run per host, so a `create` plus a boot test fill both slots. Items under
"macOS VM track" boot macOS guests: work them in one worktree at a time (`make integration-test`
queues on a host lock, manual testing doesn't). Items under "Parallel" boot none, so each can run in
its own worktree alongside. Each section is in dependency order; "needs" names what must land first.

## macOS VM track (one worktree at a time)

- M1: `hobo set` (cpus, memory, disk grow, persistent virtio-fs shares), `start --share`, `hobo provision <name> [recipe]`
- M2 [spike first]: can a cloned macOS VM take a new machine identifier and still boot (fresh identifier alone, then with fresh aux storage; check Tart)? If not, a clone and its source can't run concurrently: same identifier means network on only one and Apple ID re-auth
- M2: `hobo clone` (APFS clone, new machine identifier + MAC, source stopped), `--ephemeral` on `clone` and `start`; needs the clone spike
- M2: `hobo suspend`, resume on `start`, `start --cold`
- M2: `hobo snapshot save|restore|list|delete`, live (saved state + disk clone) and stopped
- M2: `hobo df`: sizes of bundles, snapshots, saved state and indexed images; needs suspend and snapshot
- M3: ephemeral idle-timeout leases renewed by control-socket calls; `hobo mcp` stops its ephemeral VMs on exit; needs `--ephemeral`
- M3: `exec --gui` (Aqua session via `launchctl asuser`), `hobo screenshot`
- M3: `hobo mcp` stdio server (lifecycle, exec, copy_in/out, screenshot, view, clone, snapshot, set, provision, list); needs everything above

## Parallel (no macOS guests)

- M1: Windows spike: Windows 11 on Arm on `qemu-system-aarch64 -accel hvf`, unattended install via `autounattend.xml`, headless boot, OpenSSH, screenshot from the interactive session
- M3: agent guidance text in `HoboCore` (ephemeral session pattern, test in the guest never the host UI, `exec --gui`, 2-macOS-guest limit, "run `hobo usage`"), used as the Claude skill body and the MCP server's `instructions`
- M3: `hobo claude install|uninstall [--project] [--force]`: write/remove `hobo/SKILL.md` with a `hobo-version` ownership marker; `make install` refreshes an existing global copy; needs the guidance text
- M4: Linux guests (cloud image + cloud-init recipes); optional Rosetta (virtio-fs Rosetta share + binfmt)
- M5: QEMU engine (`engine = "qemu"`) for Windows: same bundle, clone, snapshot, suspend, leases; `exec --gui` via scheduled task; UI Automation/WinAppDriver; needs the Windows spike and the M2/M3 features it mirrors

## Later

- Per-VM SSH key: generate one at the end of `create`, replace the insecure keys in `authorized_keys`, keep it in the bundle (deferred 2026-11-01)
- Host-side framebuffer screenshot for wedged guests
- Project-level file attaching VMs and shares to a directory
- An Xcode recipe (macOS 27 + Xcode, pinned `.xip`; the Mac App Store doesn't work in VMs)
- USB passthrough (`VZUSBPassthroughDevice`, macOS 27 host and guest)
- `hobo sim` for host iOS Simulator (headless simctl; input via idb/XCUITest) and Android Emulator (`-no-window`, adb)
- Developer ID + notarization, private Homebrew tap, `.app` bundle for VM window identity
- `hobo-agent` over virtio-vsock
- External provisioner JSON contract, Ansible plugin
- Android emulator inside Linux guests via nested virtualization (M3+ hosts)
- Port forwards and bridged networking (`public_network`) via privileged helper
