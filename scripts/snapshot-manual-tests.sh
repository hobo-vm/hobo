#!/bin/bash
# The hobo snapshot checks `make integration-test` doesn't make: failure paths, changed settings, a
# VM process from an older hobo, shares, a long gap before restoring, and what only a person can
# judge about the window. It builds this checkout, so the binary on your PATH doesn't matter.
#
# It works on its own clone of a stopped macOS VM and deletes that clone when it ends. It refuses
# to run if a VM with the clone's name already exists, and touches no other VM. It boots one macOS
# guest, so stop anything that would make a third, and don't run it alongside `make integration-test`.

usage() {
    cat <<EOF
Usage: scripts/snapshot-manual-tests.sh [options]

  --source <vm>      The stopped macOS VM to clone (default: macos27).
  --gap <minutes>    How long test 4 leaves a snapshot before restoring it (default: 5).
                     The clock failures in hobo-b3w followed short gaps; try 180 once.
  --old-hobo <path>  A signed hobo without snapshots, for test 9 (default: the main checkout's
                     release build, if it qualifies; otherwise test 9 is skipped).
  --only <n,n,...>   Run only these tests (default: all).
  --unattended       Ask nothing; what only a person can judge is reported as not checked.
  --keep             Leave the clone in place at the end, to look at it.
  -h, --help         Show this.

Tests:
  1  The window during a save              6  Ctrl-C during a save
  2  The window after a restore            7  Changed CPUs: restore boots from the disk
  3  Apps, processes and network           8  The disk goes back to its old size
     after a restore                       9  A VM process from an older hobo
  4  Restoring an old snapshot (runs       10 Shared folders across a restore
     last, because of its gap)
  5  A forced stop during a save

Tests 1 and 2 open a window, which comes to the front. The rest are headless.
Exits 0 if nothing failed, 1 if something did, 2 if it couldn't run.
EOF
}

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
VM=snap-manual
SOURCE=macos27
GAP_MINUTES=5
OLD_HOBO=
ONLY=
KEEP=0
ATTENDED=1
[ -t 0 ] || ATTENDED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --gap) GAP_MINUTES=$2; shift 2 ;;
        --old-hobo) OLD_HOBO=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --unattended) ATTENDED=0; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

HOBO=$REPO/.build/release/hobo
BUNDLE=${HOBO_VMS:-$HOME/Hobo}/$VM.hobovm
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hobo-snapshot-tests.XXXXXX")
LOG=$WORK/log.txt
RESULTS=$WORK/results.txt
CREATED=0
FAILED_HERE=0
UNCHECKED_HERE=0
INCONCLUSIVE_HERE=
ANY_FAILED=0
CHILD=
: > "$RESULTS"

# --- Output and results ---------------------------------------------------------------------------

note() { echo "    $*"; echo "note: $*" >> "$LOG"; }
ok() { echo "  ok    $*"; echo "ok: $*" >> "$LOG"; }
bad() {
    echo "  FAIL  $*"
    echo "FAIL: $*" >> "$LOG"
    FAILED_HERE=1
    ANY_FAILED=1
}
# check <description> <command...>: passes if the command does.
check() {
    local description=$1
    shift
    if "$@"; then ok "$description"; else bad "$description"; fi
}

# Asks the person, if there is one, about what a script can't see.
ask() {
    if [ "$ATTENDED" = 0 ]; then
        note "not checked (unattended): $1"
        UNCHECKED_HERE=$((UNCHECKED_HERE + 1))
        return
    fi
    local answer
    while :; do
        read -r -p "  ? $1 [y/n] " answer < /dev/tty
        case "$answer" in
            y|Y) ok "$1"; return ;;
            n|N) bad "$1"; return ;;
        esac
    done
}

pause() {
    [ "$ATTENDED" = 1 ] || return 0
    read -r -p "  > $1 Press Return. " _ < /dev/tty
}

# --- hobo and the guest ---------------------------------------------------------------------------

# Runs hobo, leaving what it printed in OUT and its status in RC.
hobo() {
    echo "\$ hobo $*" >> "$LOG"
    OUT=$("$HOBO" "$@" 2>&1)
    RC=$?
    { echo "$OUT"; echo "[exit $RC]"; } >> "$LOG"
    return $RC
}

guest() { "$HOBO" exec "$VM" -- sh -c "$1" 2>> "$LOG"; }
guest_answers() { "$HOBO" exec "$VM" -- true >> "$LOG" 2>&1; }

row() { "$HOBO" list 2>> "$LOG" | grep -E "^$VM +"; }
is_running() { row | grep -Eq "^$VM +running"; }
is_stopped() { row | grep -Eq "^$VM +stopped"; }
window_shown() { row | grep -Eq "^$VM +running \(window\)"; }
tag_listed() { "$HOBO" snapshot list "$VM" 2>> "$LOG" | grep -Eq "^$1 "; }
no_partial_left() { ! ls -d "$BUNDLE"/snapshots/.saving-* > /dev/null 2>&1; }
config_value() { sed -n "s/.*\"$1\"[^0-9]*\([0-9]*\).*/\1/p" "$BUNDLE/config.json" | head -1; }

# Starts the VM if it isn't running. A start straight after a forced stop may need a retry (hobo-rok).
ensure_running() {
    is_running && return 0
    local tries=0
    while [ $tries -lt 3 ]; do
        hobo start "$VM" && return 0
        tries=$((tries + 1))
        sleep 5
    done
    bad "couldn't start $VM: $OUT"
    return 1
}

ensure_stopped() {
    is_running || return 0
    hobo stop "$VM" || bad "couldn't stop $VM: $OUT"
}

# A process that shows the guest's memory came back: only a restored moment has it after a restart.
start_sleeper() { guest 'nohup sleep 86400 >/dev/null 2>&1 & echo $!' | tr -d '[:space:]'; }
sleeper_alive() { guest "ps -p $1 -o comm= | grep -qx sleep"; }

# The guest's clock against the host's, reading the host on both sides of the exec, as the
# integration test does. Every result is logged, as evidence for hobo-b3w.
clock_right() {
    local before after clock
    before=$(date +%s)
    clock=$(guest 'date +%s' | tr -d '[:space:]')
    after=$(date +%s)
    [ -n "$clock" ] || return 1
    note "guest clock $((clock - before)) s from the host (the exec took $((after - before)) s)"
    [ "$clock" -gt $((before - 5)) ] && [ "$clock" -lt $((after + 5)) ]
}

# TLS fails on a clock that is far off, so this checks more than the route out.
network_works() { guest 'curl -sS -m 30 -o /dev/null https://www.apple.com/' >> "$LOG" 2>&1; }

wait_for_window() {
    local i
    for i in $(seq 1 30); do
        window_shown && return 0
        sleep 1
    done
    return 1
}

wait_for_guest() {
    local i
    for i in $(seq 1 60); do
        guest_answers && return 0
        sleep 5
    done
    return 1
}

drop_snapshot() { hobo snapshot delete "$VM" "$1"; }

# Starts a save in the background, leaving its pid in CHILD and its output in $WORK/save.txt. With
# job control on, the shell doesn't make it ignore SIGINT as it would any background job.
background_save() {
    set -m
    "$HOBO" snapshot save "$VM" "$1" > "$WORK/save.txt" 2>&1 &
    CHILD=$!
    set +m
}

# --- Tests ----------------------------------------------------------------------------------------

test_1() {
    ensure_running || return
    local sleeper
    sleeper=$(start_sleeper)
    hobo view "$VM" || bad "hobo view: $OUT"
    pause "Open something in the window that visibly moves (Clock with seconds, a video)."
    SECONDS=0
    if hobo snapshot save "$VM" t1; then ok "the save succeeded, in $SECONDS s"; else bad "the save failed: $OUT"; fi
    check "the window is still showing" window_shown
    check "the guest's processes carried on" sleeper_alive "$sleeper"
    check "the guest's clock is right" clock_right
    ask "Did the window freeze briefly and carry on, with no crash or black screen?"
    drop_snapshot t1
}

test_2() {
    ensure_running || return
    hobo view "$VM"
    pause "Leave something recognisable on screen in the window: the restore returns to it."
    hobo snapshot save "$VM" t2 || bad "the save failed: $OUT"
    pause "Now change what's on screen, so you can tell the restore worked."
    if hobo snapshot restore --force "$VM" t2; then ok "the restore succeeded"; else bad "the restore failed: $OUT"; fi
    check "the window came back by itself" wait_for_window
    ask "Is the window showing what was on screen at the save?"
    drop_snapshot t2
}

test_3() {
    ensure_running || return
    local sleeper
    sleeper=$(start_sleeper)
    pause "If you want to check apps too: open a few in the window, or skip this with Return."
    hobo snapshot save "$VM" t3 || bad "the save failed: $OUT"
    guest "kill $sleeper"
    hobo snapshot restore --force "$VM" t3 || bad "the restore failed: $OUT"
    check "the process killed after the save is back" sleeper_alive "$sleeper"
    check "the guest's clock is right" clock_right
    check "the network works, including TLS" network_works
    check "hobo ssh works" "$HOBO" ssh "$VM" -- true
    ask "If you opened apps, are they where they were (answer y if you didn't)?"
    drop_snapshot t3
}

test_4() {
    ensure_running || return
    local sleeper
    sleeper=$(start_sleeper)
    hobo snapshot save "$VM" aged || bad "the save failed: $OUT"
    ensure_stopped
    note "waiting $GAP_MINUTES minutes before restoring"
    sleep $((GAP_MINUTES * 60))
    if hobo snapshot restore "$VM" aged; then ok "the restore succeeded"; else bad "the restore failed: $OUT"; fi
    check "the snapshot's process is back" sleeper_alive "$sleeper"
    check "the guest's clock is right at once" clock_right
    check "the network works, including TLS" network_works
    sleep 30
    check "the guest's clock is still right 30 s later" clock_right
    drop_snapshot aged
}

test_5() {
    ensure_running || return
    background_save forced
    sleep 2
    if ! kill -0 "$CHILD" 2> /dev/null; then
        wait "$CHILD" || bad "the save failed: $(tr '\n' ' ' < "$WORK/save.txt")"
        CHILD=
        INCONCLUSIVE_HERE="the save finished in under 2 s, before the forced stop"
        drop_snapshot forced
        return
    fi
    hobo stop --force "$VM" || bad "the forced stop failed: $OUT"
    wait "$CHILD"
    local rc=$?
    CHILD=
    note "the save said: $(tr '\n' ' ' < "$WORK/save.txt")"
    [ $rc -ne 0 ] && ok "the interrupted save reported failure" || bad "the interrupted save exited 0"
    check "the VM is stopped" is_stopped
    if tag_listed forced; then bad "the interrupted snapshot is listed"; else ok "the interrupted snapshot isn't listed"; fi

    local tries=1
    until hobo start "$VM"; do
        note "start attempt $tries failed: $OUT"
        tries=$((tries + 1))
        [ $tries -le 4 ] || break
        sleep 5
    done
    if [ $tries -gt 4 ]; then
        bad "the VM wouldn't start again"
        return
    fi
    ok "the VM starts again (attempt $tries; more than one is hobo-rok)"
    check "the boot cleared what the save left" no_partial_left
    check "the guest answers" guest_answers
}

test_6() {
    ensure_running || return
    local sleeper
    sleeper=$(start_sleeper)
    background_save interrupted
    sleep 2
    if ! kill -0 "$CHILD" 2> /dev/null; then
        wait "$CHILD" || bad "the save failed: $(tr '\n' ' ' < "$WORK/save.txt")"
        CHILD=
        INCONCLUSIVE_HERE="the save finished in under 2 s, before the Ctrl-C"
        drop_snapshot interrupted
        return
    fi
    kill -INT "$CHILD"
    wait "$CHILD"
    note "the client exited $? and said: $(tr '\n' ' ' < "$WORK/save.txt")"
    CHILD=
    # The VM process finishes the save without the client, and exec is refused until it has.
    check "the guest answers again: the VM isn't left paused" wait_for_guest
    check "the VM is still running" is_running
    check "the guest's processes carried on" sleeper_alive "$sleeper"
    check "the guest's clock is right" clock_right
    check "no partial save is left" no_partial_left
    if tag_listed interrupted; then
        note "the save finished after the client went away"
        if hobo snapshot restore --force "$VM" interrupted; then ok "the snapshot restores"; else bad "the snapshot doesn't restore: $OUT"; fi
        check "the restored VM answers" guest_answers
        drop_snapshot interrupted
    else
        note "the save stopped when the client went away"
    fi
}

test_7() {
    ensure_running || return
    local sleeper cpus
    sleeper=$(start_sleeper)
    cpus=$(config_value cpus)
    hobo snapshot save "$VM" t7 || bad "the save failed: $OUT"
    ensure_stopped
    hobo set "$VM" --cpus $((cpus + 1)) || bad "hobo set --cpus failed: $OUT"

    if hobo snapshot restore "$VM" t7; then ok "the restore succeeded"; else bad "the restore failed: $OUT"; fi
    if echo "$OUT" | grep -q "can't be used"; then ok "it warned that the saved state doesn't fit"; else bad "no warning: $OUT"; fi
    check "the VM booted and answers" guest_answers
    if sleeper_alive "$sleeper"; then bad "the memory came back, though it doesn't fit"; else ok "it booted from the disk, not the memory"; fi
    [ "$(config_value cpus)" = $((cpus + 1)) ] && ok "the CPUs stayed as they are now" || bad "the CPUs changed: $(config_value cpus)"

    # With the old settings back, the same snapshot's memory fits again.
    ensure_stopped
    hobo set "$VM" --cpus "$cpus" || bad "hobo set --cpus failed: $OUT"
    if hobo snapshot restore "$VM" t7; then ok "the restore succeeded with the old CPUs"; else bad "the restore failed: $OUT"; fi
    check "the memory came back this time" sleeper_alive "$sleeper"
    drop_snapshot t7
}

test_8() {
    ensure_running || return
    guest 'echo before > $HOME/t8-marker; sync'
    ensure_stopped
    local disk grown
    disk=$(config_value disk)
    grown=$((disk / 1073741824 + 4))GB
    hobo snapshot save "$VM" t8 || bad "the save failed: $OUT"
    hobo set "$VM" --disk "$grown" || bad "hobo set --disk failed: $OUT"
    ensure_running || return
    guest 'echo after > $HOME/t8-marker; sync'
    ensure_stopped

    if hobo snapshot restore "$VM" t8; then ok "the restore succeeded"; else bad "the restore failed: $OUT"; fi
    if echo "$OUT" | grep -q "The disk is back to"; then ok "it said the disk went back"; else bad "it didn't say the disk went back: $OUT"; fi
    check "the VM stays stopped" is_stopped
    [ "$(config_value disk)" = "$disk" ] && ok "config.json has the old size" || bad "config.json has $(config_value disk), not $disk"
    if grep -Eq '"diskGrowPending" *: *false' "$BUNDLE/config.json"; then ok "no grow is pending"; else bad "a grow is pending"; fi

    ensure_running || return
    check "the guest boots on the old disk" guest_answers
    [ "$(guest 'cat $HOME/t8-marker' | tr -d '[:space:]')" = before ] && ok "the disk has the snapshot's contents" || bad "the disk doesn't have the snapshot's contents"
    local seen
    seen=$(guest 'diskutil info disk0' | sed -n 's/.*Disk Size.*(\([0-9]*\) Bytes).*/\1/p')
    [ "$seen" = "$disk" ] && ok "the guest sees the old size" || bad "the guest sees ${seen:-nothing}, not $disk"
    drop_snapshot t8
}

test_9() {
    if [ -z "$OLD_HOBO" ]; then
        OLD_HOBO=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')/.build/release/hobo
    fi
    if [ ! -x "$OLD_HOBO" ] || "$OLD_HOBO" snapshot --help 2>&1 | grep -q "hobo snapshot"; then
        INCONCLUSIVE_HERE="$OLD_HOBO isn't a hobo from before snapshots (pass --old-hobo)"
        return
    fi
    ensure_stopped
    if ! "$OLD_HOBO" start "$VM" >> "$LOG" 2>&1; then
        bad "the older hobo couldn't start the VM (see the log)"
        return
    fi
    hobo snapshot save "$VM" t9
    note "the save said: $OUT"
    [ "$RC" -ne 0 ] && ok "the save was refused" || bad "the save exited 0"
    check "the VM is still running" is_running
    check "the guest answers" guest_answers
    if tag_listed t9; then bad "a snapshot was listed"; else ok "no snapshot was listed"; fi
    ask "Does the message above tell you what's wrong and what to do?"
    ensure_stopped
}

test_10() {
    ensure_stopped
    local name=snapmanual$$
    local folder=$WORK/$name
    local inside="/Volumes/My Shared Files/$name"
    mkdir -p "$folder"
    echo hello > "$folder/hello.txt"
    hobo start "$VM" --share "$folder" || { bad "couldn't start with a share: $OUT"; return; }
    [ "$(guest "cat '$inside/hello.txt'")" = hello ] && ok "the share works before the save" || bad "the share doesn't work before the save"
    hobo snapshot save "$VM" t10 || bad "the save failed: $OUT"
    ensure_stopped
    if hobo snapshot restore "$VM" t10; then ok "the restore succeeded"; else bad "the restore failed: $OUT"; fi
    [ "$(guest "cat '$inside/hello.txt'")" = hello ] && ok "the guest reads the share after the restore" || bad "the guest can't read the share after the restore"
    guest "echo back > '$inside/from-guest.txt'"
    [ "$(cat "$folder/from-guest.txt" 2> /dev/null)" = back ] && ok "the guest writes to the share after the restore" || bad "the guest can't write to the share after the restore"
    drop_snapshot t10
    ensure_stopped
}

title() {
    case "$1" in
        1) echo "The window during a save" ;;
        2) echo "The window after a restore" ;;
        3) echo "Apps, processes and network after a restore" ;;
        4) echo "Restoring a snapshot $GAP_MINUTES minutes old" ;;
        5) echo "A forced stop during a save" ;;
        6) echo "Ctrl-C during a save" ;;
        7) echo "Changed CPUs: restore boots from the disk" ;;
        8) echo "The disk goes back to its old size" ;;
        9) echo "A VM process from an older hobo" ;;
        10) echo "Shared folders across a restore" ;;
    esac
}

wanted() {
    [ -z "$ONLY" ] && return 0
    case ",$(echo "$ONLY" | tr -d ' ')," in *",$1,"*) return 0 ;; esac
    return 1
}

run_test() {
    wanted "$1" || return 0
    FAILED_HERE=0
    UNCHECKED_HERE=0
    INCONCLUSIVE_HERE=
    echo
    echo "=== $1. $(title "$1")"
    echo "=== $1. $(title "$1")" >> "$LOG"
    "test_$1"
    local verdict=PASS
    if [ "$FAILED_HERE" = 1 ]; then
        verdict=FAIL
    elif [ -n "$INCONCLUSIVE_HERE" ]; then
        verdict="INCONCLUSIVE: $INCONCLUSIVE_HERE"
    elif [ "$UNCHECKED_HERE" -gt 0 ]; then
        verdict="PASS, with $UNCHECKED_HERE thing(s) for a person not checked"
    fi
    echo "  -> $verdict"
    printf '%3s. %-46s %s\n' "$1" "$(title "$1")" "$verdict" >> "$RESULTS"
}

# --- Setup and cleanup ----------------------------------------------------------------------------

cleanup() {
    [ -n "$CHILD" ] && kill "$CHILD" 2> /dev/null
    [ "$CREATED" = 1 ] || return 0
    if [ "$KEEP" = 1 ]; then
        echo "Kept $VM. Delete it with: $HOBO stop --force $VM; $HOBO delete $VM --yes"
        return 0
    fi
    "$HOBO" stop --force "$VM" >> "$LOG" 2>&1
    if "$HOBO" delete "$VM" --yes >> "$LOG" 2>&1; then
        echo "Deleted $VM."
    else
        echo "Couldn't delete $VM; see the log. It's safe to delete by hand."
    fi
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

echo "Log: $LOG"
echo "Building this checkout..."
if ! make -C "$REPO" sign >> "$LOG" 2>&1; then
    echo "make sign failed; see the log." >&2
    exit 2
fi
if ! "$HOBO" snapshot --help 2>&1 | grep -q "hobo snapshot"; then
    echo "$HOBO has no snapshot command." >&2
    exit 2
fi
if "$HOBO" list | grep -Eq "^$VM +"; then
    echo "A VM named $VM already exists. This script won't touch it; delete it, then run this again." >&2
    exit 2
fi
if ! "$HOBO" list | grep -Eq "^$SOURCE +stopped +macOS"; then
    echo "--source must be a stopped macOS VM, and $SOURCE isn't:" >&2
    "$HOBO" list >&2
    exit 2
fi
if [ "$("$HOBO" list | grep -Ec 'running.*macOS')" -ge 2 ]; then
    echo "Two macOS guests are already running, the most a host allows. Stop one first." >&2
    exit 2
fi

echo "Cloning $SOURCE to $VM..."
if ! hobo clone "$SOURCE" "$VM"; then
    echo "The clone failed: $OUT" >&2
    exit 2
fi
CREATED=1

for number in 1 2 3 5 6 7 8 9 10 4; do
    run_test "$number"
done

echo
echo "Results:"
cat "$RESULTS"
echo "Log: $LOG"
[ "$ANY_FAILED" = 0 ]
