package main

import "runtime/debug"

// version is the engine's own build version, stamped at build time via
// -ldflags "-X main.version=<MARKETING_VERSION>" (packaging/build-engine.sh), so
// it matches the app it ships with. Plain `go build` leaves it "dev". Reported in
// the status response so the app can show it and, later, detect an app/engine
// version skew after an update (new app bundle, old daemon still running).
var version = "dev"

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
