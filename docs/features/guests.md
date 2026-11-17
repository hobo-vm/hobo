---
title: Guest operating systems
description: macOS, Ubuntu Linux and Windows 11 on Arm guests, all on Apple's Virtualization framework.
sidebar:
  order: 20
---

Hobo runs macOS, Ubuntu Linux and Windows 11 on Arm guests, all on Apple's Virtualization
framework, all built from a recipe and used through the same commands. macOS installs unattended
from Apple's IPSW, Linux from Ubuntu's cloud images, and Windows from a Microsoft ISO without ever
showing Setup.

```sh
hobo init --os linux && hobo create ubuntu
hobo exec ubuntu -- uname -a
```

<!-- more -->

Every guest gets the same conventions, so commands work alike across them: a `hobo` user with
password `hobo`, passwordless sudo (an administrator on Windows), SSH with hobo's insecure
key, and no sleep or automatic updates.

## macOS

```sh
hobo images                  # pick a build
hobo init 26B123
hobo create mac
```

- The IPSW is downloaded to `~/Downloads`, verified, and installed with no clicks. The `hobo`
  user is logged in at boot. A download bigger than the disk's free space is refused as it starts.
- A guest can't be newer than the host. Running a beta guest needs Apple's Device Support package
  (or the matching Xcode beta) on the host, and `create` names it if it's missing.
- macOS allows at most **2 running macOS guests** per host. Linux and Windows guests don't count.
- Disks under about 50 GB can fail macOS updates; the default is 80 GB.
- `[security]` turns SIP and AMFI off, and `[gui_testing]` grants the permissions UI tests need.
  See [Recipes](./recipes.md).

## Linux

```sh
hobo images --os linux       # supported Ubuntu versions
hobo init --os linux 26.04   # with a desktop; add --server for a text console
hobo create ubuntu
```

- Built from Ubuntu's cloud images, set up by cloud-init on first boot.
- `hobo init --os linux` adds a first step that installs Ubuntu's minimal desktop, with `hobo`
  logged in and the screen never locking, for [`hobo view`](./running-vms.md) and
  [GUI testing](./gui-testing.md). `--server` leaves it out.
- Shared folders appear at `/mnt/hobo/<folder>`.

## Windows

```sh
hobo init --os windows ~/Downloads/Win11_25H2_English_Arm64.iso
hobo create win
hobo exec win -- powershell.exe -Command 'Get-ComputerInfo | Select-Object OsName'
```

- Bring a Windows on Arm ISO from
  [Microsoft](https://www.microsoft.com/en-us/software-download/windows11arm64); there's no
  catalog. `create` installs it without Setup's screens in about 8 minutes, and a clone boots to
  SSH in about 11 seconds.
- `hobo` is an administrator, logged in at boot. SSH's shell is PowerShell, so `hobo exec` and
  `[[provision]]` scripts are PowerShell.
- The display is a fixed 1024×768, which the window scales. `[windows] resizable_display = true`
  gives 1920×1200 that follows the window, but installs a test-signed display driver, so Windows
  runs in Test Mode with a watermark on the desktop.
- Shared folders appear as `Z:\<folder>`.

> **Check before relying on Windows.** It runs through a private Virtualization framework setting
> that a macOS update could remove. Microsoft authorizes only Parallels for Windows 11 on Apple
> Silicon, so check the licence before using it for work.
