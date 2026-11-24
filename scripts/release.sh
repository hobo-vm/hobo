#!/bin/bash
# Cut a release. Run via `make release [VERSION=x.y.z]`; VERSION defaults to the next minor after
# the latest v* tag, or 0.1.0 when there is none.
#
# Tags HEAD v<version>, which is what gives the build its version (scripts/version.sh), then runs
# the unit tests, the integration tests, and a Homebrew install of the formula from the local
# tarball (`make release-test`). If any of that fails, or you answer no at the prompt, the tag is
# deleted and nothing has left this machine.
#
# After you confirm, it publishes, in this order: the v<version> tag, a GitHub release with the
# tarball, the formula in the tap, and last `main`, so that docs on main that tell people to
# `brew install` go live only once that works.
set -euo pipefail

REPO="hobo-vm/hobo"
TAP="hobo-vm/homebrew-tap"
DIST=".build/dist"

die() { echo "release: $*" >&2; exit 1; }

PREV_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [ -z "${VERSION:-}" ]; then
    if [ -z "$PREV_TAG" ]; then
        VERSION="0.1.0"
    else
        IFS=. read -r major minor _ <<< "${PREV_TAG#v}"
        VERSION="${major}.$((minor + 1)).0"
    fi
fi
TAG="v${VERSION}"
TARBALL="${DIST}/hobo-${VERSION}.tar.gz"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be x.y.z, got '$VERSION'"
[ "$(git branch --show-current)" = "main" ] || die "release from main, not $(git branch --show-current)"
! git rev-parse -q --verify "refs/tags/${TAG}" > /dev/null || die "${TAG} already exists"
[ -z "$PREV_TAG" ] || [ -n "$(git rev-list "${PREV_TAG}..HEAD")" ] || die "nothing to release since ${PREV_TAG}"
[ -z "$(git status --porcelain)" ] || die "working tree isn't clean"

# What publishing needs, checked before the tests rather than after them.
command -v gh > /dev/null || die "gh not found"
command -v brew > /dev/null || die "brew not found"
[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = "PUBLIC" ] \
    || die "${REPO} isn't public, so Homebrew couldn't download the release"
# The permissions that can push are named, so that a gh that fails (no tap, not signed in) and
# prints nothing doesn't pass.
case "$(gh repo view "$TAP" --json viewerPermission --jq .viewerPermission)" in
    ADMIN | MAINTAIN | WRITE) ;;
    *) die "no push access to ${TAP}" ;;
esac
git fetch -q origin main
[ -z "$(git rev-list HEAD..origin/main)" ] || die "origin/main has commits this checkout doesn't: pull first"

echo "Releasing ${VERSION}${PREV_TAG:+ (previous: ${PREV_TAG#v})}…"

undo_tag() {
    trap - ERR INT TERM
    git tag -d "$TAG" > /dev/null
    echo "release: $1; ${TAG} is deleted and nothing was published" >&2
    exit 1
}

# Local until the push below. The builds that follow take their version from it.
git tag -a "$TAG" -m "hobo ${VERSION}"
# Ctrl-C too, so an interrupted run doesn't leave the tag behind.
trap 'undo_tag "failed"' ERR INT TERM

make test
make integration-test
make release-test
# package.sh names the tarball after the version the binary reports, so this is also the check
# that the build took its version from the tag.
[ -f "$TARBALL" ] || undo_tag "no ${TARBALL}"
# Checked again: the tests run long enough for someone to push, and the push of main comes last,
# after the tag and the release are public.
git fetch -q origin main
[ -z "$(git rev-list HEAD..origin/main)" ] || undo_tag "origin/main got new commits during the tests"

echo
echo "hobo ${VERSION}"
echo "  tarball  ${TARBALL}"
echo "  sha256   $(shasum -a 256 "$TARBALL" | cut -d ' ' -f 1)"
echo "  commits that go to origin/main:"
git log --format='    %h %s' origin/main..HEAD
read -r -p "Publish ${VERSION}? [y/N] " answer
if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
    undo_tag "cancelled"
fi

# From here each step is public and isn't undone: a failure says what is left to do by hand.
trap - ERR INT TERM
left="git push origin ${TAG}; gh release create; ${TAP}'s Formula/hobo.rb; git push origin main"
trap 'echo "release: failed while publishing. Still to do: ${left}" >&2' ERR

git push -q origin "$TAG"
left="gh release create; ${TAP}'s Formula/hobo.rb; git push origin main"

gh release create "$TAG" "$TARBALL" --repo "$REPO" --verify-tag --title "hobo ${VERSION}" --generate-notes
left="${TAP}'s Formula/hobo.rb (from ${DIST}/hobo.rb); git push origin main"

rm -rf .build/dist/tap
gh repo clone "$TAP" "$DIST/tap" -- -q
mkdir -p "$DIST/tap/Formula"
cp "$DIST/hobo.rb" "$DIST/tap/Formula/hobo.rb"
git -C "$DIST/tap" add Formula/hobo.rb
git -C "$DIST/tap" commit -q -m "hobo ${VERSION}"
# gh cloned it over HTTPS, so the push uses gh's credentials: git has none of its own for
# github.com when the checkout it runs from pushes over SSH, and would stop to ask for a username.
git -C "$DIST/tap" -c credential.helper= -c credential.helper='!gh auth git-credential' push -q origin HEAD
left="git push origin main"

git push -q origin main

echo "Released ${VERSION}: https://github.com/${REPO}/releases/tag/${TAG}"
# A hobo Homebrew has installed now is the one `make release-test` left, from its local tap, and
# Homebrew won't install the same name from a second tap over it.
if brew list --formula hobo > /dev/null 2>&1; then
    echo "Check it as a user: brew uninstall hobo && brew install hobo-vm/tap/hobo"
else
    echo "Check it as a user: brew install hobo-vm/tap/hobo"
fi
