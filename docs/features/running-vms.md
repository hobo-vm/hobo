---
title: Running VMs
description: Build named VMs, run them headless in the background, and open a window only when you want one.
sidebar:
  order: 30
---

VMs have names, and `hobo list` shows them all with their state and disk use. `hobo start` boots
a VM in the background under launchd and returns once SSH answers: it's headless and never takes
focus, so it can run all day without getting in your way. `hobo view` opens a window onto it when
you want one.

```console
$ hobo start ubuntu
Starting ubuntu
  waiting for a DHCP lease
  waiting for SSH on 192.168.64.6
ubuntu is running (192.168.64.6)

$ hobo list
NAME     STATE    ADDRESS       OS                     CPUS  MEMORY  DISK (USED/SIZE)  SNAPSHOTS
mac      stopped                macOS 27.2.0 (26B123)  4     8 GB    29.59 GB / 80 GB  —
ubuntu   running  192.168.64.6  Ubuntu 26.04           4     4 GB    6.26 GB / 32 GB   —
```

<!-- more -->

## Build

```sh
hobo create dev                  # from ./Hobo.toml
hobo create ci recipes/ci.toml   # from another recipe
```

`create` installs the OS, applies the guest conventions, runs the recipe's `[[provision]]` steps,
and shuts the VM down cleanly. A failed or interrupted build deletes the half-built VM;
`--hold-on-failure` keeps it running for SSH until you press ^C, so you can see what went wrong.

Each VM is a bundle, `~/Hobo/<name>.hobovm`, that holds its disk, configuration, the recipe it was
built from, and its snapshots. `HOBO_VMS` points hobo at another directory. Disks are ASIF, so a
VM takes only the space its guest uses, and gets space back when the guest deletes files.

## Start and stop

```sh
hobo start dev          # headless, in the background
hobo start dev --gui    # and open its window once the guest is ready
hobo stop dev           # clean shutdown
hobo stop dev --force   # power off now
```

- `start` waits until the guest answers SSH. ^C stops the wait but leaves the VM booting.
- Each VM runs in its own process under launchd, so it keeps running after the terminal closes,
  and there's no daemon to manage.
- `stop` shuts the guest down over SSH, or asks it to, and powers it off if it's still on after
  that. `--force` powers off at once.
- A suspended VM resumes on `start`. See [Suspend and resume](./suspend-resume.md).

## Look at it

```sh
hobo view dev
```

The window comes to the front with its own Dock icon, a chalk sign in a color chosen from the VM's
name, so several VMs are easy to tell apart. The guest's display follows the window's size, and
macOS and Windows guests [share the clipboard](./clipboard.md) with the Mac while it shows. Closing
the window asks whether to keep the VM running headless, suspend it, or shut it down. With the window
showing, `hobo list` says `running (window)`.

## List

```sh
hobo list        # every VM, its state, address and disk use
hobo list -v     # with each VM's snapshots
```

`USED` is a VM's own files, in full even where a clone shares them. `TOTAL` counts every block once,
so it can be less than the rows add up to.

## Rename and delete

```sh
hobo rename dev old-dev
hobo delete old-dev          # asks first; --yes doesn't
hobo delete old-dev --force  # power it off first if it's running
```
