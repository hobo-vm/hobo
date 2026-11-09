#!/bin/sh
# Compiles the UEFI framebuffer driver and loader into the output directory, as framebuffer.efi and
# loader.efi, for HoboVM to carry as resources: build.sh <source directory> <output directory>
# <scratch directory>. Run by WindowsBootPlugin.
set -eu
source=$1 output=$2 scratch=$3

linker=$(PATH="$PATH:/opt/homebrew/opt/lld/bin:/usr/local/opt/lld/bin" command -v lld-link || true)
if [ -z "$linker" ]; then
    echo "error: building Hobo's Windows boot driver needs lld-link: brew install lld" >&2
    exit 1
fi

compile() { # name, UEFI subsystem
    /usr/bin/clang -target aarch64-unknown-windows -ffreestanding -fshort-wchar -fno-builtin \
        -fno-stack-protector -mno-implicit-float -O2 -Wall -Wextra -Werror \
        -I"$source" -c "$source/$1.c" -o "$scratch/$1.o"
    "$linker" /nologo /Brepro /nodefaultlib /dll /entry:efi_main "/subsystem:$2" "/out:$output/$1.efi" "$scratch/$1.o"
}

mkdir -p "$scratch" "$output"
compile framebuffer efi_boot_service_driver
compile loader efi_application
