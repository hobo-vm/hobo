# Hobo

First-class CLI for ephemeral VMs (macOS, Linux, Windows) on Apple Silicon hosts, built on Apple's
Virtualization framework: a command-line replacement for VirtualBuddy/Parallels/Fusion. VMs are built from `Hobo.toml` recipes, and there are no boxes. The design record is
`docs/design.md`; read it before architectural changes, and update it when a decision changes.

`CONTRIBUTING.md` is the source for setup, building, testing, docs, the codebase's rules, issue
labels and PRs. Read it before building or testing; what follows adds only what it doesn't say.

## Work tracking

Deferred work is tracked in GitHub Issues on `hobo-vm/hobo` (`gh issue list`, or `todo` / `/todo`).
Priority is a `P0`–`P4` label; `deferred` and `later` mark shelved work. Work found along the way
that is out of scope becomes a new issue rather than part of the current change.

## Building and testing

- Anything that boots a VM must use a signed build (`make sign`).
- `make integration-test` holds a host-wide lock, so runs from different worktrees queue.
- Manual VM testing isn't locked: only one worktree boots macOS VMs by hand at a time. Issues that
  need to are labelled `slot:macos-vm`, and `todo` won't start a second one while one is in progress.

## Architecture rules

The rules in `CONTRIBUTING.md` ("Rules of the codebase") apply in full. In particular: all logic
lives in `HoboCore`/`HoboVM`, VM processes never take focus, agents test inside guests via SSH and
never by driving the host UI, and never `await` between a `Process`'s `run()` and `waitUntilExit()`.
