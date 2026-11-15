# hobo ui: driving macOS guest apps through accessibility

## Decisions

1. **Scope.** macOS guests only in v1, with an OS-neutral command vocabulary and JSON shapes, so
   Linux (AT-SPI) and Windows (UIA) backends can slot in later.
2. **Code.** A Swift executable target, `hobo-ui`, with its pure logic in a `HoboUICore` library.
   The Go agent stays dependency- and cgo-free.
3. **Shipping.** `hobo-ui` is embedded in `hobo` like the agent binaries; `make install` still copies
   one file. All embedded payloads move into a Hobo.app bundle when there is one. (They became files,
   in Hobo.app and then in `share/hobo` beside `bin/hobo`: docs/design.md decision 22.)
4. **Interface.** A host command, `hobo ui <vm> <command> …`, and matching MCP tools from the same
   core. The guest-side path is an implementation detail.
5. **Delivery.** On the first `ui` request after a boot, the agent fetches `ui-darwin-arm64` from
   the host's fetch port (the stub's frozen exchange is unchanged; only the agent learns the name),
   writes it root-owned under `/var/run/hobo/` (cleared at boot), and runs it as the guest user in
   its desktop bootstrap. It always matches the host's hobo. TCC attributes it to the agent's stub,
   which `[gui_testing]` grants, so no path-specific grant is needed.
6. **Refs.** One-shot processes. `snapshot` writes a per-app ref file under `/var/run/hobo/ui/`
   mapping each ref to a locator: the path from the app root of (role, AXIdentifier or title, index
   among same-role siblings). A command re-walks the locator; if nothing is there, or the role no
   longer matches, it fails with `stale ref e12: take a new snapshot`.
7. **Ref numbers carry across snapshots** by locator; new elements get the next free number; a number
   is never reused for another locator within a boot.
8. **`click <ref>`** sends a real CGEvent at the element's centre, after bringing the app forward and
   hit-testing the point (`AXUIElementCopyElementAtPosition`); if what's there isn't the element or
   a descendant, it fails and says what's in the way. `--press` uses AXPress instead. Point clicks
   (`click X,Y`) and both take `--mods`, `--right`, `--double`.
9. **Output.** `snapshot` prints a compact indented text tree (Playwright aria-snapshot style:
   `- button "Save" [e12] #saveButton (840,412 80×28) disabled`), folding unnamed layout groups and
   printing only set states. MCP returns the same text. `--json` gives every field. Other commands
   print one line, with detail under `--json`.
10. **No `run` batch in v1**; measure per-call latency over the agent first.
11. **`--app`** takes a bundle ID, a name (localized name of a running app) or `pid:N`; default is
    the frontmost app. Ambiguous names fail listing the matches. Ref files are per bundle ID.
    Point clicks, `type` and `key` need no app.
12. **No `launch`/`quit`/`focus`.** The doc shows `hobo exec dev -- open -n --env K=V App.app --args …`;
    `wait --app X` waits for the app to run and have a window.
13. **`scroll <ref|x,y> --by up|down|left|right [N]`** sends wheel events; `scroll --to e12` uses
    AXScrollToVisible, otherwise wheel events on the nearest scroll area until the element's frame
    is inside it, failing after a bound.
14. **`drag <from> <to> [--mods]`** with real CGEvents: down, intermediate drags over ~300 ms, a short
    hover on the target, up. Both ends hit-tested.
15. **`wait`** polls every 100 ms, `--timeout` default 10 s; `--ref`, `--text` (case-sensitive
    substring of any title, value or description), `--app`; `--gone` inverts. Success prints the
    match; a timeout exits non-zero and prints the current snapshot.
16. **`menu "A > B"`** presses through AXPress; fails on a disabled item; reports checked state from
    before the press. `menu "A"` lists items with enabled, checked and shortcut. Titles match
    exactly, with `…` equal to `...`. Each menu on the way is opened (AXPress) and cancelled before
    its items are read: an app brings a menu's titles and enabled states up to date only as it opens,
    so a closed Edit menu reads "Undo" where the open one shows "Undo Typing".
17. **Snapshot scope.** Windows, sheets and popovers, not the menu bar. Elements wholly outside their
    scroll area are summarised (`… N more items offscreen`); containers over 50 children show 50
    then `… N more`. `--all` lifts both, `--root e12` snapshots a subtree, `--depth N` caps depth.
18. **MCP.** One typed tool per command: `ui_snapshot`, `ui_click`, `ui_drag`, `ui_scroll`,
    `ui_type`, `ui_key`, `ui_menu`, `ui_wait`, with the CLI's parameters and output.
19. **Coordinates** are screenshot pixels everywhere (frames, points), converted by the display's
    backing scale; output says `scale N` only when it isn't 1.
20. **Tests.** Unit tests on synthetic trees in `HoboUICore` (locator matching, ref merging,
    formatting and folding, key specs, scaling); never live AX on the host. One integration test
    in an ephemeral `[gui_testing]` clone: TextEdit (type, menu, wait, click, scroll) and Finder
    (drag a file icon onto a folder icon, checked on disk).
21. Defaults chosen without a question: `type "text" [--into e12]` (clicks the element first, then
    Unicode CGEvents, layout-independent); `key cmd+shift+k` with named keys (return, esc, tab,
    space, delete, arrows, home/end, pageup/pagedown, f1–f12); `hobo ui` fails on Linux/Windows
    guests, and without `[gui_testing]` with the same message `screenshot` gives.

## As built

- `scroll` takes `scroll <ref|x,y> <direction> [lines]` (default 3), not `--by`, which
  ArgumentParser can't give an optional second value.
- The fetched binary is `/var/run/hobo-agent/hobo-ui` and refs live in
  `/var/run/hobo-agent/ui/<user>/`, under the agent's existing run directory rather than a new
  `/var/run/hobo/`.
- `hobo mcp` doesn't exist yet, so the MCP tools are a note on hobo-i2j.
- From driving TextEdit and Finder: AppKit's made-up `_NS:31` identifiers are dropped, an unnamed
  element shows its subrole (`closebutton`), zero-size elements count as offscreen, and an action's
  message shows the element as it is afterwards.

## Deferred

- `hobo ui see`: an annotated screenshot with ref-labelled boxes (Set-of-Mark)
- `hobo ui run`: batch commands in one call, if per-call latency over the agent turns out to matter
- `hobo ui snapshot --diff`: what changed since the last snapshot
- Wrappers for `log stream` filtered to one process, DiagnosticReports, and `screencapture -v` clips
- `hobo ui` backends for Linux (AT-SPI) and Windows (UI Automation) guests
- Hobo.app: a GUI app for using VMs without the CLI, whose bundle carries the embedded payloads (agent binaries, hobo-ui, Windows resources)

## Original prompt

A guest-side UI automation tool bundled with hobo and provisioned into macOS guests (with [gui_testing]) so Claude can drive apps there faster. Proposal from the Candela session: one prebuilt Swift binary at a fixed path (TCC grants are per path), JSON output, v1 commands snapshot (compact AX tree with refs), click (ref or point, modifiers, AXPress else CGEvent), type/key (CGEvent), menu (AX press, reports enabled/checked), wait (ref/text, --gone, timeout), run (batch from stdin, stop at first failure, screenshot on failure). Later: see (Set-of-Mark screenshot), host-side `hobo ui <vm>` wrapper or `hobo mcp <vm>` tools, log stream / DiagnosticReports / screencapture -v wrappers. Motivations: System Events click-at doesn't click; guest has no compiler; pixel coordinates go stale; sleep instead of waiting on conditions; each hobo exec costs seconds. Open questions: hobo subcommand vs separate guest binary, MCP vs CLI first, ref format and ref stability across snapshots. Prior art to check: Peekaboo/AXorcist, Playwright aria snapshots, cliclick, AXSwift, macapptree, Hammerspoon hs.axuielement, Appium mac2.

## Interview

- **Q1 Platform scope.** A: macOS only, OS-neutral vocabulary · B: macOS only, AX-shaped · C: all three. **A**, plus: the hobo-agent-over-virtio-vsock worktree (Go agent replacing SSH) merges soon.
- **Q2 Where the driver's code lives.** A: Swift target compiled into hobo, delivered when needed · B: in the Go agent via cgo · C: the hobo binary itself in the guest. **A**, plus: Greg wants a proper macOS GUI app later, which would make bundling extra things easier than embedding them in the CLI.
- **Q3 How hobo-ui ships for now.** A: embed in hobo, move to Hobo.app later · B: minimal Hobo.app now · C: sibling file in libexec. **A**.
- **Q4 Invocation.** A: `hobo ui <vm> …` plus MCP · B: documented guest path via exec · C: MCP only. **A**.
- **Q5 Delivery into the guest.** A: agent fetches lazily from the host, root-owned in /var/run/hobo · B: VM process `put`s it per boot · C: install at create. **A**.
- **Q6 Ref state between calls.** A: one-shot + ref file of locators, stale refs fail · B: long-running guest server · C: refs are encoded locators. **A**.
- **Q7 Ref numbers across snapshots.** A: kept by locator · B: renumbered each time. **A**.
- **Q8 What click does.** A: real CGEvent with hit-test, `--press` for AXPress · B: AXPress else CGEvent. **A**.
- **Q9 Snapshot output.** A: text tree by default, `--json` for scripts · B: JSON always. Greg asked what an agent would actually use: the text tree (agents read snapshots rather than parse them; JSON triples tokens; Playwright MCP hands models its text snapshot); `--json` is for scripts and jq. **A**.
- **Q10 `run` in v1.** A: defer, measure latency over the agent first · B: include. **A**.
- **Q11 App targeting.** A: bundle ID, name or pid, default frontmost · B: bundle ID required. **A**.
- **Q12 launch/quit/focus.** A: no, use `open` via exec, plus `wait --app` · B: wrap them. **A**.
- **Q13 Scrolling.** A: `scroll --by` and `scroll --to` · B: click auto-scrolls. **A**.
- **Q14 drag in v1.** A: yes, real CGEvents with hover · B: defer. **A**.
- **Q15 wait.** A: 100 ms poll, 10 s default, timeout prints snapshot · B: timeout prints only "timed out". **A**.
- **Q16 menu.** A: AXPress, list mode, fail on disabled · B: real clicks through menus. **A**.
- **Q17 Snapshot scope.** A: windows/sheets/popovers, offscreen and >50 children summarised, `--all`/`--root`/`--depth` · B: everything. **A**.
- **Q18 MCP shape.** A: one typed tool per command · B: one `ui` tool with a string. **A**.
- **Q19 Coordinates.** A: screenshot pixels everywhere · B: screen points. **A**.
- **Q20 Tests.** A: unit tests in HoboUICore, integration with TextEdit, drag by hand · B: plus a fixture app. **A**, but there must be a built-in app for testing drag: Finder, dragging a file icon onto a folder icon, checked on disk.
- **Q21 `see`.** A: defer with the other deferred items · B: v1. **A**.
- **Q22 Sequencing against the agent branch.** Greg: just merged it. Build everything on main.
