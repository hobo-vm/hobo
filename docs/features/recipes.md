---
title: Recipes
description: Describe a VM in a Hobo.toml file, and build it the same way every time.
sidebar:
  order: 10
---

A recipe is a TOML file, conventionally `Hobo.toml`, that says what a VM is built from and how
it's set up. `hobo init` writes a starter that's already pinned to an exact macOS build or Ubuntu
release, and `hobo validate` checks a recipe without building anything. Every VM gets the same
conventions (user `hobo`, password `hobo`, passwordless sudo, SSH); `[[provision]]` steps add
the rest.

```sh
hobo images                        # macOS builds this Mac can run
hobo init 26B123                   # a Hobo.toml pinned to that build
hobo validate
```

<!-- more -->

## Start a recipe

`hobo init` writes `Hobo.toml` in the current directory. `--os` picks the guest:

| Command | Guest |
| --- | --- |
| `hobo init` | The newest macOS this Mac supports, unpinned (`ipsw = "latest"`) |
| `hobo init 26B123` | That macOS build, pinned |
| `hobo init --os linux` | The newest Ubuntu LTS, pinned, with a desktop |
| `hobo init --os linux 26.04 --server` | Ubuntu 26.04 without a desktop |
| `hobo init --os windows ~/Downloads/Win11_Arm64.iso` | Windows 11 on Arm, from an ISO you downloaded |

`-o` writes a different file, so one directory can hold several recipes, and `hobo create` takes
the file to build from:

```console
$ hobo init --os linux -o linux.toml
$ hobo init --os windows ~/Downloads/Win11_Arm64.iso -o windows.toml
$ hobo create ubuntu linux.toml
```

`--force` overwrites an existing recipe file.

## Pick an image

`hobo images` lists what you can pin to. macOS builds come from ipsw.me, Ubuntu images from
cloud-images.ubuntu.com:

```console
$ hobo images
NAME                  VERSION  BUILD   RELEASED    SIZE
macOS 27 Golden Gate  27.2     26B123  2026-10-26  25.6 GB
macOS Tahoe           26.6.2   25G83   2026-08-17  19.77 GB
macOS Sequoia         15.6.1   24G90   2025-08-20  16.81 GB

$ hobo images --os linux
NAME              VERSION  CODENAME           RELEASE   SUPPORT ENDS  SIZE
Ubuntu 26.10      26.10    Stonking Stingray  20261105  2027-07-15    977.8 MB
Ubuntu 26.04 LTS  26.04    Resolute Raccoon   20261016  2031-05-29    940.4 MB
Ubuntu 24.04 LTS  24.04    Noble Numbat       20261017  2029-05-31    616.5 MB
```

Only the newest build of each version is listed; `--all` lists every one. macOS before 15 isn't
listed, and `create` refuses it. `hobo images 26B123`
shows one build's URL, SHA-256 and size. There's no catalog for Windows: bring a Windows on Arm
ISO from [Microsoft](https://www.microsoft.com/en-us/software-download/windows11arm64).

Downloads land in `~/Downloads` under the vendor's filename, where you can see and delete them,
and are checked against the recipe's SHA-256 before use.

## What a recipe holds

```toml
cpus   = 4          # macOS defaults: 4 CPUs, 8GB memory, 80GB disk
memory = "8GB"
disk   = "80GB"

[source]
ipsw   = "https://updates.cdn-apple.com/…/UniversalMac_27.2_26B123_Restore.ipsw"
sha256 = "…"

[[provision]]       # run once each, in order, over SSH
type   = "shell"
inline = "softwareupdate --install-rosetta --agree-to-license"

[[provision]]
type        = "file"
source      = "files/zshrc"           # relative to the recipe
destination = "/Users/hobo/.zshrc"
```

- **`[source]`** holds exactly one of `ipsw` (macOS), `image` (a Linux cloud image) or `iso`
  (a Windows installer), with its `sha256`. The key decides the guest OS. `ipsw = "latest"` is
  the only unpinned source: `hobo create` warns and prints the lines to pin it with.
- **`cpus`, `memory`, `disk`** are the VM's starting size. [`hobo set`](./changing-a-vm.md)
  changes them later.
- **`[[provision]]` steps** run once each, in order, at the end of `hobo create`:
  - `type = "shell"` with `inline` or `path` (a script next to the recipe), plus `privileged`
    (run as root; the default) and `env` (a table of environment variables).
  - `type = "file"` copies `source` from the host to `destination` in the guest.
  - On Windows, scripts are PowerShell.
- **`[security]`** (macOS only) turns off SIP and AMFI. Turning SIP off needs one command typed in
  recoveryOS, so `create` stops and opens the VM's window for it.
- **`[gui_testing]`** (macOS only) lets SSH sessions drive the guest's UI. See
  [Screenshots and GUI testing](./gui-testing.md).
- **`[windows]`** (Windows only): `resizable_display = true` gives a 1920×1200 display that
  follows the window. See [Guest operating systems](./guests.md).

## Check a recipe

```console
$ hobo validate
Hobo.toml: Linux, 4 CPUs, 4GB memory, 32GB disk, 1 provision step(s)
```

It parses the recipe and checks that the files its steps name exist, and warns about an unpinned
source. Give it a path to check another recipe: `hobo validate recipes/ci.toml`.

## Try steps without rebuilding

A full macOS build takes a while, so `hobo provision dev` runs a recipe's steps again on a running
VM, in order, without rebuilding. Steps run again in full, so write them to be safe to repeat.

A recipe is an input to `hobo create`, not the VM's record: share it, and someone else builds the
same VM. The VM keeps a copy of the recipe it was built from.
