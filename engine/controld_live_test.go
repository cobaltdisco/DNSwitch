//go:build controld_live

package main

// Live Control D checks against the real service. Opt-in only:
//
//	go test -tags controld_live -run ControlD -v ./...
//
// It goes through the same path as a switch (resolve -> buildConfig ->
// proxy.New -> LookupNetIP) but never calls Start, so nothing binds :53 and the
// system DNS is never touched. The paid part runs only when CONTROLD_TEST_RID is
// set; the Resolver ID is a credential, so it is never printed: subtest names
// carry no ID and every error string is scrubbed before it is logged.

import (
	"context"
	"io"
	"log/slog"
	"os"
	"regexp"
	"testing"
	"time"

	"github.com/AdguardTeam/dnsproxy/proxy"
)

var liveProtocols = []string{"dot", "doh", "doh3", "doq"}

func liveLookup(t *testing.T, sel selection, secret string) {
	t.Helper()
	scrub := func(s string) string {
		if secret == "" {
			return s
		}
		return regexp.MustCompile("(?i)"+regexp.QuoteMeta(secret)).ReplaceAllString(s, "<rid>")
	}
	upstreamURL, boot, cerr := sel.resolve()
	if cerr != nil {
		t.Fatalf("resolve: %s", cerr.Code)
	}
	cfg, err := buildConfig(slog.New(slog.NewTextHandler(io.Discard, nil)), upstreamURL, boot)
	if err != nil {
		t.Fatalf("buildConfig: %s", scrub(err.Error()))
	}
	p, err := proxy.New(cfg)
	if err != nil {
		t.Fatalf("proxy.New: %s", scrub(err.Error()))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	defer func() { _ = p.Shutdown(context.Background()) }()
	start := time.Now()
	addrs, err := p.LookupNetIP(ctx, "ip", selfTestName)
	if err != nil {
		t.Fatalf("lookup: %s", scrub(err.Error()))
	}
	if len(addrs) == 0 {
		t.Fatalf("lookup: no addresses (REFUSED or empty answer)")
	}
	t.Logf("%d addrs in %v", len(addrs), time.Since(start).Round(time.Millisecond))
}

func TestControlDLiveFree(t *testing.T) {
	for _, proto := range liveProtocols {
		t.Run(proto, func(t *testing.T) {
			liveLookup(t, selection{Provider: "controld", Protocol: proto}, "")
		})
	}
}

func TestControlDLivePaid(t *testing.T) {
	rid := os.Getenv("CONTROLD_TEST_RID")
	if rid == "" {
		t.Skip("CONTROLD_TEST_RID not set")
	}
	for _, dev := range []string{"", "My Mac"} {
		for _, proto := range liveProtocols {
			name := proto
			if dev != "" {
				name += "+device"
			}
			t.Run(name, func(t *testing.T) {
				liveLookup(t, selection{Provider: "controld", Protocol: proto, ID: rid, Device: dev}, rid)
			})
		}
	}
}

// A made-up Resolver ID must FAIL the self-test (Control D answers REFUSED), so
// a wrong ID can never "pass" by landing on the free frontend.
func TestControlDLiveBogusIDFails(t *testing.T) {
	for _, proto := range liveProtocols {
		t.Run(proto, func(t *testing.T) {
			upstreamURL, boot, cerr := selection{Provider: "controld", Protocol: proto, ID: "abcdef1234"}.resolve()
			if cerr != nil {
				t.Fatalf("resolve: %s", cerr.Code)
			}
			cfg, err := buildConfig(slog.New(slog.NewTextHandler(io.Discard, nil)), upstreamURL, boot)
			if err != nil {
				t.Fatal(err)
			}
			p, err := proxy.New(cfg)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = p.Shutdown(context.Background()) }()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			addrs, err := p.LookupNetIP(ctx, "ip", selfTestName)
			if err == nil && len(addrs) > 0 {
				t.Fatalf("bogus Resolver ID resolved (%d addrs); want REFUSED / no addresses", len(addrs))
			}
		})
	}
}
