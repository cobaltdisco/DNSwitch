package main

import (
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// These exercise the read-only cgo entry points (no root required) so we catch
// CoreFoundation/Security misuse — crashes, leaks-into-panics, bad returns —
// that a plain compile would miss.

func TestConsoleUserDoesNotCrash(t *testing.T) {
	uid, ok := consoleUser() // may be (0,false) in a headless test session
	if !ok && uid != 0 {
		t.Fatalf("consoleUser: not ok but uid=%d (want 0)", uid)
	}
}

func TestOwnTeamIDDoesNotCrash(t *testing.T) {
	// A `go test` binary is unsigned/ad-hoc → empty team is the expected result;
	// we only require the call to return without crashing.
	_ = ownTeamID()
}

func TestVPNServiceNames(t *testing.T) {
	names, err := vpnServiceNames()
	if err != nil {
		t.Fatalf("vpnServiceNames: %v", err)
	}
	for n := range names { // whatever it returns, entries must be non-empty
		if n == "" {
			t.Fatal("vpnServiceNames returned an empty service name")
		}
	}
}

func TestPeerRequirementFormat(t *testing.T) {
	got := peerRequirement("Z48W7TAXR4")
	want := `anchor apple generic and certificate leaf[subject.OU] = "Z48W7TAXR4"`
	if got != want {
		t.Fatalf("peerRequirement = %q, want %q", got, want)
	}
}

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// A burst of notifications must collapse into exactly one onEvent, and only
// after the debounce interval has elapsed.
func TestWatchdogDebounceCoalesces(t *testing.T) {
	var calls atomic.Int32
	w := newWatchdog(quietLogger(), func() { calls.Add(1) })
	w.debounce = 30 * time.Millisecond
	go w.loop()
	defer w.stop()

	for i := 0; i < 20; i++ {
		w.events <- struct{}{}
		time.Sleep(time.Millisecond)
	}
	if got := calls.Load(); got != 0 {
		t.Fatalf("onEvent fired %d times during the burst; want 0 (still debouncing)", got)
	}
	time.Sleep(80 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("onEvent fired %d times after debounce; want exactly 1", got)
	}
}

// A second burst after the first settled must produce a second onEvent.
func TestWatchdogDebounceRearms(t *testing.T) {
	var calls atomic.Int32
	w := newWatchdog(quietLogger(), func() { calls.Add(1) })
	w.debounce = 20 * time.Millisecond
	go w.loop()
	defer w.stop()

	w.events <- struct{}{}
	time.Sleep(60 * time.Millisecond)
	w.events <- struct{}{}
	time.Sleep(60 * time.Millisecond)
	if got := calls.Load(); got != 2 {
		t.Fatalf("onEvent fired %d times across two settled bursts; want 2", got)
	}
}

// stop must be idempotent and safe even if the loop never ran.
func TestWatchdogStopIdempotent(t *testing.T) {
	w := newWatchdog(quietLogger(), func() {})
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); w.stop() }()
	}
	wg.Wait()
}
