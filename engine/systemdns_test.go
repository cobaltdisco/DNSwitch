package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeNet scripts networksetup: it holds each service's DNS the way the real
// tool does, so pinAll/restoreAll run their real logic against a real-shaped
// world. Substituted through dnsManager.run, so the code under test is the code
// that ships — not a fake dnsManager.
type fakeNet struct {
	dns     map[string][]string // service → servers ("" entry means DHCP)
	order   []string            // -listallnetworkservices order
	gone    map[string]bool     // service exists no more (networksetup exit 4)
	failSet map[string]bool     // -setdnsservers refuses for this service
	calls   []string
}

func newFakeNet() *fakeNet {
	return &fakeNet{
		dns:     map[string][]string{},
		gone:    map[string]bool{},
		failSet: map[string]bool{},
	}
}

func (f *fakeNet) add(service string, servers ...string) {
	f.order = append(f.order, service)
	f.dns[service] = servers
}

func (f *fakeNet) run(args ...string) ([]byte, error) {
	f.calls = append(f.calls, strings.Join(args, " "))
	switch args[0] {
	case "-listallnetworkservices":
		out := "An asterisk (*) denotes that a network service is disabled.\n"
		for _, s := range f.order {
			out += s + "\n"
		}
		return []byte(out), nil
	case "-getdnsservers":
		svc := args[1]
		if f.gone[svc] {
			// Real networksetup writes this to STDOUT and exits 4.
			return []byte(svc + " " + notAServiceMarker + ".\n"), fmt.Errorf("exit status 4")
		}
		if len(f.dns[svc]) == 0 {
			return []byte("There aren't any DNS Servers set on " + svc + ".\n"), nil
		}
		return []byte(strings.Join(f.dns[svc], "\n") + "\n"), nil
	case "-setdnsservers":
		svc := args[1]
		if f.gone[svc] {
			return []byte(svc + " " + notAServiceMarker + ".\n"), fmt.Errorf("exit status 4")
		}
		if f.failSet[svc] {
			return nil, fmt.Errorf("exit status 1")
		}
		vals := args[2:]
		if len(vals) == 1 && vals[0] == "Empty" {
			f.dns[svc] = nil
		} else {
			f.dns[svc] = append([]string(nil), vals...)
		}
		return nil, nil
	}
	return nil, fmt.Errorf("unexpected networksetup call: %v", args)
}

// newTestDNS wires a dnsManager to the fake and points the snapshot at a temp
// dir. The real /var/db/dnswitch is root-only and holds the live machine's
// snapshot — a test that wrote there under sudo would delete it.
func newTestDNS(t *testing.T, f *fakeNet) *dnsManager {
	t.Helper()
	orig := snapshotDir
	snapshotDir = t.TempDir()
	t.Cleanup(func() { snapshotDir = orig })
	return &dnsManager{
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		run:    f.run,
	}
}

func readSnap(t *testing.T) *snapshot {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(snapshotDir, "dns-snapshot.json"))
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	var s snapshot
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatalf("decode snapshot: %v", err)
	}
	return &s
}

func snapServers(t *testing.T, s *snapshot, service string) ([]string, bool) {
	t.Helper()
	for _, e := range s.Services {
		if e.Service == service {
			return e.Servers, true
		}
	}
	return nil, false
}

func snapshotExists(t *testing.T) bool {
	t.Helper()
	_, err := os.Stat(filepath.Join(snapshotDir, "dns-snapshot.json"))
	return err == nil
}

// T2: the bug this whole change exists for. A restore that fails keeps the
// snapshot so a retry is possible; re-enabling must not overwrite the record
// with "was on DHCP" read back off our own pin.
func TestPinAllPreservesOriginalsAfterFailedRestore(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	f.add("Ethernet", "8.8.4.4")
	m := newTestDNS(t, f)

	if err := m.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	// Restore fails on Wi-Fi; Ethernet comes back.
	f.failSet["Wi-Fi"] = true
	if err := m.restoreAll(); err == nil {
		t.Fatal("restoreAll should have reported failure")
	}
	if !snapshotExists(t) {
		t.Fatal("a failed restore must keep the snapshot")
	}
	f.failSet["Wi-Fi"] = false

	// User re-enables. Wi-Fi is still sitting on our pin.
	if got := f.dns["Wi-Fi"]; len(got) != 1 || got[0] != localDNS {
		t.Fatalf("precondition: Wi-Fi should still be pinned, got %v", got)
	}
	if err := m.pinAll(); err != nil {
		t.Fatalf("second pinAll: %v", err)
	}

	snap := readSnap(t)
	got, ok := snapServers(t, snap, "Wi-Fi")
	if !ok {
		t.Fatal("Wi-Fi missing from snapshot")
	}
	if len(got) != 1 || got[0] != "9.9.9.9" {
		t.Errorf("original DNS was destroyed: recorded %v, want [9.9.9.9]", got)
	}
}

// T2b: the mirror image, and the only test that catches a merge which blindly
// prefers the recorded value. If the user picks a NEW resolver while we are off,
// that is their current choice and must replace what we remembered.
func TestPinAllPrefersLiveValueOverStaleRecord(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	m := newTestDNS(t, f)

	if err := m.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	f.failSet["Wi-Fi"] = true
	_ = m.restoreAll() // fails, snapshot retained with 9.9.9.9
	f.failSet["Wi-Fi"] = false

	// User gives up and sets a different resolver by hand.
	f.dns["Wi-Fi"] = []string{"1.1.1.1"}

	if err := m.pinAll(); err != nil {
		t.Fatalf("second pinAll: %v", err)
	}
	got, _ := snapServers(t, readSnap(t), "Wi-Fi")
	if len(got) != 1 || got[0] != "1.1.1.1" {
		t.Errorf("stale record resurrected: recorded %v, want [1.1.1.1]", got)
	}
}

// T3: a snapshot naming a service macOS no longer has must not block enabling.
// Before the write set was anchored on the live services, the stale entry was
// pinned too — and failed every time.
func TestPinAllSucceedsWithStaleSnapshotEntry(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	f.add("Thunderbolt Bridge", "8.8.8.8")
	m := newTestDNS(t, f)

	if err := m.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	f.failSet["Wi-Fi"] = true
	_ = m.restoreAll()
	f.failSet["Wi-Fi"] = false

	// The user renames the bridge, so the snapshot's entry no longer resolves.
	f.gone["Thunderbolt Bridge"] = true
	f.order = []string{"Wi-Fi"}

	if err := m.pinAll(); err != nil {
		t.Fatalf("pinAll must tolerate a stale snapshot entry, got: %v", err)
	}
	if _, ok := snapServers(t, readSnap(t), "Thunderbolt Bridge"); !ok {
		t.Error("stale entry was dropped; it should be kept in case the service returns")
	}
}

// T4: and the stale entry must not wedge restore either — otherwise one renamed
// service means the snapshot is never deleted and every restore reports failure
// from then on.
func TestRestoreAllToleratesVanishedService(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	f.add("Thunderbolt Bridge", "8.8.8.8")
	m := newTestDNS(t, f)

	if err := m.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	f.gone["Thunderbolt Bridge"] = true

	if err := m.restoreAll(); err != nil {
		t.Errorf("a vanished service must not fail the restore: %v", err)
	}
	if snapshotExists(t) {
		t.Error("restore succeeded, so the snapshot should have been deleted")
	}
	if got := f.dns["Wi-Fi"]; len(got) != 1 || got[0] != "9.9.9.9" {
		t.Errorf("Wi-Fi not restored: %v", got)
	}
}

// An unreadable snapshot may be the only copy of the user's DNS. Refuse rather
// than start a fresh one over the top of it.
func TestPinAllRefusesUnreadableSnapshot(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi", "9.9.9.9")
	m := newTestDNS(t, f)

	if err := os.WriteFile(filepath.Join(snapshotDir, "dns-snapshot.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := m.pinAll(); err == nil {
		t.Fatal("pinAll must refuse when the existing snapshot cannot be read")
	}
	if got := f.dns["Wi-Fi"]; len(got) != 1 || got[0] != "9.9.9.9" {
		t.Errorf("refusal must not touch system DNS, got %v", got)
	}
}

// A DHCP original is a nil slice, so snapshot membership has to be tested by
// presence and not by length — otherwise DHCP services silently lose their
// record on the second pin.
func TestPinAllRoundTripsDHCPOriginal(t *testing.T) {
	f := newFakeNet()
	f.add("Wi-Fi") // DHCP
	m := newTestDNS(t, f)

	if err := m.pinAll(); err != nil {
		t.Fatalf("pinAll: %v", err)
	}
	f.failSet["Wi-Fi"] = true
	_ = m.restoreAll()
	f.failSet["Wi-Fi"] = false

	if err := m.pinAll(); err != nil {
		t.Fatalf("second pinAll: %v", err)
	}
	got, ok := snapServers(t, readSnap(t), "Wi-Fi")
	if !ok {
		t.Fatal("Wi-Fi missing from snapshot")
	}
	if len(got) != 0 {
		t.Errorf("DHCP original should stay empty, got %v", got)
	}

	if err := m.restoreAll(); err != nil {
		t.Fatalf("restoreAll: %v", err)
	}
	if len(f.dns["Wi-Fi"]) != 0 {
		t.Errorf("Wi-Fi should be back on DHCP, got %v", f.dns["Wi-Fi"])
	}
}
