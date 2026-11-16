---
title: Changing a VM
description: Resize CPUs, memory and disk, share folders, and run a recipe's steps again on an existing VM.
sidebar:
  order: 80
---

A recipe gives a VM its starting size; `hobo set` changes it afterwards: CPUs, memory, disk size
and shared folders. The disk grows in place, and the guest's filesystem grows into the new space on
its next boot. `hobo provision` runs a recipe's steps again on a running VM, to try them out or to
bring an older VM up to date.

```console
$ hobo set dev --cpus 6 --memory 8GB --disk 120GB
Growing the disk image to 120GB
dev: 6 CPUs, 8 GB memory, 120 GB disk
The guest grows into the larger disk at the next hobo start dev.
```

<!-- more -->

## Resize

```sh
hobo set dev --cpus 8
hobo set dev --memory 16GB
hobo set dev --disk 200GB
```

- The VM must be stopped (not suspended: its saved state fits only its old size).
- The disk only grows. Its image grows at once, and the guest's filesystem grows into the space at
  the next `hobo start`, on macOS, Linux and Windows alike.
- Settings combine: `hobo set dev --cpus 8 --memory 16GB` does both.

## Share folders

```sh
hobo set dev --share ~/src --share ~/data:ro
hobo set dev --unshare data
```

See [Getting inside](./getting-inside.md#share-folders) for where shares appear in each guest.

## Run a recipe's steps again

```sh
hobo provision dev               # ./Hobo.toml's [[provision]] steps
hobo provision dev recipes/ci.toml
```

The VM must be running. Every step runs again, in order; the rest of the recipe (source, size) is
ignored. Write steps to be safe to repeat, and iterate on them here instead of waiting for a full
`hobo create`.

## Rename, keep, delete

```sh
hobo rename dev old-dev       # stopped or suspended VMs only
hobo set dev-6b62 --keep      # an ephemeral VM stays when it stops
hobo delete old-dev
```
