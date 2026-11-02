# Windows 11 on Arm under QEMU: spike (hobo-gsa)

Throwaway proof that a headless Windows 11 on Arm guest can be installed unattended, reached
over SSH, and screenshotted from its interactive session, on `qemu-system-aarch64 -accel hvf`.
M5 (hobo-51j) turns this into the QEMU engine; nothing here is wired into Hobo.

**Result: it all works.** Run on 2026-11-02 on macOS 27.2, QEMU 11.1.3 (Homebrew), Windows 11
Pro build 26300.9457 (`Windows11_Client_arm64_en-us_26300_9457.iso`, sha256 `8992f2d2…6623e9c`).

## Running it

```sh
brew install qemu
# Windows 11 ARM64 ISO from https://www.microsoft.com/software-download/windows11arm64 → ~/Downloads
./run.sh prepare      # downloads virtio-win + OpenSSH (pinned), builds config ISO, disk, NVRAM
./run.sh install      # unattended install; watch ~/Downloads/hobo-windows-spike/progress.png
./run.sh screenshot   # guest-side + host-side PNGs into ~/Downloads/hobo-windows-spike
./run.sh ssh 'ver'    # cmd.exe is the remote shell
./run.sh stop
./run.sh boot
```

Large files live in `~/Downloads/hobo-windows-spike` (12 GB disk after install, plus the 0.9 GB
virtio-win ISO). The files here: `run.sh` (host side), `autounattend.xml`, `hobo-setup.ps1`
(first logon), `run-in-session.ps1` (the `exec --gui` prototype), `screenshot.ps1`.

## The machine

```
qemu-system-aarch64 -machine virt,highmem=on -accel hvf -cpu host -smp 4 -m 8G
  -drive if=pflash,readonly=on,file=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
  -drive if=pflash,file=vars.fd                       # copy of edk2-arm-vars.fd, per VM
  -device ramfb                                       # the only display; Windows uses Basic Display
  -device qemu-xhci -device usb-kbd -device usb-tablet
  -device nvme,drive=disk0,bootindex=0                # inbox driver, no viostor needed
  -netdev user,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci   # NetKVM from virtio-win
  -device usb-storage,drive=<Windows ISO>,bootindex=1 -device usb-storage,drive=<config ISO>
  -display none -qmp unix:qmp.sock,server=on,wait=off
```

## Timings

| Step | Time |
|---|---|
| Setup's file copy from the ISO (to Setup's first reboot) | ~45 min |
| First boot from disk → specialize → OOBE → first logon → OpenSSH up | 7 min |
| `stop` (`shutdown /s` over SSH) | 19 s |
| Cold `boot` to SSH answering | 26 s |
| Guest-side screenshot (scheduled task round trip) | 7–16 s |
| Host-side QMP screendump | instant |

## Findings

1. **The install media is the bottleneck.** The file copy is I/O-bound on the emulated USB mass
   storage that carries the ISO (QEMU sat at ~60% of one core). WinPE has no virtio driver, so the
   faster buses aren't available before Setup boots. For M5: try `usb-uas` or `usb-storage` on a
   USB 3 port with a larger request size, or skip Setup: apply `install.wim` to the disk from a
   helper VM with `wimlib`/DISM, then boot straight into specialize. Treat 45 minutes as the
   baseline to beat.
2. **Boot order: name the disk.** `bootindex` becomes QEMU's `bootorder` for edk2, and edk2 then
   drops boot entries the list doesn't name. With only the CD given `bootindex=0`, every Setup
   reboot fell back to the CD, its "press any key" prompt timed out, and edk2 landed in the UEFI
   shell instead of trying Windows Boot Manager. The fix is disk `bootindex=0` and CD
   `bootindex=1`: the empty disk falls through to the CD, and after the first phase the disk wins.
3. **The CD's "press any key" prompt.** The ISO's EFI loader waits about 5 s for a key. `run.sh`
   sends Enter over QMP `send-key` for the first 10 s only. Pressing longer reaches Setup's UI,
   where Enter lands on the focused **Cancel** button (seen on the first run: "Are you sure you
   want to quit?"). Rebuilding the ISO with `efisys_noprompt.bin` would remove the prompt
   entirely, which is better for the engine.
4. **`autounattend.xml` on a second ISO works.** `hdiutil makehybrid -iso -joliet` builds it and
   Setup finds it at the root. The drive letter isn't known in advance, so driver paths list
   `D:`–`G:`, and the first-logon command loops over drive letters looking for `hobo-setup.ps1`.
   The ISO is multi-edition (Home, Home Single Language, Pro), and the generic Pro install key
   picks Pro without a prompt.
5. **Windows 11 gates.** LabConfig `BypassTPMCheck`/`BypassSecureBootCheck`/`BypassRAMCheck` in
   windowsPE and `BypassNRO` in specialize gave a fully unattended local-account OOBE with no
   network or Microsoft-account screens. No vTPM: hobo-f8e tracks `swtpm`.
6. **Drivers.** NVMe and USB input are inbox. NetKVM (`NetKVM/w11/ARM64` from virtio-win
   0.1.302) loaded from the windowsPE `DriverPaths` and showed up as "Red Hat VirtIO Ethernet
   Adapter". virtio-win also ships ARM64 viorng, vioserial, viosock, viofs and Balloon; vioserial
   or viosock is the candidate for a guest-agent channel like the macOS one.
7. **OpenSSH.** The Win32-OpenSSH ARM64 MSI (10.4.0.0p1, pinned by sha256) installs offline from
   the config ISO. `OpenSSH.Server` as a Feature on Demand is `NotPresent` on this ISO and would
   download from Windows Update. vagrant is an admin, so its keys go in
   `C:\ProgramData\ssh\administrators_authorized_keys`, writable only by Administrators and
   SYSTEM. `scp` works with both the legacy protocol (`C:/path`) and SFTP (`/C:/path`).
8. **Session 0 really has no desktop.** Run straight from SSH, `CopyFromScreen` fails with "The
   handle is invalid". `run-in-session.ps1` registers a one-shot scheduled task whose principal
   is `vagrant` with `-LogonType Interactive`, which needs no stored password. It starts the task
   under `conhost --headless`, waits, returns the task's exit code, and unregisters it. Both
   screenshots show the same desktop. This is the shape of `exec --gui` for Windows. The cost is
   cold starts of two PowerShells plus `Add-Type`. The engine should keep a small agent resident
   in the session instead (for example a Run-key process listening on vioserial/viosock).
9. **Auto-logon survives reboots.** The unattend `AutoLogon` has a `LogonCount`, so
   `hobo-setup.ps1` rewrites the Winlogon keys permanently. After a cold boot, `query user` shows
   vagrant `Active` on `console`.
10. **Display is 800×600.** `ramfb` has no resolution properties in QEMU 11.1, and Windows drives
    it with the Basic Display adapter at the firmware's 800×600. That's too small for real GUI
    testing. Open question for M5: edk2's GOP resolution setting (persisted in `vars.fd`), or a
    different display path. VZ's virtio-gpu is still out, because Windows on Arm can't drive it.
11. **Networking.** User-mode networking with `hostfwd` needs no root, and the guest reaches the
    internet. It gives no routable guest IP, so `hobo ip` and VZ's DHCP-lease model don't carry
    over. M5 picks between hostfwd (a port per VM) and `vmnet-shared` (root, or a
    `socket_vmnet` helper as Lima does).
12. **Process model.** QEMU runs as an ordinary child process with a QMP Unix socket, which fits
    "one `hobo _vm-run` per VM under launchd": `_vm-run` would supervise QEMU and translate
    `HoboControl` requests into QMP (`screendump`, `send-key`, `system_powerdown`, and
    `migrate`/`savevm` for suspend and snapshots). `run.sh stop` used `shutdown /s` over SSH;
    `system_powerdown` (ACPI) is the fallback and wasn't exercised.
13. **Guest clock.** The unattend's `TimeZone` of `UTC` makes the taskbar clock read UTC. The
    engine should take the host's zone instead.

## Not tried

- vTPM/Secure Boot (hobo-f8e), suspend/snapshots via QMP, `system_powerdown` timing, display
  resolution, and faster install media (finding 1).
