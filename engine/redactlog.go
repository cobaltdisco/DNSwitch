package main

import (
	"context"
	"log/slog"
	"slices"
)

// redactHandler is the slog.Handler we give to the embedded dnsproxy library.
//
// WHY THIS EXISTS (H2, docs/03): launchd's StandardErrorPath log is a plain file
// on disk, and the library logs the FULL upstream URL — which for NextDNS embeds
// the user's profile id and device name — plus the queried domain name. Two call
// sites do it above LevelWarn, so a level threshold does not help:
//
//	proxy/exchange.go:88     "exchange failed"    upstream=<url> question=<name>
//	upstream/upstream.go:367 "response received"  addr=<url> status=<err>   (Error on timeout)
//
// The second one fires on ordinary laptop life — sleep, roaming, a captive
// portal — so it is the common case, not the rare one.
//
// ALLOWLIST, NOT DENYLIST. Naming the bad keys would silently spring a leak the
// day dnsproxy adds an attribute, and this is a security boundary: it must fail
// closed. So we drop every attribute except values that cannot carry a URL, a
// hostname, or an error string — numbers, booleans, durations — plus a tiny set
// of known-safe string keys that make the surviving lines worth reading.
//
// WHAT SURVIVES: the level, the timestamp, and the message. Enough to see THAT
// exchanges are failing and how often; never which upstream or which domain.
// This assumes dnsproxy's messages are constant strings, which they are on these
// paths (re-checked in v0.85.0 by diffing every log message literal in proxy/
// and upstream/ against the previous version — one constant added, none
// changed, and none built with Sprintf or concatenation) — a future version
// that formats a value into the message text would defeat the allowlist, so
// re-check on upgrade.
//
// NOT A SUBSTITUTE FOR FILE PERMISSIONS. A Go runtime panic, dyld, or launchd
// itself writes straight to fd 2 and no handler can intercept that. The plist's
// Umask key is what covers those (see main).
type redactHandler struct {
	inner slog.Handler
	// discardAll latches once WithGroup opens a named group: from that point
	// every attribute is namespaced under it and our flat key allowlist can no
	// longer reason about them, so we fail closed instead of guessing.
	discardAll bool
}

// safeStringKeys are the only string-valued attributes allowed through. Each is
// a fixed enum-like token in dnsproxy, never a URL, hostname, or error text.
var safeStringKeys = []string{"proto", "prefix", "qtype"}

func newRedactHandler(inner slog.Handler) *redactHandler {
	return &redactHandler{inner: inner}
}

// safeAttr reports whether a is safe to emit. The value must already be
// resolved: a slog.LogValuer can expand into anything, so callers resolve first
// and pass the result here.
func safeAttr(a slog.Attr) bool {
	switch a.Value.Kind() {
	case slog.KindBool, slog.KindInt64, slog.KindUint64, slog.KindFloat64, slog.KindDuration:
		// A number or a flag cannot carry the profile id.
		return true
	case slog.KindString:
		return slices.Contains(safeStringKeys, a.Key)
	default:
		// KindGroup (opaque nesting), KindAny (arbitrary Stringer), KindTime.
		return false
	}
}

func filterAttrs(attrs []slog.Attr) []slog.Attr {
	out := make([]slog.Attr, 0, len(attrs))
	for _, a := range attrs {
		a.Value = a.Value.Resolve()
		if safeAttr(a) {
			out = append(out, a)
		}
	}
	return slices.Clip(out)
}

// Enabled delegates. Returning a blanket true would make the library format
// records the sink would then drop, for nothing.
func (h *redactHandler) Enabled(ctx context.Context, l slog.Level) bool {
	return h.inner.Enabled(ctx, l)
}

// Handle rebuilds the record from scratch rather than mutating the one it was
// given: a slog.Record shares backing state with its caller, and Attrs is the
// only way to read it.
func (h *redactHandler) Handle(ctx context.Context, r slog.Record) error {
	out := slog.NewRecord(r.Time, r.Level, r.Message, r.PC)
	if !h.discardAll {
		r.Attrs(func(a slog.Attr) bool {
			a.Value = a.Value.Resolve()
			if safeAttr(a) {
				out.AddAttrs(a)
			}
			return true
		})
	}
	return h.inner.Handle(ctx, out)
}

// WithAttrs MUST filter, and MUST return a redactHandler.
//
// This is the trap that makes a naive wrapper useless. dnsproxy derives loggers
// with logger.With(...) — proxy/serverudp.go:146 pre-binds an address and then
// logs at Error on the next line. slog.Logger.With calls Handler.WithAttrs, and
// a wrapper that leaves this method to an embedded interface hands back the
// INNER handler: from then on that logger bypasses Handle entirely and every
// attribute, pre-bound and per-record alike, reaches the file. Verified by
// experiment before this was written.
func (h *redactHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	if h.discardAll {
		return h
	}
	kept := filterAttrs(attrs)
	if len(kept) == 0 {
		return h
	}
	return &redactHandler{inner: h.inner.WithAttrs(kept)}
}

// WithGroup with a non-empty name latches discardAll: inside a group the keys we
// allowlist are no longer the keys being written, so the safe move is to stop
// emitting attributes rather than to let unknown ones through. An empty name is
// a documented no-op (slog.Handler contract).
func (h *redactHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	return &redactHandler{inner: h.inner, discardAll: true}
}
