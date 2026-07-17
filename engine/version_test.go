package main

import (
	"strings"
	"testing"
)

// dnsproxyVer is read from the binary's build info at init; if the module path
// ever changes (or -trimpath/build settings stop preserving deps), it silently
// goes empty. Guard against that: the About view would show a blank otherwise.
func TestDnsproxyVersionResolved(t *testing.T) {
	if dnsproxyVer == "" {
		t.Fatal("dnsproxyVer is empty — ReadBuildInfo found no github.com/AdguardTeam/dnsproxy dep")
	}
	if !strings.HasPrefix(dnsproxyVer, "v") {
		t.Errorf("dnsproxyVer = %q, want a v-prefixed module version", dnsproxyVer)
	}
}
