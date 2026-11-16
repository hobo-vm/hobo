---
title: Agents
description: A Claude Code skill and JSON output on every command, so coding agents can test in clean VMs.
sidebar:
  order: 100
---

Hobo is built for coding agents as well as people. `hobo claude install` gives Claude Code a skill
for testing in clean VMs, every command takes `--json`, and `hobo usage` prints the whole reference
in one read. An agent can start a throwaway VM, build and test inside it, screenshot the desktop, and
leave nothing behind, all without touching the host's screen.

```sh
hobo claude install     # the hobo skill, in ~/.claude/skills/hobo
```

<!-- more -->

## The Claude Code skill

```sh
hobo claude install              # for every project
hobo claude install --project    # for this git repository only
hobo claude uninstall
```

The skill teaches Claude when and how to use hobo: test in an
[ephemeral clone](./clones.md) of a prepared VM, run builds and tests with `hobo exec`, and check
UI with [`hobo screenshot`](./gui-testing.md). Ask Claude to "test this on a clean macOS install"
and it reaches for hobo.

`hobo claude install` replaces an earlier copy that hobo wrote, but won't overwrite a `hobo` skill
someone else put there without `--force`. `make install` refreshes the installed skill, so it always
matches the binary.

## JSON output

Every command except `ssh` and `usage` takes `--json`:

```console
$ hobo exec dev --json -- true
{
  "exitStatus" : 0
}
```

- Quick commands print one JSON document.
- Long ones (`create`, `start`, `stop`, `suspend`, `provision`, `snapshot save` and `restore`) print
  JSON Lines: `{"event":"log","message":…}` as they go, then `{"event":"result","result":…}`.
- A failure is `{"error":…}` (or an `error` event) on stdout, with exit status 1. The message goes
  to stderr too, so piping stdout into `jq` doesn't hide it.
- Sizes are bytes and dates ISO 8601.
- A VM (in `list`, and from `create`, `clone`, `set` and `rename`) has its `name` and `state` at the
  top and what it is set to under `config`: `.config.os`, `.config.cpus`, `.config.ephemeral`,
  `.config.guiTesting`.
- `exec` and `cp` send the guest's output to stderr, print `{"exitStatus":…}`, and exit with that
  status.

## The whole reference at once

```sh
hobo usage
```

prints every command's help followed by the conventions they share, generated from the same
definitions as `--help`, so it can't fall behind.

## Leaving no trace

[Ephemeral VMs](./clones.md#ephemeral-vms) are made for agents: each one is deleted when it stops,
and stops itself after 30 minutes idle, so an agent session that ends abruptly doesn't leave VMs
running. VM windows never take focus unless a person opens one, so agents can work while you keep
using the Mac.
