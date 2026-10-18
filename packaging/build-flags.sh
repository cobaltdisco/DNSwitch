# Release build settings, shared by the QA release-candidate build and
# packaging/release.sh so the bundle QA tests is built exactly like a release.
# Sourced, never executed.
#
# CODE_SIGN_STYLE=Manual: automatic signing would pick the Development cert.
# ENABLE_HARDENED_RUNTIME + --timestamp are also read by build-engine.sh, which
# signs the nested engine the same way (notarization checks every executable).
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: for the `build` action Xcode defaults it
# to YES, which silently injects com.apple.security.get-task-allow (the debugger
# entitlement) into the app binary — and Apple's notary service rejects any
# executable that asks for it.
DNSWITCH_TEAM_ID="${TEAM_ID:-Z48W7TAXR4}"
DNSWITCH_IDENTITY="${IDENTITY:-Developer ID Application}"
DNSWITCH_RELEASE_BUILD_FLAGS=(
	ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
	CODE_SIGN_STYLE=Manual
	CODE_SIGN_IDENTITY="$DNSWITCH_IDENTITY"
	DEVELOPMENT_TEAM="$DNSWITCH_TEAM_ID"
	ENABLE_HARDENED_RUNTIME=YES
	CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
	OTHER_CODE_SIGN_FLAGS="--timestamp"
)
