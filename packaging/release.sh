#!/bin/bash
# Build → sign (Developer ID + hardened runtime) → notarize → staple → package.
#
#   packaging/release.sh                 # full run
#   packaging/release.sh --check         # preflight only (no build, no upload)
#
# Prerequisites you must set up ONCE, by hand (they involve credentials this
# script deliberately never sees — see docs/09):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --apple-id <你的 Apple ID> --team-id Z48W7TAXR4 --password <app-专用密码>
set -euo pipefail

TEAM_ID="${TEAM_ID:-Z48W7TAXR4}"
NOTARY_PROFILE="${NOTARY_PROFILE:-dnswitch}"
IDENTITY="${IDENTITY:-Developer ID Application}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO/app"
DERIVED="$APP_DIR/build-release"
APP="$DERIVED/Build/Products/Release/DNSwitch.app"
DIST="$REPO/dist"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
step "Preflight"

# A Development certificate CANNOT be notarized — Apple rejects the submission.
# Catch that here rather than after a 10-minute build and an upload.
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
	die "no \"$IDENTITY\" certificate in the keychain.
     Xcode › Settings › Accounts › (your team) › Manage Certificates › + › Developer ID Application
     (needs a paid membership and the Account Holder / Admin role). See docs/09 §1."
fi
echo "✓ signing identity: $(security find-identity -v -p codesigning | grep "$IDENTITY" | head -1 | sed 's/^ *[0-9]*) [0-9A-F]* //')"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
	die "no notarytool keychain profile named \"$NOTARY_PROFILE\".
     Create an app-specific password at appleid.apple.com, then run (yourself — this
     script never handles the password):
       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
         --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>"
fi
echo "✓ notarytool profile: $NOTARY_PROFILE"

command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
command -v go >/dev/null || export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
command -v go >/dev/null || die "go not found"
echo "✓ toolchain"

[ "${1:-}" = "--check" ] && { echo; echo "preflight only — nothing built."; exit 0; }

# ---------------------------------------------------------------- build
step "Build (universal, Developer ID, hardened runtime)"
cd "$APP_DIR"
xcodegen generate >/dev/null
rm -rf "$DERIVED"

# CODE_SIGN_STYLE=Manual: automatic signing would pick the Development cert.
# ENABLE_HARDENED_RUNTIME + --timestamp are also read by build-engine.sh, which
# signs the nested engine the same way (notarization checks every executable).
xcodebuild -project DNSwitch.xcodeproj -scheme DNSwitch -configuration Release \
	-derivedDataPath "$DERIVED" \
	ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
	CODE_SIGN_STYLE=Manual \
	CODE_SIGN_IDENTITY="$IDENTITY" \
	DEVELOPMENT_TEAM="$TEAM_ID" \
	ENABLE_HARDENED_RUNTIME=YES \
	OTHER_CODE_SIGN_FLAGS="--timestamp" \
	build | grep -E "error:|warning: .*\.swift|BUILD" || true

[ -d "$APP" ] || die "build produced no app at $APP"

# ---------------------------------------------------------------- verify
step "Verify the signature before spending a notarization round-trip"
codesign --verify --deep --strict --verbose=2 "$APP"
for bin in "$APP/Contents/MacOS/DNSwitch" "$APP/Contents/MacOS/dnswitch-engine"; do
	name="$(basename "$bin")"
	info="$(codesign -dv --verbose=4 "$bin" 2>&1)"
	grep -q "flags=0x10000(runtime)" <<<"$info" || die "$name is missing the hardened runtime"
	grep -q "Developer ID Application" <<<"$info" || die "$name is not Developer ID signed"
	grep -q "Timestamp=" <<<"$info" || die "$name has no secure timestamp"
	echo "✓ $name — Developer ID, hardened runtime, timestamped, $(lipo -archs "$bin")"
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
id="$(grep -m1 -Eo '\bid: [0-9a-f-]{36}' <<<"$out" | head -1 | awk '{print $2}')"
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

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
FINAL="$DIST/DNSwitch-$VERSION.zip"
rm -f "$FINAL" "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$FINAL"

step "Done"
echo "notarized + stapled: $FINAL"
echo "This zip opens on any Mac with no Gatekeeper prompt and no xattr surgery."
