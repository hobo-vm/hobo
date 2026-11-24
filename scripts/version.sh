#!/bin/sh
# Writes hobo's version as a Swift source for HoboCore to compile (`Hobo.version`):
# version.sh <package directory> <output directory>. Run by HoboVersionPlugin before every build.
#
# The version is what `git describe` says of the checkout against the v<version> release tags:
# `0.2.0` on the tagged commit, `0.2.0-3-g1a2b3c4` three commits after it. Without git, a tag or a
# checkout (a source archive), it is `0.0.0-dev`.
set -eu
package=$1 output=$2

described=$(git -C "$package" describe --tags --match 'v[0-9]*' 2>/dev/null || true)
version=${described#v}
[ -n "$version" ] || version="0.0.0-dev"

# Left alone when the version hasn't changed, so that a build doesn't recompile HoboCore for it.
file="$output/GeneratedVersion.swift"
contents="let generatedVersion = \"$version\""
mkdir -p "$output"
if [ ! -f "$file" ] || [ "$(cat "$file")" != "$contents" ]; then
    printf '%s\n' "$contents" > "$file"
fi
