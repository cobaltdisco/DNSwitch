package main

// Persisted snapshot of the system's original DNS settings, so we can restore
// them on exit — and, crucially, reconcile after an unclean crash where the
// system is left pinned at 127.0.0.1 with nothing listening (docs/05 §F, B8).

import (
	"encoding/json"
	"os"
)

const (
	snapshotDir  = "/var/db/dnswitch"
	snapshotFile = snapshotDir + "/dns-snapshot.json"
)

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
func saveSnapshot(s *snapshot) error {
	if err := os.MkdirAll(snapshotDir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(snapshotDir, "dns-snapshot-*.tmp")
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
	if err = os.Rename(tmpName, snapshotFile); err != nil {
		return err
	}
	// SF-5: fsync the directory so the rename is durable. The pin itself
	// (networksetup) is persisted to macOS preferences; the recovery snapshot
	// must be at least as durable, or a power cut could leave DNS pinned with no
	// snapshot to reconcile from.
	dir, err := os.Open(snapshotDir)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// loadSnapshot returns (nil, nil) when no snapshot exists.
func loadSnapshot() (*snapshot, error) {
	data, err := os.ReadFile(snapshotFile)
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

func deleteSnapshot() error {
	if err := os.Remove(snapshotFile); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
