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
(first logon), `run-in-session.ps1` (the `exec --gui` prototype), `screenshot.ps1`,
`hvf-unaligned.patch` (finding 14), and `vz-boot.swift` (findings 20 and 21).

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
   network or Microsoft-account screens. A real vTPM and Secure Boot also work: see below.
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
10. **`ramfb` is 800×600.** `ramfb` has no resolution properties in QEMU 11.1, and Windows drives
    it with the Basic Display adapter at the firmware's 800×600. That's too small for real GUI
    testing, but `virtio-gpu-pci` replaces it: see "Display and VZ" below, which also corrects
    what this finding used to say about virtio-gpu.
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

## vTPM and Secure Boot (hobo-f8e)

**Result: both work on stock Homebrew QEMU, but the firmware has to come from elsewhere.** Run on
2026-11-02 with swtpm 0.10.2 (Homebrew), against copy-on-write overlays of the installed disk
above. Windows booted with Secure Boot on, the vTPM ready, and BitLocker sealed to the TPM
(PCR 7, 11). After a cold restart of QEMU and swtpm the volume unlocked without a recovery key.

```sh
brew install swtpm
# Firmware: UTM 5.0.8's Resources/qemu/edk2-aarch64-secure-code.fd, and its
# edk2-arm-secure-vars.fd padded to 64 MiB (truncate -s 64m) as vars.fd. Then, with
# virt-fw-vars from `pip install --no-deps virt-firmware cryptography pefile`:
virt-fw-vars -i vars.fd -o vars.fd --enroll-generate "Hobo VM <name>" \
    --microsoft-kek all --microsoft-db all --sb
HOBO_SPIKE_TPM=1 HOBO_SPIKE_CODE=.../edk2-aarch64-secure-code.fd ./run.sh boot
```

The QEMU side is three arguments; `swtpm` runs beside QEMU:

```
swtpm_setup --tpm2 --tpmstate $WORK/tpm --create-ek-cert --create-platform-cert --lock-nvram
swtpm socket --tpm2 --tpmstate dir=$WORK/tpm --ctrl type=unixio,path=$WORK/swtpm.sock --terminate --daemon
qemu-system-aarch64 ... -chardev socket,id=chrtpm,path=$WORK/swtpm.sock
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0,ppi=off
```

14. **`ppi=off` is required on HVF.** `tpm-tis-device` defaults to `ppi=on`, which adds a 1 KiB
    RAM region for the Physical Presence Interface. HVF can't map less than a 16 KiB page, and
    `hvf_set_phys_mem` then calls `hv_vm_unmap` on the unaligned, never-mapped range, which
    fails, so QEMU aborts at start with `HV_BAD_ARGUMENT (hvf-all.c:123)`. `hvf-unaligned.patch`
    (return early instead) fixes it: with it, `ppi=on` boots and `Get-Tpm` works. Without PPI,
    `Get-Tpm` fails with `0x80284001`, because it asks for PPI state, and System logs TPM event 15
    at boot. `tpmtool`, the Platform Crypto Provider (TPM-backed keys) and BitLocker all work
    regardless. Worth sending upstream; the engine doesn't need it.
15. **Homebrew's firmware has no Secure Boot, and BitLocker won't use the TPM without it.** QEMU's
    `edk2-aarch64-code.fd` measures boot into the TPM (the TCG log matches the PCRs), but
    `Confirm-SecureBootUEFI` reports the variable undefined, and `manage-bde -protectors -add C:
    -tpm` fails with `0x80310002` ("The BIOS did not correctly communicate with the TPM"). The
    same command on Secure Boot firmware succeeds with PCR profile 7, 11, so PPI wasn't the cause.
16. **Debian's AAVMF doesn't boot Windows under HVF.** `qemu-efi-aarch64` 2026.08+ds-2 and
    2025.02-8+deb13u1 (`AAVMF_CODE.secboot.fd` with `AAVMF_VARS.ms.fd`, and also the non-Secure
    Boot `AAVMF_CODE.no-secboot.fd`) stop at "Start boot option" for 10+ minutes with no serial
    output after the banner. Homebrew's firmware with an equally fresh NVRAM boots the same disk
    in 25 s, so the cause is the firmware build; it wasn't pursued.
17. **UTM's Secure Boot firmware works, but ships without keys.** `edk2-arm-secure-vars.fd` is in
    Setup Mode, with no PK, KEK, db or dbx, so Secure Boot is off until keys are enrolled.
    `virt-fw-vars` enrolls them offline in a second: a generated per-VM PK, plus Microsoft's
    2011 and 2023 KEK and db certificates. Windows Boot Manager is signed by the Microsoft
    Windows PCA, so it boots. A fresh NVRAM loses Windows' boot entry, but edk2 falls back to
    `\EFI\BOOT\BOOTAA64.EFI` on the ESP. Arm `virt` has no SMM, so the guest kernel could
    rewrite the Secure Boot variables: this satisfies Windows' checks rather than defending a
    test VM. The Microsoft 2011 certificates expired during 2026 (firmware doesn't check expiry),
    and new boot managers are signed under the 2023 CAs, so both generations are enrolled.
18. **What the second daemon costs the process model: little.** `swtpm_setup` takes 0.4 s once
    per VM, and the state is one ~10 KB file (`tpm2-00.permall`). `swtpm socket --daemon
    --terminate` starts in 25 ms and exits by itself when QEMU disconnects, including when QEMU
    crashes, so `_vm-run` starts it before QEMU as a second child, with no launchd job of its
    own and nothing to reap. UTM links swtpm into its process as a framework instead; Hobo
    doesn't need to. The state is part of the VM:
    - `clone` and offline snapshots must copy `tpm/` and `vars.fd` with the disk. A BitLocker
      volume whose TPM state is lost or rolled back separately needs its recovery key.
    - Running snapshots (`savevm`) should carry the TPM state, since the `emulator` backend
      migrates swtpm's state blobs, but this wasn't tested.
    - `swtpm_localca` keeps its CA in `$(brew --prefix)/Cellar/swtpm/<version>/var/lib`, which
      `brew upgrade` deletes. Existing VMs keep their EK certificates in TPM NVRAM, and Windows
      reports `EkCertIsAvailable: false` for this CA anyway, so the engine can skip
      `--create-ek-cert` or point `swtpm_setup --config` at a Hobo-owned CA.

## Display and VZ (hobo-51j)

Run on 2026-11-05 on macOS 27.2, against APFS clones of the installed disk above. The spike and
decision 20 had said Windows on Arm can't drive virtio-gpu, but nothing had tested it, and
virtio-win 0.1.302 ships `viogpudo/w11/ARM64`.

19. **Under QEMU, virtio-gpu works and ends the 800×600 limit.** `pnputil /add-driver viogpudo.inf
    /install` over SSH bound "Red Hat VirtIO GPU DOD controller" with no test signing or reboot.
    With `-device virtio-gpu-pci,xres=1920,yres=1200` and no `ramfb`, the guest boots to SSH in
    16 s at 1920×1200. It offers modes up to 5120×2160, and QMP `screendump` and the guest-side
    screenshot both return 1920×1200. Setup itself hasn't been run on this device, and neither
    suspend nor snapshots have been tried with it.
20. **Windows didn't boot under VZ.** `vz-boot.swift` uses VZ's EFI, NVMe, virtio-gpu, USB input
    and NAT. Neither Windows path ever showed anything:

    | Boot | Display | CPU | Other signs |
    |---|---|---|---|
    | Installed disk (raw, `viogpudo` installed, fresh NVRAM) | black for 5 min | one core at 100% | disk and NVRAM never written, no DHCP lease |
    | Windows ISO over USB mass storage, empty disk | black at 50 s, no "press any key" | one core at about 100% | |
    | Control: clone of an Ubuntu 26.04 VM, same program, NVMe | GNOME desktop by 50 s | about 2% | |

    So the hang comes before any display driver matters: one vCPU spins early, in firmware or
    Windows' boot loader. Finding 21 has the cause.
21. **Windows does run under VZ, with two fixes.** [A post on running Windows under
    Tart](https://mustafaakin.dev/blog/windows-on-tart/) names them, and its [fork](https://github.com/mustafaakin/tart/tree/windows-guest-extras)
    has the code (FSL-1.1-ALv2, so it was built here for testing only and none of it is in this
    repo). Run on an M2 on macOS 27.2, with the installed disk above, on NVMe:

    - The spin ends with the private `VZGenericPlatformConfiguration`
      `_setPerformanceMonitoringUnitEmulationEnabled:`. Alone, it turns the hang into "The virtual
      machine stopped unexpectedly" in under a second. `_setFineGrainedTrapsEmulationEnabled:`
      wasn't needed.
    - VZ's firmware offers a Blt-only GOP with no linear framebuffer, which the post gives as the
      cause of that stop. The fork's UEFI driver (7 KB) backs the GOP with reserved RAM and copies
      changed rows to the scanout until `ExitBootServices`. Here it went in the EFI partition with a
      small loader as `EFI/BOOT/BOOTAA64.EFI`, which starts the driver and then Boot Manager, moved
      to `EFI/BOOT/windows.efi`. No firmware file is replaced, and VZ's `VZEFIBootLoader` is used.

    | Check | Result |
    |---|---|
    | Boot to SSH, fresh NVRAM | 6–8 s; 11 s with two clones starting together |
    | Devices | Apple NVMe, VirtIO network with a DHCP lease on the VM's MAC, VirtIO GPU |
    | Display | 1024×768 at first; 1920×1200 once set from the desktop session, and it stays set across a reboot |
    | Session work | `run-in-session.ps1` works, and a guest screenshot is 1920×1200 |
    | Guest reboot, shutdown | Same VM process through a reboot, SSH back in 16 s; shutdown stops the VM |
    | Save a running VM | Works, against the post's report: about 5–6 s, 2.8 GB with 8 GB of memory |
    | Restore | 3–8 s; processes and desktop carry on, and the VM's CPU settles |
    | Network after restore | **Dead.** The guest stops answering ARP, and swapping the attachment from the host doesn't help. `ipconfig /renew` doesn't either; `Restart-NetAdapter` in the guest brings it back in about a second |
    | Clones | `cp -c` of disk and NVRAM, new machine identifier and MAC; two ran together, each with its own lease. The hostname stays the source's |

    Not yet tried: installing under VZ (the post's DISM script takes 12 min and avoids Setup,
    which it says fails on these disks), ASIF disks, virtio-fs shares, and whether the private
    setter survives later macOS releases.

## Not tried

- A fresh install with vTPM + Secure Boot and no LabConfig bypasses (the runtime checks above
  ran on the existing install), running snapshots with a vTPM, Windows Hello, suspend/snapshots
  via QMP, `system_powerdown` timing, and faster install media (finding 1).
