# hobo ui on Linux and Windows guests

## Decisions

1. **Architecture.** `hobo-ui`'s OS-neutral driver logic (refs, locators, snapshot building and
   formatting, `--text` matching, waits, hit-test checks) moves into `HoboUICore` behind a
   `UIBackend` protocol. macOS keeps running it in the guest, in `hobo-ui`, with the AX backend.
   For Linux and Windows the same driver runs on the host, with thin guest backends for the platform
   calls; their refs live in the VM's per-boot run state on the host.
2. **Linux input** is a uinput absolute pointer and keyboard (a udev rule giving the `hobo` user
   `/dev/uinput`), which reaches Wayland apps as hardware input.
3. **Linux screen positions** come from a GNOME Shell extension of hobo's own, shipped in
   `share/hobo` and installed by the recipe. Over D-Bus it lists windows (pid, desktop app ID, title,
   frame and buffer rects, stacking, focus) and activates one. AT-SPI's window-relative extents are
   offset by the window's origin; stacking covers raising and hit-testing.
4. **One backend process per command.** The host starts the backend with `exec --gui` and speaks
   JSON lines to it over stdin and stdout for the command's life; closing stdin ends it. The agent's
   `exec` gains a stdin frame (protocol version bump).
5. **Windows backend** is C#, published with NativeAOT for `win-arm64` inside an ephemeral clone of
   a Windows build VM by `make windows-ui`. The exe is committed with its sources' digest; `make test`
   fails when they differ, as for a stale README. `swift build` uses the committed exe, and the agent
   learns to fetch tools on Windows.
6. **Roles** are ARIA role names, mapped through W3C Core-AAM, plus `window`, `text` and
   `scrollarea` where ARIA has none, on every guest, macOS included (`textfield` becomes `textbox`,
   `statictext` becomes `text`). Backends report native roles; the mapping lives in Swift on the host
   side of the driver; `--json` keeps the native role.
7. **Linux setup** is part of the recipe's desktop step, always on: the udev rule and the
   extension. `[gui_testing]` stays macOS-only; Windows needs nothing.
8. **`--app`**: on Linux the desktop app ID (`org.gnome.TextEditor`), a display name (its `.desktop`
   name or AT-SPI's), or `pid:N`; on Windows the AUMID or exe name without `.exe`, a display name, or
   `pid:N`. Case-insensitive; ambiguous names fail listing matches; refs are keyed by the ID; the
   default is the focused window's app.
9. **`menu`** walks real menu bars everywhere (UIA ExpandCollapse/Invoke on Windows, AT-SPI menu bars
   on Linux). An app with none fails with a hint: its menus are behind a button, use `click --text`.
10. **`choose`** is ported: Ctrl+L and the path in GTK's file chooser, the File name box in Windows'
    common dialog; then confirm, failing if the dialog is still there.
11. **Linux `type`** sends keycodes for what the US layout has and IBus's Ctrl+Shift+U, hex, Space
    entry for other characters.
12. **Tests.** Integration per OS in ephemeral clones: Linux with GNOME Text Editor (type with a
    non-ASCII character, wait, click, scroll, `choose` through Save As, `menu`'s hint) and Files
    (drag a file onto a folder, checked on disk); Windows with Notepad (type, `menu "File > Save
    As…"`, `choose`, wait, click, scroll) and Explorer (drag, checked on disk). Unit tests on
    synthetic trees for role mapping, app matching and the IBus sequence.
13. Defaults chosen without a question: the Linux backend is a Python script served as the
    `ui-linux-arm64` tool; `--press` is AT-SPI `do_action(0)` and UIA's Invoke pattern; settling
    windows polls until window frames stop changing; pixel scale comes from GNOME's monitor scale and
    a per-monitor DPI aware Windows backend.

## As built

- The driver runs in the VM process (`GuestUI`), not a separate host process; refs for Linux and
  Windows guests live in `VMJob.uiState`, kept across a resume and cleared by a fresh boot.
- The Windows backend targets .NET Framework 4.8.1 (in every Windows 11), not NativeAOT: a
  28 KB exe with no runtime to ship, built by `make windows-ui` with `dotnet build` in an
  ephemeral clone of a Windows VM provisioned with `UIWindows/install-dotnet.ps1`.
- A WinUI menu (Notepad's) opens its items in an unnamed menu in a popup of the app's own window,
  so `menu` takes whichever menu wasn't open before it expanded the item.
- File Explorer's folder windows and its shell are both `explorer.exe`, so `--app explorer` is
  ambiguous there and a test gives the window's pid.
- Windows' integration test (`windowsUI`) runs in an ephemeral clone of the kept VM
  `HOBO_WINDOWS_VM` names (`windows11`, built by `make test-vms`): the test can't download an ISO.
- The Linux backend writes uinput itself (ioctls and `input_event` structs) rather than through
  python3-evdev, which Ubuntu 26.04 doesn't package for arm64; it waits until gnome-shell has
  opened the new devices, since events before then are lost.
- GTK 4 reports AT-SPI window coordinates relative to the window's frame, not its buffer (which
  includes the client-side shadow), so the extension's frame rect is the origin.
- GTK 4 menu items carry no name of their own; they're named by their labelled-by targets.
- GNOME's file chooser is the portal's, a window of Nautilus's process that the shell attributes
  to the app it's transient for. The extension reports transient windows, a pid with only those
  goes by its AT-SPI name, and `choose` looks for the chooser in every app. Its save mode takes
  the folder in the location bar and the file name in a separate File Name box.

## Deferred

- A long-lived hobo ui backend per boot, if measured per-command latency is still too slow
- `hobo exec` forwarding the host's stdin, now that exec has a stdin frame

## Original prompt

/design hobo-ak7

## Interview

**Q1. Where does the OS-neutral logic run for Linux and Windows?** A: shared Swift driver, thin
guest backends · B: full port per guest language · C: one Go tool · D: cross-compile hobo-ui.
Recommended A. **A.**

**Q2. How do Linux guests get real input?** A: uinput virtual device · B: Mutter RemoteDesktop
D-Bus · C: host-side NSEvents into VZVirtualMachineView · D: AT-SPI actions only. Recommended A. **A.**

**Q3. Where do Linux element frames get their screen position?** A: hobo's own GNOME Shell
extension · B: org.gnome.Shell.Introspect (unsafe mode only) · C: window-relative frames only.
Recommended A. **A.**

**Q4. How many guest processes does one hobo ui command start?** A: one, spoken to over
stdin/stdout, needing an exec stdin frame · B: a long-lived backend per boot · C: one exec per
backend call. Recommended A. **A.**

**Q5. What is the Windows backend written in?** A: C# compiled in the guest with .NET Framework's
csc.exe · B: PowerShell with Add-Type per command · C: Go with raw COM · D: .NET exe built on the
host. Recommended A. User: "we can create a windows VM to build inside."

**Q5 (revised). How does the VM-built Windows backend reach share/hobo?** A: commit the NativeAOT
exe, regenerated by `make windows-ui` in an ephemeral Windows build VM, with a digest check in
`make test` · B: build in the VM on every make sign/release · C: CI on a hosted Windows arm64
runner. Recommended A. **A.**

**Q6. What role names does a Linux or Windows snapshot show?** A: macOS's current names · B: native
names · C: a neutral vocabulary such as ARIA. Recommended A. User asked for open-source precedent:
W3C Core-AAM maps ARIA roles to AX, UIA and AT-SPI; Playwright aria snapshots (the format model)
print ARIA roles; AccessKit uses an ARIA-like enum; Appium, pywinauto and dogtail stay native, at the
cost of per-platform selectors. Recommendation revised to C (ARIA through Core-AAM, plus window,
text and scrollarea; macOS changes too, which pre-release costs nothing). **C.**

**Q7. Does Linux need anything turned on in the recipe?** A: part of the desktop step, always on ·
B: behind [gui_testing] on Linux too. Recommended A. **A.**

**Q8. What does --app accept on Linux and Windows?** A: each platform's analogue of bundle ID,
name, pid · B: pid and window title only. Recommended A. **A.**

**Q9. What does menu "A > B" do on Linux and Windows?** A: real menu bars, a hinted failure without
one · B: also treat A as a header-bar menu button · C: macOS only. Recommended A. **A.**

**Q10. Does choose come to Linux and Windows?** A: port it (Ctrl+L on GTK, File name box on
Windows) · B: macOS only. Recommended A. **A.**

**Q11. How does Linux type handle characters off the US layout?** A: Ctrl+Shift+U through IBus · B:
AT-SPI insert_text · C: ASCII only. Recommended A. **A.**

**Q12. What do the integration tests cover?** A: macOS's shape per OS (Text Editor and Files;
Notepad and Explorer) plus host unit tests · B: a smoke test per OS. Recommended A. **A.**
