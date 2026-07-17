package main

import "runtime/debug"

// version and build are stamped at build time via -ldflags "-X main.version=... -X
// main.build=..." (packaging/build-engine.sh) from the app's MARKETING_VERSION and
// CURRENT_PROJECT_VERSION, so the engine matches the app it ships with down to the
// build number. Plain `go build` leaves version "dev". Reported in the status
// response so the app can show it and, later, detect an app/engine version skew
// after an update (new app bundle, old daemon still running) — which a
// build-number-only rebuild would otherwise hide.
var (
	version = "dev"
	build   = ""
)

// engineBuildVersion mirrors the app's About row exactly, e.g. "0.3 (3)"; falls
// back to just the version when the build number is unset or equal.
func engineBuildVersion() string {
	if build == "" || build == version {
		return version
	}
	return version + " (" + build + ")"
}

// dnsproxyVer is the embedded AdGuard dnsproxy module version (e.g. "v0.83.0"),
// read once from the binary's own build info — so it can never drift from what's
// actually linked (unlike a hand-maintained constant). "" if unavailable.
var dnsproxyVer = func() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return ""
	}
	for _, d := range info.Deps {
		if d.Path == "github.com/AdguardTeam/dnsproxy" {
			if d.Replace != nil {
				return d.Replace.Version
			}
			return d.Version
		}
	}
	return ""
}()
