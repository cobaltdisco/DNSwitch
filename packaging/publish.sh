#!/bin/bash
# Push → tag → GitHub Release, for the zip packaging/release.sh produced.
#
#   packaging/publish.sh <release-notes.md>
#
# Run it only after release.sh succeeded. It publishes nothing else: the zip must
# be the one release.sh wrote for the current commit (checked by its sha256), so
# what users download is the App the QA tested.
#
# Safe to run again after a failure: a tag or Release that already exists for
# this commit and this zip is accepted, anything else stops the script. It never
# force-pushes, moves a tag, or edits or deletes an existing Release.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_REPO="cobaltdisco/DNSwitch"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: packaging/publish.sh <release-notes.md>"
NOTES="$1"
[ -s "$NOTES" ] || die "release notes file is missing or empty: $NOTES"

cd "$REPO"

# ---------------------------------------------------------------- checks
step "Checks"
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' app/project.yml)"
TAG="v$VERSION"
ZIP="dist/DNSwitch-$VERSION.zip"
MANIFEST="$ZIP.release.json"
HEAD="$(git rev-parse HEAD)"

[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = "main" ] || die "not on branch main"
[ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes"
[ -f "$ZIP" ] && [ -f "$MANIFEST" ] || die "no $ZIP from release.sh — run packaging/release.sh first"

read -r m_version m_commit m_sha < <(/usr/bin/python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["version"], m["commit"], m["sha256"])' "$MANIFEST")
[ "$m_version" = "$VERSION" ] || die "$ZIP was built for $m_version, the project is at $VERSION"
[ "$m_commit" = "$HEAD" ] || die "$ZIP was produced at ${m_commit:0:7}, HEAD is ${HEAD:0:7}"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
[ "$SHA" = "$m_sha" ] || die "$ZIP changed after release.sh wrote it"
echo "✓ $ZIP is release.sh's output for ${HEAD:0:7}"

gh auth status >/dev/null 2>&1 || die "gh is not logged in"
git fetch --quiet origin main --tags
git merge-base --is-ancestor origin/main HEAD || die "origin/main has commits that HEAD lacks — pull first"

local_tag="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)"
if [ -n "$local_tag" ]; then
	[ "$local_tag" = "$HEAD" ] || die "tag $TAG already exists on ${local_tag:0:7}, not HEAD"
fi
remote_tag="$(git ls-remote origin "refs/tags/$TAG" | cut -f1)"
[ -z "$remote_tag" ] || [ "$remote_tag" = "$HEAD" ] || die "tag $TAG on GitHub points at ${remote_tag:0:7}, not HEAD"
echo "✓ $TAG is free or already on HEAD"

# ---------------------------------------------------------------- push
step "Push main and $TAG"
git push origin HEAD:refs/heads/main
[ -n "$local_tag" ] || git tag "$TAG" "$HEAD"
git push origin "refs/tags/$TAG"

# ---------------------------------------------------------------- release
step "GitHub Release $TAG"
if gh release view "$TAG" -R "$GH_REPO" >/dev/null 2>&1; then
	echo "Release $TAG already exists — checking its zip instead of creating it."
else
	gh release create "$TAG" "$ZIP" -R "$GH_REPO" --verify-tag --title "$TAG" --notes-file "$NOTES"
fi

digest="$(gh release view "$TAG" -R "$GH_REPO" --json assets \
	-q ".assets[] | select(.name == \"DNSwitch-$VERSION.zip\") | .digest")"
[ "$digest" = "sha256:$SHA" ] || die "the zip on the Release ($digest) is not the local one (sha256:$SHA)"
echo "✓ uploaded zip matches sha256:$SHA"

step "Done"
gh release view "$TAG" -R "$GH_REPO" --json url -q .url
