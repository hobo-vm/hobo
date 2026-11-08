---
title: Clones and ephemeral VMs
description: Copy a VM instantly, or start a throwaway copy that deletes itself when you're done.
sidebar:
  order: 70
---

`hobo clone` copies a stopped VM instantly, since APFS shares the disk blocks until either VM
changes them, and the copy can run beside the original. `hobo start --ephemeral` goes one step
further: it boots a throwaway clone that deletes itself when it stops, or after half an hour
idle. Build a VM once, then try anything in a fresh copy.

```console
$ hobo start dev --ephemeral
Cloned dev to dev-6b62
Starting dev-6b62
  waiting for a DHCP lease
  waiting for SSH on 192.168.64.6
dev-6b62 is running (192.168.64.6); deleted after 30m idle

$ hobo stop dev-6b62
  shutting down over SSH
Stopped and deleted dev-6b62, which was ephemeral
```

<!-- more -->

## Clone

```sh
hobo clone dev experiment
hobo clone dev throwaway --ephemeral   # deleted after its first run
```

- The source must be stopped.
- A clone gets its own machine identifier, serial number and MAC address, so it runs beside the
  original with its own network address.
- It shares the source's disk blocks until either one changes them, so a clone of an 80 GB VM
  takes a few seconds and almost no space. `hobo list`'s `TOTAL` counts shared blocks once.
- Snapshots aren't copied.

## Ephemeral VMs

```sh
hobo start dev --ephemeral                    # clone, start, print the clone's name
hobo start dev --ephemeral --idle-timeout 2h  # or 90s, 30m, off
```

An ephemeral VM is named `<vm>-<4 hex digits>`, and `hobo list` marks it `ephemeral`, with the time
it has left. It's deleted:

- when it stops, however it stops: `hobo stop`, a shutdown inside the guest, or a crash;
- when it has sat idle for its timeout, 30 minutes unless `--idle-timeout` says otherwise. Any
  hobo command on it except `list` resets the clock; plain SSH doesn't.

A suspended ephemeral VM is kept, and `hobo discard` deletes it. Ephemeral VMs can't have snapshots.

## Keep one

```sh
hobo set dev-6b62 --keep
hobo rename dev-6b62 repro-1234
```

`--keep` turns an ephemeral VM into a regular one, even while it's running, so an experiment that
found something can stay.
