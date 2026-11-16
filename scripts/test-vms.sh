#!/bin/bash
# Builds the kept VMs the guest tests clone (Tests/HoboVMTests/KeptVM.swift), any that are missing, from
# Tests/HoboVMTests/recipes: $HOBO_MACOS_VM, $HOBO_LINUX_VM and $HOBO_WINDOWS_VM, each skipped when
# set empty. Windows needs $HOBO_WINDOWS_ISO, a Windows on Arm installer, which hobo can't download.
set -euo pipefail

hobo=${HOBO_BIN:-hobo}
recipes=$(cd "$(dirname "$0")/../Tests/HoboVMTests/recipes" && pwd)
work=$(mktemp -d)
trap 'safe-rm -rf "$work"' EXIT

exists() { [ -d "${HOBO_VMS:-$HOME/Hobo}/$1.hobovm" ]; }

build() {  # <vm> <recipe>
    if [ -z "$1" ]; then return; fi
    if exists "$1"; then
        echo "$1 is already there"
        return
    fi
    echo "Building $1 from $(basename "$2")"
    "$hobo" create "$1" "$2"
}

build "${HOBO_MACOS_VM-macos27}" "$recipes/macos.toml"
build "${HOBO_LINUX_VM-ubuntu26}" "$recipes/linux.toml"

windows=${HOBO_WINDOWS_VM-windows11}
if [ -n "$windows" ] && ! exists "$windows"; then
    iso=${HOBO_WINDOWS_ISO:?"$windows needs HOBO_WINDOWS_ISO, the path of a Windows on Arm installer ISO"}
    # Absolute: the recipe is in $work, and a recipe's paths are relative to it.
    iso=$(cd "$(dirname "$iso")" && pwd)/$(basename "$iso")
    cp "$recipes/windows.toml" "$work/windows.toml"
    printf '\n[source]\niso    = "%s"\nsha256 = "%s"\n' "$iso" "$(shasum -a 256 "$iso" | cut -d' ' -f1)" >> "$work/windows.toml"
    build "$windows" "$work/windows.toml"
fi
