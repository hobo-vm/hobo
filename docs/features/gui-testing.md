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
| Windows | Nothing more: `vagrant` is logged in at boot |

## Run in the desktop session

```sh
hobo exec dev --gui -- open -a TextEdit
hobo exec dev --gui -- osascript -e 'tell application "System Events" to keystroke "hello"'
```

A plain `hobo exec` runs in a background session that can't see the desktop. `--gui` runs the
command in `vagrant`'s desktop session instead, waiting up to a minute for it to come up, and exits
with status 125 if it never does.

## Driving the UI

- **macOS:** `[gui_testing]` in the recipe grants Accessibility, Screen Recording and System Events
  automation to `sshd`, `osascript`, `screencapture` and Terminal, so AppleScript and XCUITest work
  over SSH with SIP still on. `allow` adds your own test runners by path or bundle ID:

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
