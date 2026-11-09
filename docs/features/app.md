---
title: The Hobo app
description: A Mac app for your VMs, for when you'd rather click than type.
sidebar:
  order: 35
---

Hobo.app lists your VMs with their state and disk use. From it you can start, stop, suspend, open
a VM's window, clone, rename and delete VMs, and change their settings. **New VM** builds one
without a recipe file. The app and the `hobo` command are the same program, so they always agree.
Use either, or both at once.

<!-- more -->

## Install

`make install` puts Hobo.app in `/Applications` and links `/usr/local/bin/hobo` to the command
inside it. If you install the app another way, choose **Hobo › Install Command Line Tool…** to make
the same link. It asks for an administrator's password, since `/usr/local/bin` belongs to the system.

## The library

The sidebar lists every VM in `~/Hobo` with its icon and state, using the words `hobo list` uses.
It keeps up with changes made anywhere, including VMs started or stopped with the `hobo` command.
Select a VM to see its details: OS, address, disk used, snapshots, and where its bundle is.

The toolbar starts, stops, suspends and deletes the selected VM, opens its window, and clones it.
Right-click a VM for those actions and for **Rename…**, **Discard Saved State** (for a suspended VM)
and **Show in Finder**.

Quitting the app never stops a VM: each one runs in its own process, as it does when the `hobo`
command starts it.

## Settings

The detail pane edits what [`hobo set`](./changing-a-vm.md) changes: CPUs, memory, disk size and
shared folders, and **Keep** for an ephemeral VM. **Save** applies the changes the same way `set` does:

- The VM must be stopped, except for **Keep**. The fields are locked while it runs and say why.
- The disk only grows. The guest grows into the new space at its next start.
- **Add Folder…** shares a folder, and **Read-only** stops the guest writing to it, as `--share
  folder:ro` does.

## New VM

**File › New VM…** (⌘N) asks for:

- **Name**
- **System:** macOS, Linux (Ubuntu) or Windows 11 on Arm
- **Version:**
  - macOS: a build from the same list as `hobo images`, or **Latest**.
  - Ubuntu: a release, with or without a desktop.
  - Windows: the installer ISO you downloaded.
- **CPUs, memory and disk**
- **GUI testing:** macOS only. Turns on [`[gui_testing]`](./gui-testing.md).

The app writes the [recipe](./recipes.md) `hobo init` would, with these settings, and builds the VM
from it. The progress appears in the sidebar and the detail pane. The VM keeps a copy of the recipe
in its bundle, as every VM does.

**File › Create from Recipe…** (⌘O) builds from a `Hobo.toml` you already have, for provision steps
and everything else a recipe can say.

The build runs inside the app, one at a time. Closing the window doesn't stop it. Quitting the app
asks first, because it cancels the build and deletes the half-built VM, as interrupting
`hobo create` does.
