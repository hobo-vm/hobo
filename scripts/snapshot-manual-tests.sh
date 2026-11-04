#!/bin/bash
# The hobo snapshot checks `make integration-test` doesn't make: failure paths, changed settings, a
# VM process from an older hobo, shares, a long gap before restoring, and what only a person can
# judge about the window. It builds this checkout, so the binary on your PATH doesn't matter.
#
# It works on its own clone of a stopped macOS VM and deletes that clone when it ends. It refuses
# to run if a VM with the clone's name already exists, and touches no other VM. A host runs at most
# two macOS guests and this boots one, so leave room for it, and don't run it alongside
# `make integration-test`.

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

usage_error() {
    echo "$1" >&2
    usage >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --source|--gap|--old-hobo|--only) [ $# -ge 2 ] || usage_error "$1 needs a value" ;;
    esac
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --gap) GAP_MINUTES=$2; shift 2 ;;
        --old-hobo) OLD_HOBO=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --unattended) ATTENDED=0; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_error "unknown option: $1" ;;
    esac
done

ONLY=${ONLY// /}

# Checked now, since a bad gap would end the run at its last test, and an --only that matches
# nothing would run no tests and report success.
[[ "$GAP_MINUTES" =~ ^(0|[1-9][0-9]*)$ ]] || usage_error "--gap takes whole minutes, not: $GAP_MINUTES"
[ -z "$ONLY" ] || [[ "$ONLY" =~ ^((10|[1-9]),)*(10|[1-9])$ ]] \
    || usage_error "--only takes test numbers from 1 to 10, separated by commas, not: $ONLY"

HOBO=$REPO/.build/release/hobo
BUNDLE=${HOBO_VMS:-$HOME/Hobo}/$VM.hobovm
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hobo-snapshot-tests.XXXXXX")
LOG=$WORK/log.txt
RESULTS=$WORK/results.txt
CLONED=0
TEST_FAILED=0
TEST_UNCHECKED=0
TEST_INCONCLUSIVE=
ANY_FAILED=0
SAVE_PID=

# --- Output and results ---------------------------------------------------------------------------

note() { echo "    $*"; echo "note: $*" >> "$LOG"; }
ok() { echo "  ok    $*"; echo "ok: $*" >> "$LOG"; }
bad() {
    echo "  FAIL  $*"
    echo "FAIL: $*" >> "$LOG"
    TEST_FAILED=1
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
        TEST_UNCHECKED=$((TEST_UNCHECKED + 1))
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

list_row() { "$HOBO" list 2>> "$LOG" | grep -E "^$VM +"; }
is_running() { list_row | grep -Eq "^$VM +running"; }
is_stopped() { list_row | grep -Eq "^$VM +stopped"; }
window_shown() { list_row | grep -Eq "^$VM +running \(window\)"; }
tag_listed() { "$HOBO" snapshot list "$VM" 2>> "$LOG" | grep -Eq "^$1 "; }
no_partial_left() { ! ls -d "$BUNDLE"/snapshots/.saving-* > /dev/null 2>&1; }
config_value() { sed -n "s/.*\"$1\"[^0-9]*\([0-9]*\).*/\1/p" "$BUNDLE/config.json" | head -1; }

# A start straight after a forced stop may need a retry (hobo-rok). Leaves the attempt it got to in
# START_ATTEMPT.
start_with_retries() {
    for START_ATTEMPT in 1 2 3 4; do
        hobo start "$VM" && return 0
        note "start attempt $START_ATTEMPT failed: $OUT"
        sleep 5
    done
    return 1
}

ensure_running() {
    is_running && return 0
    start_with_retries && return 0
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

# Starts a save in the background, leaving its pid in SAVE_PID and its output in $WORK/save.txt. With
# job control on, the shell doesn't make it ignore SIGINT as it would any background job.
background_save() {
    set -m
    "$HOBO" snapshot save "$VM" "$1" > "$WORK/save.txt" 2>&1 &
    SAVE_PID=$!
    set +m
}

# save_ended_too_soon <tag> <interruption>: gives the background save 2 s, and is true if it ended
# before it could be interrupted. That's a failure if the save failed, otherwise inconclusive.
save_ended_too_soon() {
    sleep 2
    kill -0 "$SAVE_PID" 2> /dev/null && return 1
    wait "$SAVE_PID" || bad "the save failed: $(tr '\n' ' ' < "$WORK/save.txt")"
    SAVE_PID=
    TEST_INCONCLUSIVE="the save finished in under 2 s, before $2"
    drop_snapshot "$1"
    return 0
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
    hobo view "$VM" || bad "hobo view: $OUT"
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
    save_ended_too_soon forced "the forced stop" && return
    hobo stop --force "$VM" || bad "the forced stop failed: $OUT"
    wait "$SAVE_PID"
    local rc=$?
    SAVE_PID=
    note "the save said: $(tr '\n' ' ' < "$WORK/save.txt")"
    if [ $rc -ne 0 ]; then ok "the interrupted save reported failure"; else bad "the interrupted save exited 0"; fi
    check "the VM is stopped" is_stopped
    if tag_listed forced; then bad "the interrupted snapshot is listed"; else ok "the interrupted snapshot isn't listed"; fi

    if ! start_with_retries; then
        bad "the VM wouldn't start again"
        return
    fi
    ok "the VM starts again (attempt $START_ATTEMPT; more than one is hobo-rok)"
    check "the boot cleared what the save left" no_partial_left
    check "the guest answers" guest_answers
}

test_6() {
    ensure_running || return
    local sleeper
    sleeper=$(start_sleeper)
    background_save interrupted
    save_ended_too_soon interrupted "the Ctrl-C" && return
    kill -INT "$SAVE_PID"
    wait "$SAVE_PID"
    note "the client exited $? and said: $(tr '\n' ' ' < "$WORK/save.txt")"
    SAVE_PID=
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
    if [ "$(config_value cpus)" = $((cpus + 1)) ]; then ok "the CPUs stayed as they are now"; else bad "the CPUs changed: $(config_value cpus)"; fi

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
    grown=$((disk / (1024 * 1024 * 1024) + 4))GB
    hobo snapshot save "$VM" t8 || bad "the save failed: $OUT"
    hobo set "$VM" --disk "$grown" || bad "hobo set --disk failed: $OUT"
    ensure_running || return
    guest 'echo after > $HOME/t8-marker; sync'
    ensure_stopped

    if hobo snapshot restore "$VM" t8; then ok "the restore succeeded"; else bad "the restore failed: $OUT"; fi
    if echo "$OUT" | grep -q "The disk is back to"; then ok "it said the disk went back"; else bad "it didn't say the disk went back: $OUT"; fi
    check "the VM stays stopped" is_stopped
    if [ "$(config_value disk)" = "$disk" ]; then ok "config.json has the old size"; else bad "config.json has $(config_value disk), not $disk"; fi
    if grep -Eq '"diskGrowPending" *: *false' "$BUNDLE/config.json"; then ok "no grow is pending"; else bad "a grow is pending"; fi

    ensure_running || return
    check "the guest boots on the old disk" guest_answers
    if [ "$(guest 'cat $HOME/t8-marker' | tr -d '[:space:]')" = before ]; then ok "the disk has the snapshot's contents"; else bad "the disk doesn't have the snapshot's contents"; fi
    local seen
    seen=$(guest 'diskutil info disk0' | sed -n 's/.*Disk Size.*(\([0-9]*\) Bytes).*/\1/p')
    if [ "$seen" = "$disk" ]; then ok "the guest sees the old size"; else bad "the guest sees ${seen:-nothing}, not $disk"; fi
    drop_snapshot t8
}

test_9() {
    if [ -z "$OLD_HOBO" ]; then
        OLD_HOBO=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')/.build/release/hobo
    fi
    # A plain `swift build -c release` leaves it unsigned, and that would look like a failed start.
    if [ ! -x "$OLD_HOBO" ] || "$OLD_HOBO" snapshot --help 2>&1 | grep -q "hobo snapshot" \
        || ! codesign -d --entitlements - "$OLD_HOBO" 2>&1 | grep -q com.apple.security.virtualization; then
        TEST_INCONCLUSIVE="$OLD_HOBO isn't a signed hobo from before snapshots (pass --old-hobo)"
        return
    fi
    ensure_stopped
    if ! "$OLD_HOBO" start "$VM" >> "$LOG" 2>&1; then
        bad "the older hobo couldn't start the VM (see the log)"
        return
    fi
    hobo snapshot save "$VM" t9
    note "the save said: $OUT"
    if [ "$RC" -ne 0 ]; then ok "the save was refused"; else bad "the save exited 0"; fi
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
    if ! hobo start "$VM" --share "$folder"; then
        bad "couldn't start with a share: $OUT"
        return
    fi
    if [ "$(guest "cat '$inside/hello.txt'")" = hello ]; then ok "the share works before the save"; else bad "the share doesn't work before the save"; fi
    hobo snapshot save "$VM" t10 || bad "the save failed: $OUT"
    ensure_stopped
    if hobo snapshot restore "$VM" t10; then ok "the restore succeeded"; else bad "the restore failed: $OUT"; fi
    if [ "$(guest "cat '$inside/hello.txt'")" = hello ]; then ok "the guest reads the share after the restore"; else bad "the guest can't read the share after the restore"; fi
    guest "echo back > '$inside/from-guest.txt'"
    if [ "$(cat "$folder/from-guest.txt" 2> /dev/null)" = back ]; then ok "the guest writes to the share after the restore"; else bad "the guest can't write to the share after the restore"; fi
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

wanted() { [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]; }

run_test() {
    wanted "$1" || return 0
    TEST_FAILED=0
    TEST_UNCHECKED=0
    TEST_INCONCLUSIVE=
    echo
    echo "=== $1. $(title "$1")"
    echo "=== $1. $(title "$1")" >> "$LOG"
    "test_$1"
    local verdict=PASS
    if [ "$TEST_FAILED" = 1 ]; then
        verdict=FAIL
    elif [ -n "$TEST_INCONCLUSIVE" ]; then
        verdict="INCONCLUSIVE: $TEST_INCONCLUSIVE"
    elif [ "$TEST_UNCHECKED" -gt 0 ]; then
        verdict="PASS, with $TEST_UNCHECKED thing(s) for a person not checked"
    fi
    echo "  -> $verdict"
    printf '%3s. %-46s %s\n' "$1" "$(title "$1")" "$verdict" >> "$RESULTS"
}

# --- Setup and cleanup ----------------------------------------------------------------------------

cleanup() {
    [ -n "$SAVE_PID" ] && kill "$SAVE_PID" 2> /dev/null
    [ "$CLONED" = 1 ] || return 0
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
CLONED=1

# Test 4 goes last so its gap holds up nothing else.
for number in 1 2 3 5 6 7 8 9 10 4; do
    run_test "$number"
done

echo
echo "Results:"
cat "$RESULTS"
echo "Log: $LOG"
[ "$ANY_FAILED" = 0 ]
