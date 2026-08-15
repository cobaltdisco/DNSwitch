package main

// Provider preset table + validation (docs/06 §6, templates from docs/04 §2).
// Server-side is the real gate — the UI greying is only the first line.

import (
	"fmt"
	"net/url"
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

// nextdnsBootstrap resolves dns.nextdns.io / <id>.dns.nextdns.io to NextDNS's
// real DNS endpoints. It MUST be NextDNS's own anycast (space-separated list =
// ParallelResolver, second IP for resilience): a generic resolver (e.g. 1.1.1.1)
// now returns a Cloudflare-fronted steering IP that 403s wireformat DoH and
// serves the wrong cert on :853 — verified broken on ALL four protocols for both
// profiled and config-less NextDNS (docs/04). Used for every NextDNS selection.
const nextdnsBootstrap = "45.90.28.0 45.90.30.0"

// NextDNS device name raw input: letters, digits, space, hyphen. Encoded form
// replaces spaces with "--" (NextDNS's rule) and must stay a valid DNS label.
var deviceRawRe = regexp.MustCompile(`^[A-Za-z0-9 -]{1,40}$`)

// validateDevice checks a NextDNS device name and returns its trimmed raw form
// ("" = none). Chars are limited to [A-Za-z0-9 -] so the DoT hostname-label form
// stays valid across ALL protocols; the 50-char bound caps the device portion
// (real NextDNS ids are ~6 chars, so "<dev>-<id>" stays a valid DNS label).
// The per-protocol ENCODING differs (see resolve): DoT/DoQ use "--" for spaces
// in the hostname label; DoH/DoH3 URL-encode the name in the path (space -> %20,
// per NextDNS's DoH format).
func validateDevice(raw string) (string, *codedError) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if !deviceRawRe.MatchString(raw) {
		return "", newErr("invalid_device", "device name: letters, digits, space, hyphen only")
	}
	if len(strings.ReplaceAll(raw, " ", "--")) > 50 {
		return "", newErr("invalid_device", "device name too long")
	}
	return raw, nil
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
		// No id -> NextDNS's config-less public resolver (unfiltered; no logging or
		// device reporting). It MUST be bootstrapped via NextDNS's own anycast:
		// resolving dns.nextdns.io through a generic resolver returns a
		// Cloudflare-fronted steering IP that 403s wireformat DoH and serves the
		// wrong cert on :853; the anycast routes to NextDNS's real DNS endpoints.
		// Verified with dnslookup across all four protocols (docs/04). A device
		// name is meaningless without a profile, so it is ignored here.
		if s.ID == "" {
			return map[string]string{
				"dot":  "tls://dns.nextdns.io",
				"doh":  "https://dns.nextdns.io/dns-query",
				"doh3": "h3://dns.nextdns.io/dns-query",
				"doq":  "quic://dns.nextdns.io",
			}[s.Protocol], nextdnsBootstrap, nil
		}
		if !idRe.MatchString(s.ID) {
			return "", "", newErr("invalid_id", "id must match [A-Za-z0-9-]{1,64}")
		}
		dev, cerr := validateDevice(s.Device)
		if cerr != nil {
			return "", "", cerr
		}
		host, path := s.ID+".dns.nextdns.io", s.ID
		if dev != "" {
			// DoT/DoQ carry the device as a DNS-label prefix (spaces -> "--");
			// DoH/DoH3 carry it as a URL path segment (URL-encoded, space -> %20).
			// Both verified against NextDNS.
			host = strings.ReplaceAll(dev, " ", "--") + "-" + s.ID + ".dns.nextdns.io"
			path = s.ID + "/" + url.PathEscape(dev)
		}
		return map[string]string{
			"dot":  "tls://" + host,
			"doh":  "https://dns.nextdns.io/" + path,
			"doh3": "h3://dns.nextdns.io/" + path,
			"doq":  "quic://" + host,
		}[s.Protocol], nextdnsBootstrap, nil

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
