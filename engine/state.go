package main

// Persisted user intent (docs/07 §3): which upstream, and whether DNS is pinned.
// Written on every switch/set_enabled; loaded at boot to auto-restore the last
// selection and (self-test permitting) re-pin. Unlike the DNS snapshot, state is
// NOT deleted on clean exit — it's durable intent, not an owed restore.

import (
	"encoding/json"
	"os"
)

// stateFile() lives in snapshot.go, alongside the dir var it derives from.

type persistedState struct {
	Version  int    `json:"version"`
	Provider string `json:"provider"`
	Protocol string `json:"protocol"`
	ID       string `json:"id"`
	Device   string `json:"device"`
	Enabled  bool   `json:"enabled"`
}

func saveState(s *persistedState) error { return atomicWriteJSON(stateFile(), s) }

// loadState returns (nil, nil) when no state file exists.
func loadState() (*persistedState, error) {
	data, err := os.ReadFile(stateFile())
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s persistedState
	if err = json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}
