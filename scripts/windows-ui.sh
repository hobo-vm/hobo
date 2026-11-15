#!/bin/bash
# Builds hobo ui's Windows backend (UIWindows/) in an ephemeral clone of a Windows build VM and
# commits-ready copies it to Sources/HoboVM/Resources/UI/hobo-ui-windows.exe, beside the digest of
# the sources it came from, which `make test` checks (designs/hobo-ui-linux-windows.md decision 5).
#
#   scripts/windows-ui.sh build   build it (make windows-ui)
#   scripts/windows-ui.sh check   fail if the exe is older than UIWindows/ (make test), warn if there's none
#
# The build VM, $HOBO_WINDOWS_BUILD_VM (default windows-build), is a Windows VM with the .NET SDK:
#   hobo init --os windows <Windows on Arm ISO> -o windows-build.toml
#   then add UIWindows/install-dotnet.ps1 as a [[provision]] step, and hobo create windows-build -f windows-build.toml
set -euo pipefail
cd "$(dirname "$0")/.."

out=Sources/HoboVM/Resources/UI
digest_file=$out/hobo-ui-windows.sources.sha256
hobo=${HOBO_BIN:-hobo}
vm_name=${HOBO_WINDOWS_BUILD_VM:-windows-build}

sources_digest() {
    (cd UIWindows && find . -type f \( -name '*.cs' -o -name '*.csproj' -o -name '*.manifest' \) | LC_ALL=C sort | xargs shasum -a 256) | shasum -a 256 | cut -d' ' -f1
}

case "${1:-}" in
check)
    # Until a Windows build VM has built it once, hobo ui fails on Windows guests saying so.
    if [ ! -f "$out/hobo-ui-windows.exe" ]; then
        echo "warning: $out/hobo-ui-windows.exe hasn't been built yet; run make windows-ui" >&2
    elif [ "$(cat "$digest_file" 2>/dev/null)" != "$(sources_digest)" ]; then
        echo "error: $out/hobo-ui-windows.exe is out of date with UIWindows/; run make windows-ui" >&2
        exit 1
    fi
    ;;
build)
    if ! "$hobo" list --json | jq -e --arg name "$vm_name" '.vms[] | select(.name == $name)' >/dev/null; then
        echo "error: no VM $vm_name to build in; see the top of $0 for making one" >&2
        exit 1
    fi
    vm=$("$hobo" start "$vm_name" --ephemeral --json | jq -r 'select(.event=="result").result.name')
    trap '"$hobo" stop "$vm" --force >/dev/null 2>&1 || true' EXIT
    "$hobo" exec "$vm" -- powershell.exe -NoProfile -Command 'Remove-Item -Recurse -Force C:\build -ErrorAction SilentlyContinue; New-Item -ItemType Directory C:\build | Out-Null'
    "$hobo" cp UIWindows "$vm":C:/build/UIWindows
    "$hobo" exec "$vm" -- dotnet build C:/build/UIWindows/HoboUIWindows.csproj -c Release -o C:/build/out -nologo
    "$hobo" cp "$vm":C:/build/out/hobo-ui-windows.exe "$out/hobo-ui-windows.exe"
    sources_digest > "$digest_file"
    echo "Built $out/hobo-ui-windows.exe"
    ;;
*)
    echo "usage: $0 build|check" >&2
    exit 2
    ;;
esac
