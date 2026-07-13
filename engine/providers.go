package main

// Provider preset table + validation (docs/06 §6, templates from docs/04 §2).
// Server-side is the real gate — the UI greying is only the first line.

import (
	"fmt"
	"regexp"
	"strings"
)

type selection struct {
	Provider string
	Protocol string
	ID       string
	Device   string // NextDNS device name (optional); reported per-device in logs
}

// id / account subdomain: alphanumeric + hyphen, bounded. Guards against
// smuggling a second host/scheme into ParseUpstreamsConfig. (SF-a)
var idRe = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

// NextDNS device name raw input: letters, digits, space, hyphen. Encoded form
// replaces spaces with "--" (NextDNS's rule) and must stay a valid DNS label.
var deviceRawRe = regexp.MustCompile(`^[A-Za-z0-9 -]{1,40}$`)

// encodeDevice turns a NextDNS device name into its hostname-safe form: spaces
// become "--". Empty input means "no device". The bound keeps "<dev>-<id>" a
// valid DNS label (<=63).
func encodeDevice(raw string) (string, *codedError) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if !deviceRawRe.MatchString(raw) {
		return "", newErr("invalid_device", "device name: letters, digits, space, hyphen only")
	}
	enc := strings.ReplaceAll(raw, " ", "--")
	if len(enc) > 50 {
		return "", newErr("invalid_device", "device name too long")
	}
	return enc, nil
}

func isProtocol(p string) bool {
	switch p {
	case "dot", "doh", "doh3", "doq":
		return true
	}
	return false
}

// resolve validates the selection and returns the upstream URL and the
// server-derived bootstrap IP (never client-supplied, SF-f). DoQ is only
// available where a template exists — Google/Cloudflare have none.
func (s selection) resolve() (upstreamURL, bootstrap string, cerr *codedError) {
	if !isProtocol(s.Protocol) {
		return "", "", newErr("unsupported_protocol", fmt.Sprintf("unknown protocol %q", s.Protocol))
	}
	unsupported := newErr("unsupported_protocol",
		fmt.Sprintf("%s not available for %s", s.Protocol, s.Provider))

	switch s.Provider {
	case "google":
		if s.Protocol == "doq" {
			return "", "", unsupported
		}
		return map[string]string{
			"dot":  "tls://dns.google",
			"doh":  "https://dns.google/dns-query",
			"doh3": "h3://dns.google/dns-query",
		}[s.Protocol], "8.8.8.8", nil

	case "cloudflare":
		if s.Protocol == "doq" {
			return "", "", unsupported
		}
		// DoT/DoQ must use 1.1.1.1, not cloudflare-dns.com (docs/04, C3).
		return map[string]string{
			"dot":  "tls://1.1.1.1",
			"doh":  "https://cloudflare-dns.com/dns-query",
			"doh3": "h3://cloudflare-dns.com/dns-query",
		}[s.Protocol], "1.1.1.1", nil

	case "nextdns":
		if cerr := requireID(s.ID); cerr != nil {
			return "", "", cerr
		}
		dev, cerr := encodeDevice(s.Device)
		if cerr != nil {
			return "", "", cerr
		}
		host, path := s.ID+".dns.nextdns.io", s.ID
		if dev != "" {
			// DoT/DoQ carry the device as a hostname prefix; DoH/DoH3 as a path
			// segment (both empirically verified against NextDNS).
			host = dev + "-" + s.ID + ".dns.nextdns.io"
			path = s.ID + "/" + dev
		}
		return map[string]string{
			"dot":  "tls://" + host,
			"doh":  "https://dns.nextdns.io/" + path,
			"doh3": "h3://dns.nextdns.io/" + path,
			"doq":  "quic://" + host,
		}[s.Protocol], "1.1.1.1", nil

	case "alidns":
		// id present → enterprise subdomain; absent → public resolver. (SF-b)
		if s.ID == "" {
			return map[string]string{
				"dot":  "tls://dns.alidns.com",
				"doh":  "https://dns.alidns.com/dns-query",
				"doh3": "h3://dns.alidns.com/dns-query",
				"doq":  "quic://dns.alidns.com",
			}[s.Protocol], "223.5.5.5", nil
		}
		if !idRe.MatchString(s.ID) {
			return "", "", newErr("invalid_id", "id must match [A-Za-z0-9-]{1,64}")
		}
		return map[string]string{
			"dot":  "tls://" + s.ID + ".alidns.com",
			"doh":  "https://" + s.ID + ".alidns.com/dns-query",
			"doh3": "h3://" + s.ID + ".alidns.com/dns-query",
			"doq":  "quic://" + s.ID + ".alidns.com",
		}[s.Protocol], "223.5.5.5", nil

	default:
		return "", "", newErr("unknown_provider", fmt.Sprintf("unknown provider %q", s.Provider))
	}
}

func requireID(id string) *codedError {
	if id == "" {
		return newErr("missing_id", "this provider requires an id")
	}
	if !idRe.MatchString(id) {
		return newErr("invalid_id", "id must match [A-Za-z0-9-]{1,64}")
	}
	return nil
}
