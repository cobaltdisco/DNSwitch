package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// An app built against an older engine must not meet a key it does not know,
// and — more importantly — the reverse: this engine's reply has to stay
// decodable by the 0.14 app, which is what every user runs at the moment they
// install this version and before they relaunch the daemon. omitempty is what
// keeps the common case byte-identical to before.
func TestStateDTOOmitsRestoreOwedWhenFalse(t *testing.T) {
	b, err := json.Marshal(&stateDTO{Enabled: true, Provider: "cloudflare", Protocol: "doh"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(b), "restoreOwed") {
		t.Errorf("restoreOwed must be omitted when false, got %s", b)
	}

	b, err = json.Marshal(&stateDTO{RestoreOwed: true})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(b), `"restoreOwed":true`) {
		t.Errorf("restoreOwed must be present when true, got %s", b)
	}
}

// The persisted state is a separate format from the wire one and must not have
// grown a field: a 0.15 engine has to be able to hand its state file back to a
// 0.14 engine if the user rolls back.
func TestPersistedStateFormatUnchanged(t *testing.T) {
	b, err := json.Marshal(&persistedState{
		Version: 1, Provider: "nextdns", Protocol: "doh", ID: "abc", Device: "Mac", Enabled: true,
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	const want = `{"version":1,"provider":"nextdns","protocol":"doh","id":"abc","device":"Mac","enabled":true}`
	if string(b) != want {
		t.Errorf("on-disk state format changed\n got: %s\nwant: %s", b, want)
	}
}
