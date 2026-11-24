#!/bin/bash
# Package the staged, signed tree (.build/hobo, from `make sign`) for a release. Writes, in
# .build/dist:
#   hobo-<version>.tar.gz   bin/hobo, share/hobo, entitlements.plist and LICENSE in hobo-<version>/
#   hobo.rb                 the Homebrew formula (packaging/hobo.rb.in) for that tarball as a
#                           GitHub release asset
# The version is the one the staged binary reports: x.y.z built at a release tag, and
# x.y.z-<commits>-g<hash> past one, which is good only for --test.
#
# With --test, also installs the formula with Homebrew from the local tarball (a file:// URL, in
# a local tap, hobo-vm/release-test) and runs its test: the path a user's `brew install` takes,
# with nothing published. Run as `make release-test`. A hobo that Homebrew had installed already
# is replaced by this one; otherwise the test uninstalls its own afterwards, so that it doesn't
# shadow a `make install` build on PATH.
set -euo pipefail

REPO="hobo-vm/hobo"
TEST_TAP="hobo-vm/release-test"
STAGE=".build/hobo"
DIST=".build/dist"

die() { echo "package: $*" >&2; exit 1; }

[ -x "$STAGE/bin/hobo" ] || die "no $STAGE/bin/hobo: run make sign"
version=$("$STAGE/bin/hobo" --version)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+-g[0-9a-f]+)?$ ]] \
    || die "hobo --version printed '$version', not x.y.z or x.y.z-<commits>-g<hash>"

name="hobo-$version"
tarball="$DIST/$name.tar.gz"

rm -rf .build/dist
mkdir -p "$DIST/$name"
cp -R "$STAGE/bin" "$STAGE/share" "$DIST/$name/"
cp entitlements.plist LICENSE "$DIST/$name/"
# COPYFILE_DISABLE keeps macOS's tar from adding ._ files for extended attributes.
COPYFILE_DISABLE=1 tar -czf "$tarball" -C "$DIST" "$name"
rm -rf "$DIST/$name"
sha256=$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)

# formula <url> <file>
formula() {
    sed -e "s|@URL@|$1|" -e "s|@SHA256@|$sha256|" packaging/hobo.rb.in > "$2"
}

formula "https://github.com/$REPO/releases/download/v$version/$name.tar.gz" "$DIST/hobo.rb"
echo "package: $tarball"
echo "package: sha256 $sha256"
echo "package: $DIST/hobo.rb"

[ "${1:-}" = "--test" ] || exit 0

command -v brew > /dev/null || die "brew not found"
# Homebrew installs formulae only from taps, so the test formula goes in a local one.
# Not grep -q: it exits at the first match, and under pipefail a brew still writing then fails
# the pipeline, which would run tap-new on a tap that exists.
brew tap | grep -x "$TEST_TAP" > /dev/null || brew tap-new --no-git "$TEST_TAP" > /dev/null
tap_formula="$(brew --repository "$TEST_TAP")/Formula/hobo.rb"
formula "file://$PWD/$tarball" "$tap_formula"
# Homebrew reads the version from the url, and of a build past a release tag reads it wrong (the
# hash's digits), so that formula states it. A release's is tested as it ships.
if [[ "$version" == *-* ]]; then
    sed -i '' -e "s|^  sha256 .*|&\\
  version \"$version\"|" "$tap_formula"
fi
had_hobo=0
if brew list --formula hobo > /dev/null 2>&1; then
    had_hobo=1
    # Uninstalled first, so the install is from this tarball whatever was there before.
    brew uninstall --formula --force hobo > /dev/null
else
    # On exit, so a failed brew test doesn't leave its hobo installed either.
    trap 'brew uninstall --formula --force hobo > /dev/null 2>&1 || true' EXIT
fi
HOMEBREW_NO_AUTO_UPDATE=1 brew install --formula "$TEST_TAP/hobo"
brew test "$TEST_TAP/hobo"
echo "package: brew installed and tested hobo $version from $tarball"
[ $had_hobo = 0 ] || echo "package: the hobo Homebrew had installed is now this build"
