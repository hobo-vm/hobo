---
title: Suspend and resume
description: Save a running VM's memory to disk, and pick up exactly where you left off seconds later.
sidebar:
  order: 50
---

`hobo suspend` saves a running VM's memory and device state to disk and stops it. `hobo start`
resumes it in a few seconds, with every app and shell where you left them and the guest's clock set
to the host's. Nothing is lost by accident: throwing the saved state away is always a separate,
explicit step.

```console
$ hobo suspend dev
  saving state
Suspended dev (608 MB saved state)

$ hobo start dev
Resuming dev
  resuming
  setting the guest's clock
dev resumed (192.168.64.6)
```

<!-- more -->

## Suspend

```sh
hobo suspend dev
```

The VM pauses, its state is saved into its bundle, and its process exits, so it uses no memory or
CPU. `hobo list` shows it as `suspended`, with the size of its saved state. If the save fails, the VM
carries on running and `suspend` says why.

From the VM's window, closing it offers **Suspend** too.

## Resume

```sh
hobo start dev
```

A suspended VM always resumes; it never boots fresh unless you ask. On resume, hobo sets the guest's
clock (it stood still while suspended) and, on macOS, remounts shared folders.

## Throw the saved state away

```sh
hobo discard dev           # leave it stopped
hobo start dev --cold      # or boot it fresh now
```

Whatever was in the guest's memory is lost, as if it had lost power. `hobo stop` refuses a
suspended VM rather than doing this for you.

## Things to know

- A suspended VM's configuration is fixed until it resumes: `hobo set` and `start --share` refuse
  it, since the saved state fits only the configuration it was saved with. `rename` and `delete`
  work.
- A suspended [ephemeral VM](./clones.md) is kept until it is resumed and stopped, or discarded.
- To keep a running moment to come back to again and again, use a
  [snapshot](./snapshots.md) instead.
