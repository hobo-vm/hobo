---
title: Getting inside
description: SSH in, run commands, copy files and share folders, with no keys or addresses to look up.
sidebar:
  order: 40
---

`hobo ssh` logs in, `hobo exec` runs a command and exits with its status, and `hobo cp` copies
files either way. There are no keys or IP addresses to look up: hobo knows each VM's address and
logs in with hobo's own well-known key. Host folders can be shared into the guest, read-only if you like.

```console
$ hobo exec dev -- uname -a
Linux dev 7.0.0-38-generic #38-Ubuntu SMP PREEMPT_DYNAMIC Fri Sep  4 09:28:02 UTC 2026 aarch64 GNU/Linux

$ hobo cp ./notes.txt dev:/tmp/
$ hobo ssh dev
```

<!-- more -->

## SSH

```sh
hobo ssh dev                    # a login shell
hobo ssh dev -- uptime          # a command instead
hobo ssh dev --print            # the ssh command line, to use elsewhere
```

`hobo ssh` runs the system's `ssh` as the `hobo` user, so the session, the exit status and any
command behave just as plain `ssh` does. `--print` gives a command line you can paste into scripts,
IDEs or `rsync -e`.

## Run commands

```sh
hobo exec dev -- make test
hobo exec dev -- sh -c 'cd /src && make test | tee test.log'
hobo exec win -- powershell.exe -Command 'Get-Process | Select-Object -First 5'
```

- The command runs as `hobo`, without stdin or a terminal, and `hobo exec` exits with its
  status, so it fits in scripts and CI.
- Its arguments are quoted for the guest's shell. For pipes and redirection, run a shell
  yourself: `sh -c '…'`, or `powershell.exe -Command '…'` on Windows.
- `--gui` runs the command in the desktop session instead. See
  [Screenshots and GUI testing](./gui-testing.md).
- `--json` prints `{"exitStatus": …}` and sends the command's output to stderr.

## Copy files

```sh
hobo cp ./app.zip dev:/tmp/            # host to guest
hobo cp dev:/var/log/system.log .      # guest to host
hobo cp ./build dev:/Users/hobo/       # a directory, with everything in it
```

One side names the guest as `<vm>:<path>`, and a guest path that is relative, or starts `~/`, is
from the `hobo` user's home, as it is for `hobo rm`. Paths are placed as `scp` places them: a source goes
inside a destination directory that exists, under its own name, and otherwise becomes the
destination itself.

Copying onto a directory that is already there merges into it, so files the new copy doesn't have
stay. `--replace` removes whatever each source would land on first:

```sh
hobo cp --replace ./build/MyApp.app dev:/Applications/    # no leftovers from the old MyApp.app
```

## Remove files

```sh
hobo rm dev:/tmp/app.zip dev:/Users/hobo/build    # a directory goes with everything in it
hobo rm -f dev:/tmp/maybe-there                    # no failure if it's already gone
```

`hobo rm` removes files and directories inside a VM, never the VM itself: that is `hobo delete`.
Every path names the guest as `<vm>:<path>`, and a relative one, or one starting `~/`, is from the `hobo` user's home.
It won't remove `/`, the home directory or what holds it.

## Share folders

```sh
hobo set dev --share ~/src            # every start
hobo set dev --share ~/data:ro        # read-only
hobo start dev --share ~/scratch      # this run only
hobo set dev --unshare src
```

A shared folder appears in the guest at:

| Guest | Path |
| --- | --- |
| macOS | `/Volumes/My Shared Files/<folder>` |
| Linux | `/mnt/hobo/<folder>` |
| Windows | `Z:\<folder>` |

`hobo set` needs the VM stopped. `--unshare` runs before `--share`, so
`hobo set dev --unshare src --share ~/src:ro` makes a share read-only.

## The VM's address

```console
$ hobo ip dev
192.168.64.6
```

Every VM is on macOS's shared NAT network: it reaches the internet and the host, and the host
reaches it at that address.
