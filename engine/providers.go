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
	// Device is the NextDNS / Control D device name (optional), kept raw;
	// shown per device in the provider's own dashboard.
	Device string
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

// controldBootstrap resolves freedns.controld.com / <rid>.dns.controld.com via
// Control D's own public plain-DNS resolvers (two different /24s =
// ParallelResolver). Resolver-style only, never a static IP map: Control D picks
// the free or paid service by DESTINATION IP, so pinning addresses could route a
// bad Resolver ID to the free frontend and make it "pass" (docs/10 §3.1).
const controldBootstrap = "76.76.2.0 76.76.10.0"

// controldIDRe is the Control D Resolver ID grammar (docs/10 §3.2, checked
// against a real account): alphanumeric, no hyphen (the hyphen separates the
// ID from the device name in DoT/DoQ hostnames), at most one DNS label long.
// Case is kept, never folded. Real IDs are lowercase and Control D matches
// them case-sensitively (an uppercased ID is REFUSED on all four protocols,
// SNI included), but uppercase is still accepted here on purpose, like
// NextDNS's grammar: being too strict would lock out a valid ID for good,
// while a wrongly-cased one just fails the switch self-test and the previous
// provider stays in place.
var controldIDRe = regexp.MustCompile(`^[A-Za-z0-9]{1,63}$`)

// controldDeviceRawRe limits the raw Control D device name to ASCII letters,
// digits, space and hyphen. Tabs/newlines are rejected here, before trimming.
var controldDeviceRawRe = regexp.MustCompile(`^[A-Za-z0-9 -]*$`)

// normalizeControlDDevice turns a raw device name into Control D's client
// label (docs/10 §3.3): trim ASCII spaces, collapse each run of spaces into one
// "-", keep case and any inner "--". "" = no device (not an error). A leading or
// trailing "-" is rejected. The raw name stays untouched in the selection; only
// the URL uses this form.
func normalizeControlDDevice(raw string) (string, *codedError) {
	if !controldDeviceRawRe.MatchString(raw) {
		return "", newErr("invalid_device", "device name: letters, digits, space, hyphen only")
	}
	trimmed := strings.Trim(raw, " ")
	if trimmed == "" {
		return "", nil
	}
	var b strings.Builder
	inSpace := false
	for i := 0; i < len(trimmed); i++ {
		c := trimmed[i]
		if c == ' ' {
			if !inSpace {
				b.WriteByte('-')
			}
			inSpace = true
			continue
		}
		inSpace = false
		b.WriteByte(c)
	}
	client := b.String()
	if strings.HasPrefix(client, "-") || strings.HasSuffix(client, "-") {
		return "", newErr("invalid_device", "device name must not start or end with a hyphen")
	}
	return client, nil
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
		// On DoT/DoQ a leading hyphen starts the hostname label, and Go's
		// certificate check then refuses NextDNS's *.dns.nextdns.io (verified
		// live). Reject it as a device error so the switch doesn't fail as an
		// unreachable upstream pointing at the Profile ID. DoH/DoH3 carry the
		// name in the path, where NextDNS accepts it, and a trailing hyphen
		// works on every protocol, so neither is rejected: a saved selection
		// that worked must keep passing bootRestore after an update.
		if strings.HasPrefix(dev, "-") && (s.Protocol == "dot" || s.Protocol == "doq") {
			return "", "", newErr("invalid_device", "device name must not start with a hyphen on DoT/DoQ")
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

	case "controld":
		// No Resolver ID -> Control D's free unfiltered resolver (p0); a device
		// name means nothing there, so it is ignored even if invalid.
		if s.ID == "" {
			return map[string]string{
				"dot":  "tls://p0.freedns.controld.com",
				"doh":  "https://freedns.controld.com/p0",
				"doh3": "h3://freedns.controld.com/p0",
				"doq":  "quic://p0.freedns.controld.com",
			}[s.Protocol], controldBootstrap, nil
		}
		if !controldIDRe.MatchString(s.ID) {
			return "", "", newErr("invalid_id", "Resolver ID must be letters and digits, at most 63")
		}
		client, cerr := normalizeControlDDevice(s.Device)
		if cerr != nil {
			return "", "", cerr
		}
		// ID first, the reverse of NextDNS: DoT/DoQ "<rid>-<client>" as one
		// hostname label, DoH/DoH3 "/<rid>/<client>" as path segments.
		host, path := s.ID, s.ID
		if client != "" {
			host = s.ID + "-" + client
			path = s.ID + "/" + url.PathEscape(client) // identity for a normalized name; defensive
		}
		if (s.Protocol == "dot" || s.Protocol == "doq") && len(host) > 63 {
			return "", "", newErr("invalid_device", "Resolver ID plus device name too long")
		}
		return map[string]string{
			"dot":  "tls://" + host + ".dns.controld.com",
			"doh":  "https://dns.controld.com/" + path,
			"doh3": "h3://dns.controld.com/" + path,
			"doq":  "quic://" + host + ".dns.controld.com",
		}[s.Protocol], controldBootstrap, nil

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
