package main

import (
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/AdguardTeam/dnsproxy/proxy"
)

// TestRedactHandlerAgainstRealDnsproxy drives the actual library through the
// exact wiring main uses, and proves the sentinel never reaches the sink.
//
// The unit tests above pin the handler's contract; this one pins the thing that
// contract exists for, and would catch a dnsproxy upgrade that starts logging
// the upstream under a new attribute key.
//
// Blackholed at 192.0.2.1 (RFC 5737 TEST-NET-1, guaranteed unrouted), so the
// bootstrap lookup times out — which is the branch that matters: logFinish only
// escalates to Error on a TIMEOUT (upstream/upstream.go:361). A refused port
// would exercise a different branch and prove nothing. Costs one Timeout,
// hence -short skips it.
func TestRedactHandlerAgainstRealDnsproxy(t *testing.T) {
	if testing.Short() {
		t.Skip("blackhole timeout test; skipped under -short")
	}

	lg, buf := newTestLogger(slog.LevelWarn) // same level main gives dnsproxy

	upstreamURL := "tls://" + sentinel + ".dns.example.invalid:853"
	cfg, err := buildConfig(lg, upstreamURL, "192.0.2.1")
	if err != nil {
		t.Fatalf("buildConfig: %v", err)
	}
	prx, err := proxy.New(cfg)
	if err != nil {
		t.Fatalf("proxy.New: %v", err)
	}

	// Not Start()ed: binding :53 needs root, and LookupNetIP drives the upstream
	// path without a listener (same call swapTo self-tests with).
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := prx.LookupNetIP(ctx, "ip", "example.org"); err == nil {
		t.Fatal("lookup unexpectedly succeeded against a blackhole — test is not exercising the failure path")
	}
	_ = prx.Shutdown(context.Background())

	out := buf.String()

	// Positive assertions FIRST. Without these a handler that dropped every
	// record — or a dnsproxy that stopped logging here — would sail through the
	// sentinel check below having tested nothing at all.
	if out == "" {
		t.Fatal("dnsproxy logged nothing; the redaction assertions below would be vacuous")
	}
	if !strings.Contains(out, "exchange failed") && !strings.Contains(out, "response received") {
		t.Fatalf("neither known failure message appeared; the leak paths were not exercised\ngot: %q", out)
	}

	// And now the point.
	if strings.Contains(out, sentinel) {
		t.Errorf("SENTINEL LEAKED from real dnsproxy into the log\ngot: %q", out)
	}
	if strings.Contains(out, "example.invalid") {
		t.Errorf("upstream hostname leaked from real dnsproxy\ngot: %q", out)
	}
	if strings.Contains(out, "example.org") {
		t.Errorf("queried name leaked from real dnsproxy\ngot: %q", out)
	}
	t.Logf("redacted library output (%d bytes):\n%s", len(out), out)
}
