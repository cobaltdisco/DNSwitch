package main

import (
	"strings"
	"testing"
)

func TestResolve(t *testing.T) {
	cases := []struct {
		name     string
		sel      selection
		wantURL  string
		wantBoot string
		wantErr  string // error code, "" = success
	}{
		{"google doh", selection{Provider: "google", Protocol: "doh"}, "https://dns.google/dns-query", "8.8.8.8", ""},
		{"google dot", selection{Provider: "google", Protocol: "dot"}, "tls://dns.google", "8.8.8.8", ""},
		{"google doh3", selection{Provider: "google", Protocol: "doh3"}, "h3://dns.google/dns-query", "8.8.8.8", ""},
		{"google doq -> unsupported", selection{Provider: "google", Protocol: "doq"}, "", "", "unsupported_protocol"},
		{"cloudflare dot uses 1.1.1.1", selection{Provider: "cloudflare", Protocol: "dot"}, "tls://1.1.1.1", "1.1.1.1", ""},
		{"cloudflare doh", selection{Provider: "cloudflare", Protocol: "doh"}, "https://cloudflare-dns.com/dns-query", "1.1.1.1", ""},
		{"cloudflare doq -> unsupported", selection{Provider: "cloudflare", Protocol: "doq"}, "", "", "unsupported_protocol"},

		// No id -> config-less NextDNS public resolver, bootstrapped via NextDNS's
		// own anycast (45.90.28.0 + 45.90.30.0). Verified across all four protocols (docs/04).
		{"nextdns dot no id", selection{Provider: "nextdns", Protocol: "dot"}, "tls://dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doh no id", selection{Provider: "nextdns", Protocol: "doh"}, "https://dns.nextdns.io/dns-query", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doh3 no id", selection{Provider: "nextdns", Protocol: "doh3"}, "h3://dns.nextdns.io/dns-query", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doq no id", selection{Provider: "nextdns", Protocol: "doq"}, "quic://dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns no id ignores device", selection{Provider: "nextdns", Protocol: "doh", Device: "laptop"}, "https://dns.nextdns.io/dns-query", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doq with id", selection{Provider: "nextdns", Protocol: "doq", ID: "abc123"}, "quic://abc123.dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doh with id", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123"}, "https://dns.nextdns.io/abc123", "45.90.28.0 45.90.30.0", ""},
		{"nextdns bad id", selection{Provider: "nextdns", Protocol: "doh", ID: "a/b"}, "", "", "invalid_id"},
		{"nextdns id with dot rejected", selection{Provider: "nextdns", Protocol: "doh", ID: "a.b"}, "", "", "invalid_id"},

		// device name (NextDNS only): DoT/DoQ prefix the hostname, DoH/DoH3 add a path segment.
		{"nextdns dot + device", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "laptop"}, "tls://laptop-abc123.dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doq + device", selection{Provider: "nextdns", Protocol: "doq", ID: "abc123", Device: "laptop"}, "quic://laptop-abc123.dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doh + device (path)", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123", Device: "laptop"}, "https://dns.nextdns.io/abc123/laptop", "45.90.28.0 45.90.30.0", ""},
		{"nextdns doh3 + device (path)", selection{Provider: "nextdns", Protocol: "doh3", ID: "abc123", Device: "laptop"}, "h3://dns.nextdns.io/abc123/laptop", "45.90.28.0 45.90.30.0", ""},
		{"nextdns DoT device space -> --", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "My Mac"}, "tls://My--Mac-abc123.dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns DoQ device space -> --", selection{Provider: "nextdns", Protocol: "doq", ID: "abc123", Device: "My Mac"}, "quic://My--Mac-abc123.dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns DoH device space -> %20", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123", Device: "Mac Studio 2025"}, "https://dns.nextdns.io/abc123/Mac%20Studio%202025", "45.90.28.0 45.90.30.0", ""},
		{"nextdns DoH3 device space -> %20", selection{Provider: "nextdns", Protocol: "doh3", ID: "abc123", Device: "My Mac"}, "h3://dns.nextdns.io/abc123/My%20Mac", "45.90.28.0 45.90.30.0", ""},
		{"nextdns device trimmed empty = no device", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123", Device: "  "}, "https://dns.nextdns.io/abc123", "45.90.28.0 45.90.30.0", ""},
		{"nextdns device bad char", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "a/b"}, "", "", "invalid_device"},
		// A leading hyphen breaks only the DoT/DoQ hostname label; DoH/DoH3 keep
		// working, and a trailing hyphen is fine everywhere (all verified live).
		{"nextdns device leading hyphen (dot)", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "-mac"}, "", "", "invalid_device"},
		{"nextdns device leading hyphen (doq)", selection{Provider: "nextdns", Protocol: "doq", ID: "abc123", Device: "-mac"}, "", "", "invalid_device"},
		{"nextdns device hyphen after trim (dot)", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: " -mac "}, "", "", "invalid_device"},
		{"nextdns device lone hyphen (doq)", selection{Provider: "nextdns", Protocol: "doq", ID: "abc123", Device: "-"}, "", "", "invalid_device"},
		{"nextdns device leading hyphen ok (doh)", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123", Device: "-mac"}, "https://dns.nextdns.io/abc123/-mac", "45.90.28.0 45.90.30.0", ""},
		{"nextdns device leading hyphen ok (doh3)", selection{Provider: "nextdns", Protocol: "doh3", ID: "abc123", Device: "-mac"}, "h3://dns.nextdns.io/abc123/-mac", "45.90.28.0 45.90.30.0", ""},
		{"nextdns device trailing hyphen ok (dot)", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "mac-"}, "tls://mac--abc123.dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},
		{"nextdns device inner hyphen ok", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "my-mac"}, "tls://my-mac-abc123.dns.nextdns.io", "45.90.28.0 45.90.30.0", ""},

		{"alidns public doh (no id)", selection{Provider: "alidns", Protocol: "doh"}, "https://dns.alidns.com/dns-query", "223.5.5.5", ""},
		{"alidns public doq (no id)", selection{Provider: "alidns", Protocol: "doq"}, "quic://dns.alidns.com", "223.5.5.5", ""},
		{"alidns enterprise doh (id)", selection{Provider: "alidns", Protocol: "doh", ID: "acct1"}, "https://acct1.alidns.com/dns-query", "223.5.5.5", ""},
		{"alidns enterprise doq (id)", selection{Provider: "alidns", Protocol: "doq", ID: "acct1"}, "quic://acct1.alidns.com", "223.5.5.5", ""},
		{"alidns bad id", selection{Provider: "alidns", Protocol: "doh", ID: "a b"}, "", "", "invalid_id"},

		{"unknown provider", selection{Provider: "quad9", Protocol: "doh"}, "", "", "unknown_provider"},
		{"bad protocol", selection{Provider: "google", Protocol: "sdns"}, "", "", "unsupported_protocol"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			url, boot, cerr := tc.sel.resolve()
			if tc.wantErr != "" {
				if cerr == nil {
					t.Fatalf("want error %q, got url=%q", tc.wantErr, url)
				}
				if cerr.Code != tc.wantErr {
					t.Fatalf("want error code %q, got %q (%s)", tc.wantErr, cerr.Code, cerr.Msg)
				}
				return
			}
			if cerr != nil {
				t.Fatalf("unexpected error %s: %s", cerr.Code, cerr.Msg)
			}
			if url != tc.wantURL {
				t.Errorf("url = %q, want %q", url, tc.wantURL)
			}
			if boot != tc.wantBoot {
				t.Errorf("bootstrap = %q, want %q", boot, tc.wantBoot)
			}
		})
	}
}

// Control D (docs/10 §2-§3). Resolver ID first: DoT/DoQ "<rid>-<client>", DoH/DoH3
// "/<rid>/<client>" -- the reverse of NextDNS's "<dev>-<id>".
func TestResolveControlD(t *testing.T) {
	const boot = "76.76.2.0 76.76.10.0"
	rid63 := strings.Repeat("a", 63)
	rid64 := strings.Repeat("a", 64)
	// "abcd1234" (8) + "-" + 54 = 63 bytes; 55 = 64 bytes.
	dev54 := strings.Repeat("d", 54)
	dev55 := strings.Repeat("d", 55)

	cases := []struct {
		name    string
		sel     selection
		wantURL string
		wantErr string // error code, "" = success
	}{
		// Free: empty ID -> unfiltered p0; the device name is ignored, even if invalid.
		{"free dot", selection{Provider: "controld", Protocol: "dot"}, "tls://p0.freedns.controld.com", ""},
		{"free doh", selection{Provider: "controld", Protocol: "doh"}, "https://freedns.controld.com/p0", ""},
		{"free doh3", selection{Provider: "controld", Protocol: "doh3"}, "h3://freedns.controld.com/p0", ""},
		{"free doq", selection{Provider: "controld", Protocol: "doq"}, "quic://p0.freedns.controld.com", ""},
		{"free ignores device", selection{Provider: "controld", Protocol: "dot", Device: "My Mac"}, "tls://p0.freedns.controld.com", ""},
		{"free ignores invalid device", selection{Provider: "controld", Protocol: "doh", Device: "bad/name\té"}, "https://freedns.controld.com/p0", ""},

		// Paid: Resolver ID, no device.
		{"paid dot", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234"}, "tls://abcd1234.dns.controld.com", ""},
		{"paid doh", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234"}, "https://dns.controld.com/abcd1234", ""},
		{"paid doh3", selection{Provider: "controld", Protocol: "doh3", ID: "abcd1234"}, "h3://dns.controld.com/abcd1234", ""},
		{"paid doq", selection{Provider: "controld", Protocol: "doq", ID: "abcd1234"}, "quic://abcd1234.dns.controld.com", ""},

		// Paid + device "My Mac" -> "My-Mac", ID first.
		{"paid dot + device", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "My Mac"}, "tls://abcd1234-My-Mac.dns.controld.com", ""},
		{"paid doh + device", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "My Mac"}, "https://dns.controld.com/abcd1234/My-Mac", ""},
		{"paid doh3 + device", selection{Provider: "controld", Protocol: "doh3", ID: "abcd1234", Device: "My Mac"}, "h3://dns.controld.com/abcd1234/My-Mac", ""},
		{"paid doq + device", selection{Provider: "controld", Protocol: "doq", ID: "abcd1234", Device: "My Mac"}, "quic://abcd1234-My-Mac.dns.controld.com", ""},

		// Device normalization.
		{"device runs of spaces -> one hyphen", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "My   Mac  Pro"}, "tls://abcd1234-My-Mac-Pro.dns.controld.com", ""},
		{"device leading/trailing spaces trimmed", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "  My Mac  "}, "https://dns.controld.com/abcd1234/My-Mac", ""},
		{"device all spaces = no device (dot)", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "   "}, "tls://abcd1234.dns.controld.com", ""},
		{"device all spaces = no device (doh)", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "   "}, "https://dns.controld.com/abcd1234", ""},
		{"device single char", selection{Provider: "controld", Protocol: "doq", ID: "abcd1234", Device: "x"}, "quic://abcd1234-x.dns.controld.com", ""},
		{"device inner -- kept", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "a--b"}, "tls://abcd1234-a--b.dns.controld.com", ""},
		{"device space around hyphen", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "a - b"}, "https://dns.controld.com/abcd1234/a---b", ""},
		{"device case kept", selection{Provider: "controld", Protocol: "doh3", ID: "abcd1234", Device: "MacBook"}, "h3://dns.controld.com/abcd1234/MacBook", ""},
		{"device leading hyphen rejected", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "-mac"}, "", "invalid_device"},
		{"device trailing hyphen rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "mac-"}, "", "invalid_device"},
		{"device hyphen after trim rejected", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: " -mac "}, "", "invalid_device"},
		{"device lone hyphen rejected", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "-"}, "", "invalid_device"},
		{"device tab rejected", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "My\tMac"}, "", "invalid_device"},
		{"device newline rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "My\nMac"}, "", "invalid_device"},
		{"device trailing newline rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "Mac\n"}, "", "invalid_device"},
		{"device non-ASCII rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "Café"}, "", "invalid_device"},
		{"device slash rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: "a/b"}, "", "invalid_device"},
		{"device dot rejected", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "a.b"}, "", "invalid_device"},

		// Length: ID alone is one DNS label (<= 63); ID + "-" + device <= 63 on DoT/DoQ.
		{"id 63 ok (dot)", selection{Provider: "controld", Protocol: "dot", ID: rid63}, "tls://" + rid63 + ".dns.controld.com", ""},
		{"id 63 ok (doh)", selection{Provider: "controld", Protocol: "doh", ID: rid63}, "https://dns.controld.com/" + rid63, ""},
		{"id 64 rejected (dot)", selection{Provider: "controld", Protocol: "dot", ID: rid64}, "", "invalid_id"},
		{"id 64 rejected (doh)", selection{Provider: "controld", Protocol: "doh", ID: rid64}, "", "invalid_id"},
		{"id+device 63 ok (dot)", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: dev54}, "tls://abcd1234-" + dev54 + ".dns.controld.com", ""},
		{"id+device 63 ok (doq)", selection{Provider: "controld", Protocol: "doq", ID: "abcd1234", Device: dev54}, "quic://abcd1234-" + dev54 + ".dns.controld.com", ""},
		{"id+device 64 rejected (dot)", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: dev55}, "", "invalid_device"},
		{"id+device 64 rejected (doq)", selection{Provider: "controld", Protocol: "doq", ID: "abcd1234", Device: dev55}, "", "invalid_device"},
		{"id+device 64 ok on doh (label limit is DoT/DoQ only)", selection{Provider: "controld", Protocol: "doh", ID: "abcd1234", Device: dev55}, "https://dns.controld.com/abcd1234/" + dev55, ""},
		{"id+device 64 ok on doh3 (label limit is DoT/DoQ only)", selection{Provider: "controld", Protocol: "doh3", ID: "abcd1234", Device: dev55}, "h3://dns.controld.com/abcd1234/" + dev55, ""},
		{"id 63 plus any device rejected (dot)", selection{Provider: "controld", Protocol: "dot", ID: rid63, Device: "x"}, "", "invalid_device"},
		{"id+device length counted after normalization", selection{Provider: "controld", Protocol: "dot", ID: "abcd1234", Device: "  " + dev54 + "  "}, "tls://abcd1234-" + dev54 + ".dns.controld.com", ""},

		// ID grammar: alphanumeric only, case kept (not folded), uppercase accepted.
		{"id hyphen rejected", selection{Provider: "controld", Protocol: "dot", ID: "abcd-1234"}, "", "invalid_id"},
		{"id space rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd 1234"}, "", "invalid_id"},
		{"id dot rejected", selection{Provider: "controld", Protocol: "dot", ID: "abcd.1234"}, "", "invalid_id"},
		{"id slash rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd/1234"}, "", "invalid_id"},
		{"id non-ASCII rejected", selection{Provider: "controld", Protocol: "doh", ID: "abcd123é"}, "", "invalid_id"},
		{"id surrounding space rejected", selection{Provider: "controld", Protocol: "doh", ID: " abcd1234"}, "", "invalid_id"},
		{"id case kept (dot)", selection{Provider: "controld", Protocol: "dot", ID: "AbCd1234"}, "tls://AbCd1234.dns.controld.com", ""},
		{"id case kept (doh)", selection{Provider: "controld", Protocol: "doh", ID: "AbCd1234"}, "https://dns.controld.com/AbCd1234", ""},

		{"bad protocol", selection{Provider: "controld", Protocol: "sdns"}, "", "unsupported_protocol"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			url, gotBoot, cerr := tc.sel.resolve()
			if tc.wantErr != "" {
				if cerr == nil {
					t.Fatalf("want error %q, got url=%q", tc.wantErr, url)
				}
				if cerr.Code != tc.wantErr {
					t.Fatalf("want error code %q, got %q (%s)", tc.wantErr, cerr.Code, cerr.Msg)
				}
				// H2: the message goes back to the app and may be shown; it must
				// never echo the Resolver ID or the device name.
				if id := strings.TrimSpace(tc.sel.ID); id != "" && strings.Contains(cerr.Msg, id) {
					t.Errorf("error message echoes the Resolver ID: %q", cerr.Msg)
				}
				if dev := strings.TrimSpace(tc.sel.Device); len(dev) > 1 && strings.Contains(cerr.Msg, dev) {
					t.Errorf("error message echoes the device name: %q", cerr.Msg)
				}
				return
			}
			if cerr != nil {
				t.Fatalf("unexpected error %s: %s", cerr.Code, cerr.Msg)
			}
			if url != tc.wantURL {
				t.Errorf("url = %q, want %q", url, tc.wantURL)
			}
			if gotBoot != boot {
				t.Errorf("bootstrap = %q, want %q", gotBoot, boot)
			}
		})
	}
}

// Control D's order is "<rid>-<client>", never NextDNS's "<dev>-<id>".
func TestControlDOrderIsIDFirst(t *testing.T) {
	for _, proto := range []string{"dot", "doq"} {
		url, _, cerr := selection{Provider: "controld", Protocol: proto, ID: "abcd1234", Device: "laptop"}.resolve()
		if cerr != nil {
			t.Fatalf("%s: %s", proto, cerr.Msg)
		}
		if strings.Contains(url, "laptop-abcd1234") || !strings.Contains(url, "abcd1234-laptop.") {
			t.Errorf("%s: want ID-first host, got %q", proto, url)
		}
	}
}
