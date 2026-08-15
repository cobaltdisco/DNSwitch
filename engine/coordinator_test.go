package main

import (
	"io"
	"log/slog"
	"strings"
	"testing"
)

// newTestCoordinator wires a coordinator to a scripted networksetup. ctrl is a
// zero controller: none of the paths exercised here touch the proxy (disable
// and status never do), and running() on a nil proxy is false, which is what a
// not-yet-started engine reports anyway.
func newTestCoordinator(t *testing.T, f *fakeNet) *coordinator {
	t.Helper()
	lg := slog.New(slog.NewTextHandler(io.Discard, nil))
	return newCoordinator(lg, &controller{logger: lg, dnsLogger: lg}, newTestDNS(t, f))
}

func disableReq() request {
	off := false
	return request{V: protocolVersion, Cmd: "set_enabled", Enabled: &off}
}

func countCalls(f *fakeNet, prefix string) int {
	n := 0
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

// T1: the finding that sank the first design. A disable whose restore only
// partly succeeds must still clear `enabled` — that flag gates the watchdog's
// re-pin, so leaving it set would put our pin straight back on the services
// that DID come back, about a second later.
//
// Deliberately a PARTIAL failure: with every service failing, the wrong design
// passes this too (nothing was restored, so nothing can be re-pinned). Only the
// partial shape distinguishes them.
func TestDisableWithPartialRestoreFailureStillDisables(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	f.add("Ethernet", "8.8.4.4")
	c := newTestCoordinator(t, f)

	if err := c.dns.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	c.enabled = true

	f.failSet["Wi-Fi"] = true // Ethernet restores, Wi-Fi does not
	resp := c.handle(disableReq())

	if !resp.OK {
		t.Fatalf("disable should still report ok, got error %+v", resp.Error)
	}
	if c.enabled {
		t.Fatal("enabled must be cleared even when the restore failed — the watchdog gates on it")
	}
	if resp.State == nil || !resp.State.RestoreOwed {
		t.Error("state should report restoreOwed after a failed restore")
	}
	if got := f.dns["Ethernet"]; len(got) != 1 || got[0] != "8.8.4.4" {
		t.Errorf("Ethernet should have been restored, got %v", got)
	}

	// The watchdog now fires. It must leave the restored service alone.
	before := countCalls(f, "-setdnsservers")
	c.onNetworkChange()
	if countCalls(f, "-setdnsservers") != before {
		t.Error("watchdog re-pinned after a failed disable; it must not")
	}
	if got := f.dns["Ethernet"]; len(got) != 1 || got[0] != "8.8.4.4" {
		t.Errorf("watchdog clobbered the restored value: %v", got)
	}
}

// T5: pressing the toggle again after a failed restore must actually retry. The
// old `if c.enabled` guard made the obvious remedy a no-op, because the first
// disable had already cleared the flag.
func TestSecondDisableRetriesTheRestore(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	c := newTestCoordinator(t, f)

	if err := c.dns.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	c.enabled = true

	f.failSet["Wi-Fi"] = true
	if resp := c.handle(disableReq()); !resp.OK {
		t.Fatalf("first disable: %+v", resp.Error)
	}
	if got := f.dns["Wi-Fi"]; len(got) != 1 || got[0] != localDNS {
		t.Fatalf("precondition: Wi-Fi should still be pinned, got %v", got)
	}

	f.failSet["Wi-Fi"] = false // whatever was wrong has cleared
	resp := c.handle(disableReq())

	if !resp.OK {
		t.Fatalf("retry should succeed: %+v", resp.Error)
	}
	if got := f.dns["Wi-Fi"]; len(got) != 1 || got[0] != "9.9.9.9" {
		t.Errorf("retry did not restore: %v", got)
	}
	if resp.State != nil && resp.State.RestoreOwed {
		t.Error("restoreOwed should have cleared once the restore succeeded")
	}
	if snapshotExists() {
		t.Error("a fully successful restore should have deleted the snapshot")
	}
}

// T6: guard rail on the derived flag. While enabled, a snapshot on disk is
// normal and must never read as "a restore is owed".
func TestRestoreOwedFalseWhileEnabled(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	c := newTestCoordinator(t, f)

	if err := c.dns.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	c.enabled = true

	if !snapshotExists() {
		t.Fatal("precondition: enabling writes a snapshot")
	}
	if c.stateLocked().RestoreOwed {
		t.Error("restoreOwed must be false while enabled — the snapshot is expected there")
	}
}

// A clean disable owes nothing and says so.
func TestCleanDisableOwesNothing(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	c := newTestCoordinator(t, f)

	if err := c.dns.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	c.enabled = true

	resp := c.handle(disableReq())
	if !resp.OK || resp.State == nil {
		t.Fatalf("disable failed: %+v", resp.Error)
	}
	if resp.State.RestoreOwed {
		t.Error("a clean disable must not report restoreOwed")
	}
	if got := f.dns["Wi-Fi"]; len(got) != 1 || got[0] != "9.9.9.9" {
		t.Errorf("Wi-Fi not restored: %v", got)
	}
}

// A disable arriving while a deferred pin is still pending must not pin
// everything first just to unpin it again — that would hold the lock through
// two full rounds of networksetup to arrive where the user asked to be.
func TestDisableSkipsPendingPinRetry(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	c := newTestCoordinator(t, f)
	c.pending = true

	resp := c.handle(disableReq())
	if !resp.OK {
		t.Fatalf("disable failed: %+v", resp.Error)
	}
	if n := countCalls(f, "-setdnsservers"); n != 0 {
		t.Errorf("pending retry ran during a disable: %d setdnsservers calls", n)
	}
	if got := f.dns["Wi-Fi"]; len(got) != 1 || got[0] != "9.9.9.9" {
		t.Errorf("Wi-Fi should be untouched, got %v", got)
	}
}
