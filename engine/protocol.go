package main

// NDJSON control protocol (docs/06 §2). One JSON object per line, request →
// response, over the unix socket. Owner-only (uid-gated at accept time).

import "errors"

const protocolVersion = 1

type request struct {
	V        int    `json:"v"`
	Cmd      string `json:"cmd"`
	Provider string `json:"provider,omitempty"`
	Protocol string `json:"protocol,omitempty"`
	ID       string `json:"id,omitempty"`
	Device   string `json:"device,omitempty"`
	Enabled  *bool  `json:"enabled,omitempty"`
}

type stateDTO struct {
	Enabled   bool   `json:"enabled"`
	Provider  string `json:"provider"`
	Protocol  string `json:"protocol"`
	ID        string `json:"id,omitempty"`     // so the app can seed its config from a boot-restored profile
	Device    string `json:"device,omitempty"` // (owner-only socket; not committed anywhere)
	Upstream  string `json:"upstream"`
	Listening bool   `json:"listening"`
	// Pinned is a copy of `enabled`, i.e. our INTENT, not a reading of the
	// system. Do not redefine it as "physically pinned" — the app's toggle and
	// menu-bar icon are built on the intent meaning.
	Pinned bool `json:"pinned"`
	// RestoreOwed: a disable left the original DNS not fully put back. Derived
	// at read time from (!enabled && snapshotExists()), never stored. omitempty
	// so an older app decoding this sees nothing new.
	RestoreOwed bool `json:"restoreOwed,omitempty"`
	// Build versions, for the app's About view + future app/engine skew detection.
	EngineVersion   string `json:"engineVersion,omitempty"`   // this daemon's -ldflags version
	DnsproxyVersion string `json:"dnsproxyVersion,omitempty"` // embedded AdGuard dnsproxy module
}

type errDTO struct {
	Code string `json:"code"`
	Msg  string `json:"msg"`
}

type response struct {
	V     int       `json:"v"`
	OK    bool      `json:"ok"`
	State *stateDTO `json:"state,omitempty"`
	Error *errDTO   `json:"error,omitempty"`
}

func okResp(st *stateDTO) response { return response{V: protocolVersion, OK: true, State: st} }
func errResp(code, msg string) response {
	return response{V: protocolVersion, OK: false, Error: &errDTO{Code: code, Msg: msg}}
}

// codedError carries a machine-readable code plus a message that is safe to
// return to the (authenticated) client. Non-coded errors map to "internal" and
// their detail is logged server-side only, never returned.
type codedError struct {
	Code string
	Msg  string
}

func (e *codedError) Error() string       { return e.Code + ": " + e.Msg }
func newErr(code, msg string) *codedError { return &codedError{Code: code, Msg: msg} }

var errUpstreamUnreachable = &codedError{Code: "upstream_unreachable", Msg: "upstream self-test failed"}

// codeOf extracts a client-safe (code, msg) from err, defaulting to internal.
func codeOf(err error) (code, msg string) {
	var ce *codedError
	if errors.As(err, &ce) {
		return ce.Code, ce.Msg
	}
	return "internal", "internal error"
}
