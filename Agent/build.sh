#!/bin/sh
# Builds hobo-agent for each guest into the output directory, as hobo-agent-<GOOS>, for HoboVM to
# carry as resources: build.sh <source directory> <output directory> <scratch directory>. Run by
# HoboAgentPlugin.
set -eu
source=$1 output=$2 scratch=$3

go=$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin" command -v go || true)
if [ -z "$go" ]; then
    echo "error: building hobo-agent needs Go: brew install go" >&2
    exit 1
fi

# The plugin's sandbox allows writes only under the plugin's work directory, and no network: the
# agent has no dependencies, and the installed toolchain is the one used.
mkdir -p "$scratch/cache" "$scratch/path" "$output"
export HOME="$scratch" GOCACHE="$scratch/cache" GOPATH="$scratch/path" GOTOOLCHAIN=local GOENV=off GOFLAGS= CGO_ENABLED=0

build() { # GOOS
    (cd "$source" && GOOS=$1 GOARCH=arm64 "$go" build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "$output/hobo-agent-$1" .)
}

build linux
build darwin
build windows
