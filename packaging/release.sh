#!/bin/bash
# QA gate → notarize the App that QA tested → staple → package.
#
#   packaging/release.sh                 # full run
#   packaging/release.sh --check         # preflight + QA gate only (no upload)
#
# This script does not build. The release candidate is built (with the flags in
# packaging/build-flags.sh) and tested by the pre-release QA — run
# /dnswitch-release-qa in Claude Code — and only a passing (GO) QA report for the
# current commit lets it through. It then notarizes that very bundle, so what
# ships is byte-for-byte what was tested. There is no switch to skip the gate.
#
# Prerequisites you must set up ONCE, by hand (they involve credentials this
# script deliberately never sees — see docs/09):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --apple-id <your-apple-id> --team-id Z48W7TAXR4 --password <app-specific-password>
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/packaging/build-flags.sh"
TEAM_ID="$DNSWITCH_TEAM_ID"
IDENTITY="$DNSWITCH_IDENTITY"
NOTARY_PROFILE="${NOTARY_PROFILE:-dnswitch}"
DIST="$REPO/dist"
QA_MAX_AGE_HOURS=72

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

case "$#:${1:-}" in 0:|1:--check) ;; *) die "usage: packaging/release.sh [--check]" ;; esac

# ---------------------------------------------------------------- preflight
step "Preflight"

# A Development certificate CANNOT be notarized — Apple rejects the submission.
# Catch that here rather than after a 10-minute build and an upload.
if ! grep -q "$IDENTITY" <<<"$(security find-identity -v -p codesigning)"; then
	die "no \"$IDENTITY\" certificate in the keychain.
     Xcode › Settings › Accounts › (your team) › Manage Certificates › + › Developer ID Application
     (needs a paid membership and the Account Holder / Admin role). See docs/09 §1."
fi
echo "✓ signing identity: $(security find-identity -v -p codesigning | grep "$IDENTITY" | head -1 | sed 's/^ *[0-9]*) [0-9A-F]* //')"

# This also fails when offline or when the stored credentials were revoked, so the
# message says "or" rather than misdiagnosing it as a missing profile.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
	die "notarytool can't use the profile \"$NOTARY_PROFILE\" — it's missing, its
     credentials were revoked, or you're offline. To create it, get an app-specific
     password at appleid.apple.com and run it YOURSELF (this script never handles
     the password):
       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
         --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>"
fi
echo "✓ notarytool profile: $NOTARY_PROFILE"


# ---------------------------------------------------------------- QA gate
step "QA gate"
# The newest QA run for this version must be a GO for exactly this commit,
# from the release (or full) profile, run and built on a clean tree, with no
# baseline change awaiting the user and no older than QA_MAX_AGE_HOURS. The App
# it tested is copied aside and checked against the report's per-architecture
# cdhashes; from then on only that copy is used.
#
# This guards against mistakes (no QA, a stale or partial run, a changed or
# rebuilt bundle), not against someone deliberately editing the report: whoever
# can do that can also edit this script.
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$REPO/app/project.yml")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dnswitch-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 130' INT TERM HUP # route signals through the EXIT cleanup
set +e
GATE_OUT="$(/usr/bin/python3 -I "$REPO/packaging/qa_gate.py" gate "$REPO" "$VERSION" "$QA_MAX_AGE_HOURS" "$STAGE/expected.json")"
GATE_RC=$?
set -e
if [ $GATE_RC -ne 0 ]; then
	printf '\033[31mQA gate: not releasable\033[0m\n' >&2
	printf '%s\n' "$GATE_OUT" | sed 's/^/  - /' >&2
	echo >&2
	die "Run /dnswitch-release-qa in Claude Code first (it must end in GO for this commit)."
fi

# check_tested <bundle>: both binaries, both architectures, equal to what QA recorded.
check_tested() { /usr/bin/python3 -I "$REPO/packaging/qa_gate.py" check "$1" "$STAGE/expected.json"; }

# From here on only a private copy is used, so nothing can swap the bundle
# between this check and the upload.
ditto "$GATE_OUT" "$STAGE/DNSwitch.app"
APP="$STAGE/DNSwitch.app"
check_tested "$APP" || die "the staged copy is not the App QA tested"
echo "✓ QA GO for $(git -C "$REPO" rev-parse --short HEAD); shipping the tested App (${GATE_OUT#$REPO/})"

[ "${1:-}" = "--check" ] && { echo; echo "preflight + QA gate only — nothing uploaded."; exit 0; }

# ---------------------------------------------------------------- verify
step "Verify the signature before spending a notarization round-trip"
codesign --verify --deep --strict --verbose=2 "$APP"
for bin in "$APP/Contents/MacOS/DNSwitch" "$APP/Contents/MacOS/dnswitch-engine"; do
	name="$(basename "$bin")"
	info="$(codesign -dv --verbose=4 "$bin" 2>&1)" || die "codesign could not read $name"
	# "(runtime", not "flags=0x10000(runtime)": flags print combined, e.g.
	# 0x10002(adhoc,runtime), and an exact match would false-negative.
	grep -q "(runtime" <<<"$info" || die "$name is missing the hardened runtime"
	grep -q "Developer ID Application" <<<"$info" || die "$name is not Developer ID signed"
	grep -q "Timestamp=" <<<"$info" || die "$name has no secure timestamp"
	# The rejection Xcode hands you for free (see CODE_SIGN_INJECT_BASE_ENTITLEMENTS
	# above). Checked here too, because the build setting is one typo from silently
	# coming back — and this is the failure that costs a whole upload to discover.
	# Read first (a failed read must not look like "no entitlement"), then match;
	# never `| grep -q`, which under pipefail can turn a match into a failure.
	ents="$(codesign -d --entitlements - "$bin" 2>/dev/null)" || die "codesign could not read the entitlements of $name"
	if grep -q "get-task-allow" <<<"$ents"; then
		die "$name requests com.apple.security.get-task-allow — notarization will reject it"
	fi
	archs="$(lipo -archs "$bin")"
	[ "$archs" = "x86_64 arm64" ] || [ "$archs" = "arm64 x86_64" ] \
		|| die "$name is not universal (got: $archs)"
	echo "✓ $name — Developer ID, hardened runtime, timestamped, no get-task-allow, $archs"
done

# ---------------------------------------------------------------- notarize
step "Notarize"
mkdir -p "$DIST"
ZIP="$DIST/DNSwitch-notarize.zip"
rm -f "$ZIP"
# ditto, not zip(1): zip mangles the bundle's extended attributes and signature.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

set +e
out="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
rc=$?
set -e
echo "$out"
# `|| true`: on an auth/network failure the output carries no id, grep exits 1,
# and under `set -e` the assignment itself would kill the script — skipping the
# log dump and the die message below, i.e. exactly the diagnostics we came for.
id="$(grep -m1 -Eo '\bid: [0-9a-f-]{36}' <<<"$out" | awk '{print $2}' || true)"
if [ $rc -ne 0 ] || ! grep -q "status: Accepted" <<<"$out"; then
	[ -n "$id" ] && { echo; echo "--- notarization log ---"; xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true; }
	die "notarization did not succeed"
fi

# ---------------------------------------------------------------- staple
step "Staple + final checks"
# Staples the ticket INTO the .app, so a machine that is offline (or has never
# seen this app) still passes Gatekeeper without asking Apple.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" 2>&1 | grep -E "accepted|source=" || die "spctl rejected the app"

# Stapling adds the ticket outside the signature, so the code must still be
# exactly what QA tested.
check_tested "$APP" || die "the stapled App is not the one QA tested"
echo "✓ cdhashes unchanged after staple (both architectures)"

[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")" = "$VERSION" ] || die "App version is not $VERSION"
FINAL="$DIST/DNSwitch-$VERSION.zip"
rm -f "$FINAL" "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$FINAL"

# ---------------------------------------------------------------- after-notarization checks (QA P02, P07)
step "Check the zip a user downloads"
CHECK="$STAGE/download"
mkdir -p "$CHECK"
ditto -x -k "$FINAL" "$CHECK"
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$CHECK/DNSwitch.app"
check_tested "$CHECK/DNSwitch.app" || die "the zip does not contain the App QA tested"
set +e; assess="$(spctl -a -vvv -t exec "$CHECK/DNSwitch.app" 2>&1)"; arc=$?; set -e
[ $arc -eq 0 ] && grep -q "source=Notarized Developer ID" <<<"$assess" || die "P02: the downloaded copy is not accepted as Notarized Developer ID"
xcrun stapler validate "$CHECK/DNSwitch.app" >/dev/null || die "P02: the downloaded copy has no valid ticket"
echo "✓ P02 notarized, stapled, accepted with quarantine"
for f in LICENSE THIRD-PARTY-LICENSES; do
	[ -s "$CHECK/DNSwitch.app/Contents/Resources/$f" ] || die "P07: $f missing from the bundle"
done
[ -z "$(find "$CHECK" -name .DS_Store)" ] || die "P07: .DS_Store inside the zip"
echo "✓ P07 licenses present, no .DS_Store"

# What packaging/publish.sh checks before it pushes and uploads: this zip, from this commit.
printf '{"version": "%s", "commit": "%s", "sha256": "%s"}\n' \
	"$VERSION" "$(git -C "$REPO" rev-parse HEAD)" "$(shasum -a 256 "$FINAL" | cut -d' ' -f1)" \
	>"$FINAL.release.json"

step "Done"
echo "notarized + stapled: $FINAL"
echo "On any Mac: unzip, drag to /Applications, open. No right-click→Open, no"
echo "xattr surgery. (A quarantined app still shows the one-time \"downloaded from"
echo "the Internet\" confirmation — that's the normal prompt, not a Gatekeeper block.)"
