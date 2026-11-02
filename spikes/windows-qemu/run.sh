#!/bin/bash
# Windows 11 on Arm under qemu-system-aarch64 -accel hvf: the hobo-gsa spike. Throwaway; the
# findings live in README.md, and M5 turns them into the QEMU engine.
#
#   run.sh prepare [iso]   download drivers + OpenSSH, build the config ISO, disk and NVRAM
#   run.sh install         boot the installer headless and wait for setup to finish over SSH
#   run.sh boot            boot the installed disk headless and wait for SSH
#   run.sh ssh [cmd...]    SSH in as vagrant (cmd.exe is the remote shell)
#   run.sh screenshot      guest-side (interactive session) and host-side (QMP) screenshots
#   run.sh stop            shut Windows down, falling back to killing QEMU
#
# Large files live in $HOBO_SPIKE_DIR (default ~/Downloads/hobo-windows-spike), never in the repo.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${HOBO_SPIKE_DIR:-$HOME/Downloads/hobo-windows-spike}
PORT=${HOBO_SPIKE_SSH_PORT:-2222}
CPUS=${HOBO_SPIKE_CPUS:-4}
MEMORY=${HOBO_SPIKE_MEMORY:-8G}
DISK_SIZE=${HOBO_SPIKE_DISK:-64G}

SHARE=$(brew --prefix qemu)/share/qemu
VIRTIO_URL=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso
VIRTIO_SHA256=303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d
OPENSSH_URL=https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-ARM64-v10.4.0.0.msi
OPENSSH_SHA256=75fa139d8975eedb706d9180f454e2148af09d417692825f383fe00610b00e21

KEY=$WORK/vagrant_insecure_key
QMP=$WORK/qmp.sock
SSH_OPTS=(-i "$KEY" -o Port="$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes)

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

fetch() { # url sha256 dest
    if [[ ! -f $3 ]]; then
        log "downloading $(basename "$3")"
        curl -fL --progress-bar -o "$3.partial" "$1"
        mv "$3.partial" "$3"
    fi
    echo "$2  $3" | shasum -a 256 -c --quiet - || die "$3: sha256 mismatch"
}

find_iso() {
    local iso
    shopt -s nocaseglob
    ls -t "$HOME"/Downloads/Win*11*Arm64*.iso 2>/dev/null | head -1
}

# One QMP command; prints the response line.
qmp() {
    python3 -I - "$QMP" "$1" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw')
def call(cmd):
    f.write(json.dumps(cmd) + '\n'); f.flush()
    while True:
        msg = json.loads(f.readline())
        if 'return' in msg or 'error' in msg: return msg
f.readline()  # greeting
call({'execute': 'qmp_capabilities'})
print(json.dumps(call(json.loads(sys.argv[2]))))
EOF
}

running() { [[ -f $WORK/qemu.pid ]] && kill -0 "$(cat "$WORK/qemu.pid")" 2>/dev/null; }

host_screenshot() { # dest.png
    qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$1\",\"format\":\"png\"}}" >/dev/null
}

start_qemu() { # extra qemu args...
    running && die "QEMU is already running (pid $(cat "$WORK/qemu.pid"))"
    rm -f "$QMP"
    qemu-system-aarch64 \
        -name hobo-win11 \
        -machine virt,highmem=on -accel hvf -cpu host -smp "$CPUS" -m "$MEMORY" \
        -drive if=pflash,format=raw,readonly=on,file="$SHARE/edk2-aarch64-code.fd" \
        -drive if=pflash,format=raw,file="$WORK/vars.fd" \
        -device ramfb \
        -device qemu-xhci -device usb-kbd -device usb-tablet \
        -drive if=none,id=disk0,format=qcow2,discard=unmap,file="$WORK/disk.qcow2" \
        -device nvme,drive=disk0,serial=hobo0,bootindex=0 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 \
        -device virtio-net-pci,netdev=net0 \
        -display none -monitor none -serial none \
        -qmp unix:"$QMP",server=on,wait=off \
        "$@" >"$WORK/qemu.log" 2>&1 &
    echo $! >"$WORK/qemu.pid"
    for _ in $(seq 50); do [[ -S $QMP ]] && return; sleep 0.2; done
    die "QEMU didn't start; see $WORK/qemu.log"
}

guest() { ssh "${SSH_OPTS[@]}" vagrant@127.0.0.1 "$@"; }

# Waits until `guest $check` prints $want, saving a host screenshot each round to watch progress.
wait_for() { # timeout-minutes want check...
    local minutes=$1 want=$2; shift 2
    local start=$SECONDS
    while (( SECONDS - start < minutes * 60 )); do
        running || die "QEMU exited; see $WORK/qemu.log"
        host_screenshot "$WORK/progress.png" || true
        if [[ $(guest "$@" 2>/dev/null | tr -d '\r') == *"$want"* ]]; then
            log "ready after $(( (SECONDS - start) / 60 ))m$(( (SECONDS - start) % 60 ))s"
            return
        fi
        sleep 20
    done
    die "timed out after $minutes minutes; last screen: $WORK/progress.png"
}

cmd_prepare() {
    local iso=${1:-$(find_iso)}
    [[ -f $iso ]] || die "no Win*11*Arm64*.iso in ~/Downloads; get one from https://www.microsoft.com/software-download/windows11arm64"
    mkdir -p "$WORK"
    log "Windows ISO: $iso"
    log "sha256: $(shasum -a 256 "$iso" | cut -d' ' -f1)"
    fetch "$VIRTIO_URL" "$VIRTIO_SHA256" "$WORK/virtio-win-0.1.302.iso"
    fetch "$OPENSSH_URL" "$OPENSSH_SHA256" "$WORK/OpenSSH-ARM64-v10.4.0.0.msi"
    ln -sf "$iso" "$WORK/windows.iso"

    # Vagrant insecure key pair (public halves as in HoboCore.Conventions).
    cat >"$KEY" <<'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDdWHcQaTZc8Q6nycsP0CqMNRfsLxvYVxqKosrHyTp+WAAAAJj2TBMT9kwT
EwAAAAtzc2gtZWQyNTUxOQAAACDdWHcQaTZc8Q6nycsP0CqMNRfsLxvYVxqKosrHyTp+WA
AAAEAveRHRHSCjIxbNKHDRzezD0U3R3UEEmS7R33fzvPQAD91YdxBpNlzxDqfJyw/QKow1
F+wvG9hXGoqiysfJOn5YAAAAEHNwb3hAdmFncmFudC1kZXYBAgMEBQ==
-----END OPENSSH PRIVATE KEY-----
EOF
    chmod 600 "$KEY"

    # Config ISO: autounattend.xml at the root, plus setup scripts, NetKVM and the OpenSSH MSI.
    local stage=$WORK/config
    rm -rf "$stage" && mkdir -p "$stage/drivers"
    cp "$HERE"/autounattend.xml "$HERE"/hobo-setup.ps1 "$HERE"/run-in-session.ps1 "$HERE"/screenshot.ps1 "$stage/"
    cp "$WORK/OpenSSH-ARM64-v10.4.0.0.msi" "$stage/"
    ssh-keygen -y -f "$KEY" | sed 's/$/ vagrant insecure public key/' >"$stage/authorized_keys"
    local mnt=$WORK/virtio-mnt
    mkdir -p "$mnt"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$WORK/virtio-win-0.1.302.iso"
    cp -R "$mnt/NetKVM/w11/ARM64" "$stage/drivers/NetKVM"
    hdiutil detach -quiet "$mnt" && rmdir "$mnt"
    chmod -R u+w "$stage/drivers"
    rm -f "$WORK/config.iso"
    hdiutil makehybrid -quiet -iso -joliet -default-volume-name HOBOCFG -o "$WORK/config.iso" "$stage"

    # Disk and a fresh UEFI variable store (holds the boot entries Windows Setup writes).
    rm -f "$WORK/disk.qcow2"
    qemu-img create -q -f qcow2 "$WORK/disk.qcow2" "$DISK_SIZE"
    cp "$SHARE/edk2-arm-vars.fd" "$WORK/vars.fd"
    log "prepared $WORK"
}

cmd_install() {
    [[ -f $WORK/config.iso ]] || die "run prepare first"
    # Boot order: the disk (bootindex 0) and then the Windows ISO. QEMU hands edk2 this list and
    # edk2 drops boot entries it doesn't name, so with only the CD listed, Setup's first reboot
    # lands in the UEFI shell once the CD's "press any key" prompt times out. The empty disk
    # falls through to the CD; after Setup's first phase, Windows Boot Manager on the disk wins.
    local start=$SECONDS
    start_qemu \
        -drive if=none,id=cd0,media=cdrom,readonly=on,file="$WORK/windows.iso" \
        -device usb-storage,drive=cd0,bootindex=1 \
        -drive if=none,id=cd1,media=cdrom,readonly=on,file="$WORK/config.iso" \
        -device usb-storage,drive=cd1
    # The Windows ISO's EFI loader waits for "Press any key to boot from CD or DVD" for about 5s,
    # a few seconds after power-on. Stop well before Setup's UI comes up (20s+), where Enter
    # lands on its focused Cancel button.
    log "pressing Enter for the CD boot prompt"
    for _ in $(seq 10); do
        qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}' >/dev/null || true
        sleep 1
    done
    log "installing; watch $WORK/progress.png"
    wait_for 120 done 'if exist C:\hobo\setup-done echo done'
    log "install + setup took $(( (SECONDS - start) / 60 )) minutes"
}

cmd_boot() {
    start_qemu
    wait_for 10 ok 'echo ok'
}

cmd_screenshot() {
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    host_screenshot "$WORK/host-$stamp.png"
    log "host (QMP screendump): $WORK/host-$stamp.png"
    guest 'del /q C:\hobo\shot.png 2>nul & powershell -NoProfile -ExecutionPolicy Bypass -File C:\hobo\run-in-session.ps1 -Script C:\hobo\screenshot.ps1 -Arguments C:\hobo\shot.png'
    scp -q -O "${SSH_OPTS[@]}" vagrant@127.0.0.1:C:/hobo/shot.png "$WORK/guest-$stamp.png" 2>/dev/null \
        || scp -q "${SSH_OPTS[@]}" vagrant@127.0.0.1:/C:/hobo/shot.png "$WORK/guest-$stamp.png"
    log "guest (interactive session): $WORK/guest-$stamp.png"
}

cmd_stop() {
    running || { log "not running"; return; }
    guest 'shutdown /s /t 0' 2>/dev/null || qmp '{"execute":"system_powerdown"}' >/dev/null || true
    for _ in $(seq 60); do running || { log "stopped"; return; }; sleep 2; done
    log "still running after 2 minutes; killing QEMU"
    kill "$(cat "$WORK/qemu.pid")"
}

case ${1:-} in
    prepare) shift; cmd_prepare "$@" ;;
    install) cmd_install ;;
    boot) cmd_boot ;;
    ssh) shift; guest "$@" ;;
    screenshot) cmd_screenshot ;;
    stop) cmd_stop ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
