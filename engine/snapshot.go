package main

// Persisted snapshot of the system's original DNS settings, so we can restore
// them on exit — and, crucially, reconcile after an unclean crash where the
// system is left pinned at 127.0.0.1 with nothing listening (docs/05 §F, B8).

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// snapshotDir holds both persisted files. A var rather than a const so tests can
// point it at a temp dir — /var/db/dnswitch is 0700 root-owned, and a test run
// under sudo against the real path would delete the live machine's snapshot.
//
// Deliberately ONE var with the filenames derived at each use: three separate
// path vars would let a test that overrides only one of them silently write the
// real thing.
var snapshotDir = "/var/db/dnswitch"

func snapshotFile() string { return filepath.Join(snapshotDir, "dns-snapshot.json") }
func stateFile() string    { return filepath.Join(snapshotDir, "state.json") }

// serviceDNS records one network service's original DNS servers. An empty
// Servers slice means the service was on DHCP (networksetup "Empty").
type serviceDNS struct {
	Service string   `json:"service"`
	Servers []string `json:"servers"`
}

type snapshot struct {
	Version  int          `json:"version"`
	PinnedTo string       `json:"pinned_to"`
	Services []serviceDNS `json:"services"`
}

// saveSnapshot atomically writes s via temp file + fsync + rename. It MUST be
// called before the first networksetup write (B-2 atomicity), so a crash mid-pin
// still leaves a complete record to reconcile from.
func saveSnapshot(s *snapshot) error { return atomicWriteJSON(snapshotFile(), s) }

// atomicWriteJSON marshals v and writes it to path atomically: a temp file in
// the same dir, fsync, rename, then dir fsync (so the rename is durable). Creates
// the dir 0700. Shared by the DNS snapshot and the persisted state — durability
// matters for both (a power cut must not leave DNS pinned with no way back).
func atomicWriteJSON(path string, v any) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once renamed; cleans up on error paths
	if _, err = tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err = tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	if err = os.Rename(tmpName, path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

// loadSnapshot returns (nil, nil) when no snapshot exists.
func loadSnapshot() (*snapshot, error) {
	data, err := os.ReadFile(snapshotFile())
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s snapshot
	if err = json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// snapshotExists reports whether a snapshot is on disk. Combined with "we are
// not enabled" this IS the answer to "does the machine still owe the user a
// restore" — the file is written before the first pin, kept when a restore
// fails, and deleted only when one fully succeeds. Deriving the answer from it
// beats storing a flag: the file already survives crashes, reboots and SIGKILL,
// and there is no set-site to forget.
//
// An unreadable-but-present file counts as owed: something is there, and the
// conservative reading is the one that keeps warning the user.
func snapshotExists() bool {
	_, err := os.Stat(snapshotFile())
	return !os.IsNotExist(err)
}

func deleteSnapshot() error {
	if err := os.Remove(snapshotFile()); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
