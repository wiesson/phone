#!/bin/sh
# One run from a clean, pushed main to a GitHub pre-release with the notarised
# disk image attached.
#
#   sh scripts/release-github.sh            # build, notarise, tag, release
#   sh scripts/release-github.sh --draft    # same, but the release stays a draft
#
# Needs: a Developer ID Application certificate, ASC_API_KEY_ID and
# ASC_API_ISSUER_ID (see docs/RELEASE.md), `gh auth login`, and main pushed.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VERSION=${PHONE_VERSION:-1.0.0}
TAG="v$VERSION"
NOTES="$ROOT/docs/releases/$VERSION.md"
DRAFT=""
[ "${1:-}" = "--draft" ] && DRAFT="--draft"

: "${PHONE_TEAM_ID:?Set PHONE_TEAM_ID}"
: "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID}"
: "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID}"
[ -f "$NOTES" ] || { echo "Release notes missing: $NOTES" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login" >&2; exit 1; }

cd "$ROOT"
if [ -n "$(git status --porcelain)" ]; then
  echo "The working tree is not clean; commit or discard first." >&2
  exit 1
fi
BRANCH=$(git branch --show-current)
[ "$BRANCH" = main ] || { echo "Release from main, not from $BRANCH." >&2; exit 1; }
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "main is not pushed (HEAD differs from origin/main). Push first." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists; bump PHONE_VERSION or delete the tag." >&2
  exit 1
fi

sh "$ROOT/scripts/build-app.sh" --direct --dmg --notarize
DMG="$ROOT/dist/Phone-$VERSION.dmg"
[ -f "$DMG" ] || { echo "Disk image missing: $DMG" >&2; exit 1; }

git tag -a "$TAG" -m "Phone $VERSION"
git push origin "$TAG"
gh release create "$TAG" $DRAFT --prerelease --title "Phone $VERSION" --notes-file "$NOTES" "$DMG"
echo "Release $TAG: $(gh release view "$TAG" --json url --jq .url)"
