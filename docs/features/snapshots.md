---
title: Snapshots
description: Save a VM under a tag, running apps and all, and go back to it whenever you like.
sidebar:
  order: 60
---

`hobo snapshot save` keeps a VM's state under a tag. A running VM pauses for a moment and carries
on, and its snapshot includes its memory, so restoring returns to that running moment with every app
still open. Snapshots are APFS clones, so they cost only the blocks that change afterwards.

```console
$ hobo snapshot save dev clean
Saved snapshot clean of dev (with 512 MB of saved state)

$ hobo exec dev -- sh -c 'rm -rf ~/important'      # oops

$ hobo snapshot restore dev clean --force
  forcing the VM off
Restored dev to clean
Resuming dev
  resuming
dev is running at 192.168.64.6
```

<!-- more -->

## Save

```sh
hobo snapshot save dev before-upgrade
```

| VM state | What the snapshot holds |
| --- | --- |
| Running | Disk and memory (`live`). The VM pauses for a few seconds, then runs on. |
| Suspended | Disk and saved state (`live`). The VM isn't touched. |
| Stopped | Disk only (`disk`). |

A tag can't be reused until it's deleted. Ephemeral VMs can't have snapshots;
`hobo set <vm> --keep` makes one a regular VM first.

## Restore

```sh
hobo snapshot restore dev before-upgrade
hobo snapshot restore dev before-upgrade --force   # over a running or suspended VM
```

- The VM's disk is replaced by the snapshot's, at the size it was then.
- A live snapshot resumes running, as it was. A disk-only one leaves the VM stopped.
- Restoring over a running VM (which powers it off) or a suspended one (which discards its saved
  state) needs `--force`.
- CPUs and memory stay as they are now. If they've changed since the snapshot, its memory can't be
  used, and the VM boots from the snapshot's disk with a warning.
- The snapshot is kept, so you can restore it again.

## List and delete

```console
$ hobo snapshot list dev
TAG     KIND  CREATED                 SAVED STATE  UNIQUE
clean   live  Nov 8, 2026 at 4:22 PM  512 MB       504 MB
stable  disk  Nov 8, 2026 at 4:30 PM  —            134 bytes

$ hobo snapshot delete dev stable
Deleted snapshot stable of dev
```

`UNIQUE` is what deleting that snapshot alone would free. Blocks two snapshots share are freed only
once both are gone. `hobo list` shows each VM's snapshot count and their total size, and
`hobo list -v` lists them under each VM.

Snapshots live in the VM's bundle and are deleted with it. [`hobo clone`](./clones.md) doesn't
copy them.
