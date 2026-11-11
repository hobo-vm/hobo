---
title: Screenshots and GUI testing
description: Screenshot a guest's desktop and drive its UI over SSH, with nothing on the host taking focus.
sidebar:
  order: 90
---

`hobo screenshot` saves a PNG of a guest's desktop, and `hobo exec --gui` runs a command in the
guest's desktop session, so UI tests run inside a clean VM over SSH. Nothing on the host takes
focus, and no window needs to be open: a headless VM keeps its display at full size.

```console
$ hobo screenshot ubuntu
/Users/me/ubuntu-20261108-162240.png
```

![An Ubuntu guest's desktop, captured with hobo screenshot](../images/linux-desktop.png)

<!-- more -->

## Screenshots

```sh
hobo screenshot dev                 # a new dev-<timestamp>.png here
hobo screenshot dev -o shot.png     # that file, replacing it
hobo screenshot dev -o - | open -f -a Preview
```

The capture runs inside the guest's desktop session, which each guest needs:

| Guest | Needs |
| --- | --- |
| macOS | A VM built from a recipe with `[gui_testing]` |
| Linux | A desktop: `hobo init --os linux` adds one; `--server` leaves it out |
| Windows | Nothing more: `hobo` is logged in at boot |

## Run in the desktop session

```sh
hobo exec dev --gui -- open -a TextEdit
hobo exec dev --gui -- osascript -e 'tell application "System Events" to keystroke "hello"'
```

A plain `hobo exec` runs in a background session that can't see the desktop. `--gui` runs the
command in `hobo`'s desktop session instead, waiting up to a minute for it to come up, and exits
with status 125 if it never does.

## Drive a macOS app with hobo ui

`hobo ui` drives a macOS guest's apps through accessibility, from the host, with nothing to
install in the guest. `snapshot` prints an app's windows as a tree, each element with a ref to act
on:

```console
$ hobo exec dev -- open -a TextEdit
$ hobo ui dev wait --app TextEdit
TextEdit is running with a window
$ hobo ui dev snapshot --app TextEdit
app TextEdit (com.apple.TextEdit) pid 628
- window "Untitled" [e1] (213,86 586×488)
  - scrollarea [e2] (213,154 586×420)
    - textarea [e3] #First Text View (213,186 586×382) focused
  - group "Formatting" [e22] (213,118 586×36)
    - checkbox "bold" [e23] (221,127 22×20) unchecked
    …
$ hobo ui dev type "Hello" --into e3 --app TextEdit
$ hobo ui dev menu "Format > Font > Bold" --app TextEdit
$ hobo ui dev wait --text "Hello" --app TextEdit
```

| Command | Does |
| --- | --- |
| `snapshot` | Prints the tree. `--all` adds offscreen elements and long lists in full, `--root e12` one subtree, `--depth N` fewer levels |
| `click <ref\|x,y>` | A real click at the element's centre, failing if something covers it. `--text Remove` clicks the one element showing exactly that text, and `--role menuitem` narrows it. `--right`, `--double`, `--mods cmd,shift`; `--press` uses AXPress instead |
| `drag <from> <to>` | A real drag, pausing over the target before it drops |
| `scroll <ref\|x,y> <direction> [lines]` | Scroll wheel events; `scroll --to e40` brings an element into view |
| `type <text> [--into ref]` | Types text where the cursor is, whatever the keyboard layout. `--replace` selects all first, so the text replaces what the field had |
| `key <cmd+k>` | Presses a key with modifiers |
| `menu "File > Save"` | Chooses a menu item, failing if it's disabled; `menu File` lists the items with their shortcuts |
| `choose <path>` | Chooses a file or folder in the open or save panel an app is showing: goes to the path, then clicks Open or Save |
| `wait` | Waits for `--ref`, `--text` or `--app`, or with `--gone` for it to go. On a timeout it prints the snapshot |

- **Refs** keep their numbers across snapshots while the element is there, so `e12` from an earlier
  snapshot still means the same thing. One that has gone fails as stale rather than clicking
  whatever took its place. Give the controls of an app you're testing accessibility identifiers
  (the `#saveButton` after a ref), and its refs survive layout changes.
- **Coordinates** are screenshot pixels, the same as in a `hobo screenshot` PNG.
- `--app` takes a bundle ID, a name or `pid:<n>`; without it, the frontmost app.
- `--json` prints any command's result as JSON, failures included.
- Each call takes about a third of a second. The VM needs `[gui_testing]`.
- To launch an app with environment variables or arguments, use `hobo exec dev -- open -n --env
  KEY=value /Applications/App.app --args …`.

## Driving the UI yourself

- **macOS:** `[gui_testing]` in the recipe grants Accessibility, Screen Recording and System Events
  automation to hobo's guest agent, `osascript`, `screencapture` and Terminal, so `hobo ui`,
  AppleScript and XCUITest work with SIP still on. `allow` adds your own test runners by path or
  bundle ID:

  ```toml
  [gui_testing]
  enabled = true
  allow   = ["com.example.AppUITests.xctrunner"]
  ```

- **Linux:** the desktop has accessibility on for AT-SPI, with the Python bindings installed.
- **Windows:** UI Automation, through `powershell.exe` in the desktop session.

## Test in a clean copy every time

Build a VM once with everything your tests need, then run each test in an
[ephemeral clone](./clones.md) that deletes itself afterwards:

```sh
vm=$(hobo start ui-base --ephemeral --json | jq -r 'select(.event=="result").result.name')
hobo cp -r ./build "$vm":/tmp/
hobo exec "$vm" --gui -- /tmp/build/run-ui-tests
hobo screenshot "$vm" -o failure.png
hobo stop "$vm"
```
