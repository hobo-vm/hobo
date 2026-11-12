# `waitUntilExit` across threads: spike

Why `HostTar` waits for tar through a `terminationHandler`, not `waitUntilExit()`.
`GuestAgentTests.getOfASingleSourceBecomesTheDestination` once hung for 35 minutes: tar had
exited, but `-[NSTask waitUntilExit]` was still parked in its run loop. `GuestAgent.get()`
launches tar, awaits the copy, then waits for tar on whatever thread it resumed on.

**Result: `waitUntilExit()` on a thread other than the one that called `run()` can miss the
exit.** Sometimes the wait just stalls until something else wakes that thread's run loop, and
sometimes nothing does and it blocks for good. Launching and waiting on the same thread never
hung, even from a Swift-concurrency task. Run on 2026-11-11 on macOS 27.2.1, Swift 6.4.2, M5 Pro.

The rule (in `CLAUDE.md`): never `await` between a `Process`'s `run()` and `waitUntilExit()`.
Wait on a `terminationHandler` instead.

## Running it

```sh
swiftc -O -parse-as-library main.swift -o spike
./spike <variant> <iterations> <concurrency>    # e.g. ./spike hop 5000 16
```

A wait still blocked 10 s after it began counts as hung, and the run exits 2.

## Results

| Variant | What it does | Result |
|---|---|---|
| `plain` | `/usr/bin/true`: launch and `waitUntilExit()` in one task, same thread | never hung (15,000+ waits per width, widths 4/16/64); slowest wait under 10 ms |
| `hosttar` | `HostTar`'s shape: `tar -x` from a stdin pipe, stderr read on a detached thread, same thread | never hung (15,000 waits) |
| `thread` | `plain` on detached `Thread`s | never hung (15,000 waits) |
| `handler` | `plain`, waiting on a `terminationHandler` semaphore | never hung (15,000 waits) |
| `hop` | launch in a task, `await` work on another thread, then `waitUntilExit()` | hung in 3 of 6 runs (2–7 stuck waits, every one launched on another thread); runs that finished still had waits stalled up to 6.5 s |
| `hopfix` | `hop`, waiting on a `terminationHandler` semaphore | clean in 3 of 3 runs; slowest wait under 10 ms |
| `gone` | launch on a detached thread that then exits, wait from a task | never hung (15,000 waits) |
