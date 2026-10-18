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

command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
command -v go >/dev/null || export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
command -v go >/dev/null || die "go not found"
echo "✓ toolchain"

# ---------------------------------------------------------------- QA gate
step "QA gate"
# The newest QA report for this version must be a GO for exactly this commit,
# from the release (or full) profile, with no visual/perf baseline awaiting the
# user, younger than QA_MAX_AGE_HOURS — and its App must be the one we ship.
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$REPO/app/project.yml")"
set +e
GATE_OUT="$(/usr/bin/python3 -I - "$REPO" "$VERSION" "$QA_MAX_AGE_HOURS" <<'PY'
import datetime, glob, json, os, subprocess, sys
repo, version, max_age = sys.argv[1], sys.argv[2], float(sys.argv[3])
bad = []

def git(*args, cwd=repo):
    return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True).stdout.strip()

def cdhash(path):
    out = subprocess.run(["codesign", "-dvvv", path], capture_output=True, text=True).stderr
    return next((l.split("=", 1)[1] for l in out.splitlines() if l.startswith("CDHash=")), "")

runs = sorted(glob.glob(os.path.join(repo, "dist", "qa", version + "-*", "result.json")), key=os.path.getmtime)
if not runs:
    print("no QA report for version %s in dist/qa/" % version)
    sys.exit(1)
path = runs[-1]
try:
    with open(path, encoding="utf-8") as f:
        r = json.load(f)
except (OSError, ValueError):
    print("QA report unreadable: " + path)
    sys.exit(1)

if r.get("profile") not in ("release", "full"):
    bad.append("QA profile is %r, not release or full" % r.get("profile"))
if r.get("partial") or r.get("dev"):
    bad.append("QA run was partial (--only) or a dev run (--dev)")
if r.get("verdict") != "GO":
    bad.append("QA verdict is %s: %s" % (r.get("verdict"), "; ".join(r.get("verdictReasons", [])[:5])))
if r.get("baselinePending"):
    bad.append("%d visual/performance baseline change(s) await confirmation" % len(r["baselinePending"]))
head = git("rev-parse", "HEAD")
if not head or r.get("commit") != head:
    bad.append("QA tested commit %s, HEAD is %s" % (str(r.get("commit"))[:10], head[:10]))
if git("status", "--porcelain"):
    bad.append("working tree is not clean")
docs = os.path.join(repo, "docs")
if not os.path.isdir(os.path.join(docs, ".git")):
    bad.append("QA repository (docs/) not found")
elif git("status", "--porcelain", cwd=docs):
    bad.append("QA repository (docs/) is not clean")
elif r.get("docsCommit") != git("rev-parse", "HEAD", cwd=docs):
    bad.append("QA repository (docs/) moved since the QA run")
try:
    finished = datetime.datetime.fromisoformat(str(r.get("finishedAt")).replace("Z", "+00:00"))
    age = (datetime.datetime.now(datetime.timezone.utc) - finished).total_seconds() / 3600
    if age > max_age or age < -0.1:
        bad.append("QA report is %.0f hours old (limit %d)" % (age, max_age))
except (TypeError, ValueError):
    bad.append("QA report has no valid finish time")
rc = r.get("rc") or {}
app = rc.get("app", "")
if rc.get("qaVersion"):
    bad.append("the tested App was a --qa-version build, not the release version")
if not app or not os.path.isdir(app):
    bad.append("the App QA tested is gone: " + (app or "?"))
elif not os.path.realpath(app).startswith(os.path.realpath(os.path.join(repo, "dist", "qa", "rc")) + os.sep):
    bad.append("the tested App is not under dist/qa/rc/")
else:
    if not r.get("appCdhash") or cdhash(app) != r.get("appCdhash"):
        bad.append("App cdhash differs from the tested one")
    engine = os.path.join(app, "Contents", "MacOS", "dnswitch-engine")
    if not r.get("engineCdhash") or cdhash(engine) != r.get("engineCdhash"):
        bad.append("engine cdhash differs from the tested one")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print(app)
PY
)"
GATE_RC=$?
set -e
if [ $GATE_RC -ne 0 ]; then
	printf '\033[31mQA gate: not releasable\033[0m\n' >&2
	printf '%s\n' "$GATE_OUT" | sed 's/^/  - /' >&2
	echo >&2
	die "Run /dnswitch-release-qa in Claude Code first (it must end in GO for this commit)."
fi
APP="$GATE_OUT"
APP_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/ {print $2}')"
ENGINE_CDHASH="$(codesign -dvvv "$APP/Contents/MacOS/dnswitch-engine" 2>&1 | awk -F= '/^CDHash=/ {print $2}')"
echo "✓ QA GO for $(git -C "$REPO" rev-parse --short HEAD); shipping the tested App: ${APP#$REPO/}"

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
	# Here-strings, not `| grep -q`: under pipefail an early-exiting grep can
	# make a match look like a failure.
	if grep -q "get-task-allow" <<<"$(codesign -d --entitlements - "$bin" 2>/dev/null)"; then
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
[ "$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/ {print $2}')" = "$APP_CDHASH" ] || die "App cdhash changed during notarization"
[ "$(codesign -dvvv "$APP/Contents/MacOS/dnswitch-engine" 2>&1 | awk -F= '/^CDHash=/ {print $2}')" = "$ENGINE_CDHASH" ] || die "engine cdhash changed during notarization"
echo "✓ cdhash unchanged after staple"

[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")" = "$VERSION" ] || die "App version is not $VERSION"
FINAL="$DIST/DNSwitch-$VERSION.zip"
rm -f "$FINAL" "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$FINAL"

# ---------------------------------------------------------------- after-notarization checks (QA P02, P07)
step "Check the zip a user downloads"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$FINAL" "$CHECK"
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$CHECK/DNSwitch.app"
grep -q "source=Notarized Developer ID" <<<"$(spctl -a -vvv -t exec "$CHECK/DNSwitch.app" 2>&1)" || die "P02: the downloaded copy is not accepted as Notarized Developer ID"
xcrun stapler validate "$CHECK/DNSwitch.app" >/dev/null || die "P02: the downloaded copy has no valid ticket"
echo "✓ P02 notarized, stapled, accepted with quarantine"
for f in LICENSE THIRD-PARTY-LICENSES; do
	[ -s "$CHECK/DNSwitch.app/Contents/Resources/$f" ] || die "P07: $f missing from the bundle"
done
[ -z "$(find "$CHECK" -name .DS_Store)" ] || die "P07: .DS_Store inside the zip"
echo "✓ P07 licenses present, no .DS_Store"

step "Done"
echo "notarized + stapled: $FINAL"
echo "On any Mac: unzip, drag to /Applications, open. No right-click→Open, no"
echo "xattr surgery. (A quarantined app still shows the one-time \"downloaded from"
echo "the Internet\" confirmation — that's the normal prompt, not a Gatekeeper block.)"
