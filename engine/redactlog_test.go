package main

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"
)

// sentinel stands in for the user's real NextDNS profile id. Never put a real
// one in a test — this file is public (H2).
const sentinel = "SENTINELID0000"

// syncBuf is a Writer safe for the goroutines dnsproxy logs from.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// newTestLogger returns a logger wired exactly like the one main gives dnsproxy,
// plus the buffer it writes into.
func newTestLogger(lvl slog.Level) (*slog.Logger, *syncBuf) {
	buf := &syncBuf{}
	h := newRedactHandler(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: lvl}))
	return slog.New(h), buf
}

// TestRedactHandlerDropsUnsafeAttrs covers the flat case: attributes attached to
// a single record.
func TestRedactHandlerDropsUnsafeAttrs(t *testing.T) {
	lg, buf := newTestLogger(slog.LevelDebug)

	lg.Error("exchange failed",
		"upstream", "https://"+sentinel+".dns.nextdns.io/",
		"question", "secret.example.com.",
		"err", "dial tcp "+sentinel+".dns.nextdns.io:443: i/o timeout",
		"status", "timeout on "+sentinel,
		"proto", "udp",
		"elapsed", 5*time.Second,
		"tries", 3,
	)

	out := buf.String()
	// Positive first: if the message itself vanished the sentinel assertion
	// below would pass for the wrong reason.
	if !strings.Contains(out, "exchange failed") {
		t.Fatalf("message was dropped; nothing was tested\ngot: %q", out)
	}
	if !strings.Contains(out, "proto=udp") {
		t.Errorf("allowlisted string key was dropped\ngot: %q", out)
	}
	if !strings.Contains(out, "elapsed=5s") || !strings.Contains(out, "tries=3") {
		t.Errorf("safe non-string kinds were dropped\ngot: %q", out)
	}
	assertNoSentinel(t, out)
	for _, k := range []string{"upstream=", "question=", "err=", "status="} {
		if strings.Contains(out, k) {
			t.Errorf("unsafe key %q survived\ngot: %q", k, out)
		}
	}
}

// TestRedactHandlerDropsPreBoundAttrs is the regression that matters most: a
// handler that only filters in Handle looks correct in the test above and leaks
// everything here. dnsproxy derives loggers this way (proxy/serverudp.go:146).
func TestRedactHandlerDropsPreBoundAttrs(t *testing.T) {
	lg, buf := newTestLogger(slog.LevelDebug)

	derived := lg.With("addr", "https://"+sentinel+".dns.nextdns.io/")
	derived.Error("response received", "status", "timeout for "+sentinel)

	// A second derivation, to catch a wrapper that only survives one hop.
	derived.With("upstream", sentinel+".example").Error("exchange failed")

	out := buf.String()
	if !strings.Contains(out, "response received") || !strings.Contains(out, "exchange failed") {
		t.Fatalf("derived-logger messages missing; nothing was tested\ngot: %q", out)
	}
	assertNoSentinel(t, out)
}

// TestRedactHandlerKeepsSafePreBoundAttrs guards against over-filtering: the
// point is to redact, not to blind the log.
func TestRedactHandlerKeepsSafePreBoundAttrs(t *testing.T) {
	lg, buf := newTestLogger(slog.LevelDebug)
	lg.With("proto", "quic").Warn("upstream failed", "attempt", 2)

	out := buf.String()
	if !strings.Contains(out, "proto=quic") {
		t.Errorf("allowlisted pre-bound attr was dropped\ngot: %q", out)
	}
	if !strings.Contains(out, "attempt=2") {
		t.Errorf("safe record attr was dropped\ngot: %q", out)
	}
}

// TestRedactHandlerGroupFailsClosed: inside a named group our flat key
// allowlist no longer describes the keys being written, so nothing is emitted.
func TestRedactHandlerGroupFailsClosed(t *testing.T) {
	lg, buf := newTestLogger(slog.LevelDebug)
	lg.WithGroup("up").Error("exchange failed", "proto", "tcp", "addr", sentinel)

	out := buf.String()
	if !strings.Contains(out, "exchange failed") {
		t.Fatalf("message was dropped; nothing was tested\ngot: %q", out)
	}
	assertNoSentinel(t, out)
	if strings.Contains(out, "proto=tcp") {
		t.Errorf("grouped attrs must fail closed, even allowlisted keys\ngot: %q", out)
	}
}

// TestRedactHandlerResolvesLogValuer: a LogValuer can expand into a URL, so the
// value must be resolved BEFORE the kind is judged.
func TestRedactHandlerResolvesLogValuer(t *testing.T) {
	lg, buf := newTestLogger(slog.LevelDebug)
	lg.Error("exchange failed", "count", lazyString("https://"+sentinel+".dns.nextdns.io/"))

	out := buf.String()
	if !strings.Contains(out, "exchange failed") {
		t.Fatalf("message was dropped; nothing was tested\ngot: %q", out)
	}
	assertNoSentinel(t, out)
}

type lazyString string

func (l lazyString) LogValue() slog.Value { return slog.StringValue(string(l)) }

// TestRedactHandlerEnabledDelegates: a blanket true would make the library
// format records that are then thrown away.
func TestRedactHandlerEnabledDelegates(t *testing.T) {
	h := newRedactHandler(slog.NewTextHandler(&syncBuf{}, &slog.HandlerOptions{Level: slog.LevelWarn}))
	if h.Enabled(context.Background(), slog.LevelDebug) {
		t.Error("Enabled must delegate to the inner handler, not return true")
	}
	if !h.Enabled(context.Background(), slog.LevelError) {
		t.Error("Enabled refused a level the inner handler accepts")
	}
}

func assertNoSentinel(t *testing.T, out string) {
	t.Helper()
	if strings.Contains(out, sentinel) {
		t.Errorf("SENTINEL LEAKED into the log\ngot: %q", out)
	}
	if strings.Contains(out, "nextdns.io") {
		t.Errorf("upstream hostname leaked into the log\ngot: %q", out)
	}
	if strings.Contains(out, "secret.example.com") {
		t.Errorf("queried name leaked into the log\ngot: %q", out)
	}
}
