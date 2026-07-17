#!/bin/bash
# Xcode Run-Script phase (docs/07 §1): build the Go engine, embed it in the app
# bundle, and sign it — all BEFORE Xcode's final code-sign seals the bundle, or
# the seal breaks (the classic SMAppService packaging trap).
#
# Honors $ARCHS, so a local arm64 dev build stays single-slice while a Release
# archive that builds arm64+x86_64 produces a universal engine automatically.
set -euo pipefail

# Xcode's build environment has a minimal PATH; go isn't on it.
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$PATH"
if ! command -v go >/dev/null 2>&1; then
	echo "error: 'go' not found on PATH; install Go or edit packaging/build-engine.sh" >&2
	exit 1
fi

ENGINE_SRC="$SRCROOT/../engine"
CONTENTS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"
MACOS_DIR="$CONTENTS/MacOS"
DAEMONS_DIR="$CONTENTS/Library/LaunchDaemons"
ENGINE_OUT="$MACOS_DIR/dnswitch-engine"
mkdir -p "$MACOS_DIR" "$DAEMONS_DIR"

CLANG="$(xcrun -f clang)"
# Stamp the engine's own build version to match the app it ships with, down to the
# build number (Xcode exposes MARKETING_VERSION + CURRENT_PROJECT_VERSION here). The
# app shows it in Settings › About and can later detect an app/engine skew after an
# update. The dnsproxy version is NOT stamped — the engine reads it from its own
# build info at runtime (version.go), which can't drift. "dev" outside Xcode.
ENGINE_VERSION="${MARKETING_VERSION:-dev}"
ENGINE_BUILD="${CURRENT_PROJECT_VERSION:-}"
slices=()
for arch in $ARCHS; do
	case "$arch" in
		arm64)  goarch=arm64;  clang_arch=arm64  ;;
		x86_64) goarch=amd64;  clang_arch=x86_64 ;;
		*) echo "error: unsupported arch '$arch'" >&2; exit 1 ;;
	esac
	slice="$DERIVED_FILE_DIR/dnswitch-engine-$arch"
	echo "building engine slice: $arch (version $ENGINE_VERSION build $ENGINE_BUILD)"
	( cd "$ENGINE_SRC" && \
	  CGO_ENABLED=1 GOOS=darwin GOARCH="$goarch" \
	  CC="$CLANG -arch $clang_arch -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
	  go build -trimpath -ldflags "-X main.version=$ENGINE_VERSION -X main.build=$ENGINE_BUILD" -o "$slice" . )
	slices+=("$slice")
done

lipo -create "${slices[@]}" -output "$ENGINE_OUT"

# Sign the embedded engine with the SAME identity as the app (nested code must be
# signed before the outer seal).
#
# Notarization requires EVERY executable in the bundle to carry the hardened
# runtime and a secure timestamp — the nested engine included, and Apple rejects
# the whole submission if this one binary misses them. We mirror the app's own
# setting instead of hard-coding: ENABLE_HARDENED_RUNTIME is YES only in the
# release path (packaging/release.sh), so a local dev build stays fast and
# offline (a --timestamp needs to reach Apple's TSA).
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
	sign_flags=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY")
	if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
		sign_flags+=(--options runtime --timestamp)
	fi
	codesign "${sign_flags[@]}" "$ENGINE_OUT"
else
	echo "warning: no code-sign identity; embedding engine unsigned (control socket will be uid-only / daemon fail-closed)" >&2
fi

# Embed the LaunchDaemon plist (SMAppService reads it from here).
cp "$SRCROOT/../packaging/com.fx.dnswitch.engine.plist" "$DAEMONS_DIR/com.fx.dnswitch.engine.plist"

echo "engine embedded at: $ENGINE_OUT ($(lipo -archs "$ENGINE_OUT" 2>/dev/null || echo '?'))"
