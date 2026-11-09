# Hobo.app: a GUI for using VMs without the CLI, bundling the payloads

## Decisions

1. **Scope.** v1 is a library window. It lists VMs with their state, disk use and icon, and does
   start, stop, suspend, show window (`view`), clone, delete, rename, settings (`set`), and create
   with build progress. Recipe editing, snapshots, provisioning and exec/ssh stay in the CLI.
2. **One bundle, CLI inside.** `make install` installs `/Applications/Hobo.app`. The app has a menu
   item to link the CLI onto PATH.
3. **CLI link.** **Install Command Line Tool…** links `/usr/local/bin/hobo` (on every Mac's default
   PATH), asking for an administrator through `osascript … with administrator privileges`, with no
   privileged helper. `make install` makes the same link (with `sudo` if needed) and removes the
   `~/.local/bin/hobo` older builds installed, which would shadow it.
4. **Build.** `make app` assembles the bundle from SwiftPM products (Info.plist, `Hobo.icns`,
   payloads) and `make sign` signs it from the inside out with the virtualization entitlement.
   There is no Xcode project.
5. **Payloads.** The agent binaries, `hobo-ui`, the Windows boot driver and scripts, and the icon
   signs are SwiftPM resources of `HoboVM`, the plugins' outputs included, and nothing is embedded
   in code. `Payloads` reads them from `Contents/Resources` inside the app, and from SwiftPM's
   resource bundle in a bare build. It doesn't use `Bundle.module` in the app, because that accessor
   looks for the bundle at the top of `Hobo.app`, where code signing doesn't allow it.
6. **Executables.** The GUI is `Contents/MacOS/Hobo` and the CLI is `Contents/Helpers/hobo`. A tool
   outside `MacOS` isn't taken for the app, so VM processes keep their own Dock identity. It also
   avoids `Hobo`/`hobo` colliding on a case-insensitive volume.
7. **Live state.** FSEvents on the store and on hobo's home (sockets, logs, plists) re-run the same
   listing `hobo list` uses, with a 5 s poll as a fallback for what changes without touching disk
   (a window showing).
8. **Create** runs in the app's process through `VMCreator`, as in the CLI. Closing the window
   doesn't quit while a build runs, and quitting asks first, since it cancels the build.
9. **Window.** A `NavigationSplitView`: a sidebar of VMs (icon, name, state) and a detail pane with
   the VM's details and a settings form, locked when `set` would refuse.
10. **New VM sheet.** It takes a name, OS, version (from the same catalogs as `hobo images`),
    CPUs, memory, disk, and `[gui_testing]`. It writes the recipe `hobo init` would to a temporary
    directory. **Create from Recipe…** builds from an existing `Hobo.toml`.
11. **Lifecycle.** A plain app: closing the window quits it, except during a build. No menu-bar
    extra or login item in v1.
12. **Distribution** is separate work: Developer ID signing, notarization and GitHub Releases.
13. **Tests.** `HoboAppModel` has unit tests. The macOS lifecycle integration test copies Hobo.app
    into its `[gui_testing]` guest, seeds two stopped bundles, and drives the app with `hobo ui`:
    the list, a settings change and a rename (checked on disk), and a build from the New VM sheet.
    Start, stop and create are checked by hand on the host.
14. Defaults chosen without a question: bundle ID `app.gsquared.hobo`; failures show as an alert
    with the core's message; delete asks first.

## As built

- `RecipeDraft` (HoboCore) is the starter recipe for both `hobo init` and the New VM sheet. It
  overrides the template's `cpus`, `memory` and `disk` and appends `[gui_testing]`.
- `HoboInstall` (HoboCore) knows where this build lives: the app's `Contents`, and the CLI that
  launchd runs as a VM process. In a bare build that is the `hobo` beside the GUI binary, so
  `swift run HoboApp` starts VMs with `.build/debug/hobo`.
- Builds run one at a time. Quitting during one raises SIGTERM, whose `VMCreator` handler deletes
  the bundle and exits, as ^C does. With two builds in one process, the two handlers would race.
- The settings form edits memory and disk in whole gigabytes. A VM whose memory isn't a whole
  number of gigabytes keeps it until the field is changed.
- In the guest test, the settings change is memory rather than disk, because growing the disk
  resizes a disk image, which the seeded bundles don't have. The New VM build fails at once by
  reusing an existing name, since a guest can't run VMs. The build deletes its temporary recipe
  when it ends, so the test checks that it is gone; `NewVMFormTests` checks what the recipe says.

## Deferred

- A menu-bar extra listing running VMs with Show Window, Stop and Suspend (hobo-9jw)
- `make release`: Developer ID signing, notarization, GitHub Releases (hobo-8bi)

## Original prompt

hobo-ezb: Hobo.app: a GUI app for using VMs without the CLI, bundling the embedded payloads. From
designs/hobo-ui.md decision 3: "All embedded payloads move into a Hobo.app bundle when there is
one." Its bundle carries what hobo now embeds: agent binaries, hobo-ui, Windows resources. Needs
its own design.

## Interview

- **Q1 Scope.** A: library window (list, lifecycle, settings, create) · B: packaging plus a
  menu-bar item · C: full parity. **A**.
- **Q2 CLI and app on disk.** A: one bundle, CLI inside, payloads in Resources · B: separate app and
  CLI · C: app shells out to an installed `hobo`. **A**, plus: a real user installs the app into
  /Applications and needs a menu item to link the CLI; `make install` should install the app into
  /Applications.
- **Q3 Where the link goes.** A: `/usr/local/bin/hobo` with an admin prompt · B: `~/.local/bin` ·
  C: offer both. **A**.
- **Q4 Building the bundle.** A: Makefile assembles it from SwiftPM products · B: Xcode project.
  **A**.
- **Q5 Payloads in a dev build.** A: SwiftPM resources, our own locator · B: embedded in debug,
  files in the app · C: always run the assembled app. **A**.
- **Q6 Executables.** A: GUI in `MacOS`, CLI in `Helpers` · B: one executable for both · C: helper
  app bundles. **A**.
- **Q7 Live state.** A: FSEvents plus a 5 s poll · B: poll every 2 s · C: push over the socket. **A**.
- **Q8 Who runs create.** A: in-process `VMCreator` · B: spawn `hobo create --json` · C: a launchd
  build job. **A**.
- **Q9 Window.** A: sidebar and detail · B: one table. **A**.
- **Q10 New VM.** A: a sheet that writes a recipe, plus Create from Recipe · B: recipe files only ·
  C: plus a step editor. **A**.
- **Q11 Lifecycle.** A: plain app · B: plus a menu-bar extra · C: menu-bar only. **A**, and a todo
  for B.
- **Q12 Distribution.** A: separate issue · B: in this work. **A**.
- **Q13 Tests.** A: model unit tests, the UI driven with `hobo ui` in a guest · B: unit tests only ·
  C: XCUITest. **A**.
