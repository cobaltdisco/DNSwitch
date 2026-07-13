package main

import "testing"

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

		{"nextdns doq needs id", selection{Provider: "nextdns", Protocol: "doq"}, "", "", "missing_id"},
		{"nextdns doq with id", selection{Provider: "nextdns", Protocol: "doq", ID: "abc123"}, "quic://abc123.dns.nextdns.io", "1.1.1.1", ""},
		{"nextdns doh with id", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123"}, "https://dns.nextdns.io/abc123", "1.1.1.1", ""},
		{"nextdns bad id", selection{Provider: "nextdns", Protocol: "doh", ID: "a/b"}, "", "", "invalid_id"},
		{"nextdns id with dot rejected", selection{Provider: "nextdns", Protocol: "doh", ID: "a.b"}, "", "", "invalid_id"},

		// device name (NextDNS only): DoT/DoQ prefix the hostname, DoH/DoH3 add a path segment.
		{"nextdns dot + device", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "laptop"}, "tls://laptop-abc123.dns.nextdns.io", "1.1.1.1", ""},
		{"nextdns doq + device", selection{Provider: "nextdns", Protocol: "doq", ID: "abc123", Device: "laptop"}, "quic://laptop-abc123.dns.nextdns.io", "1.1.1.1", ""},
		{"nextdns doh + device (path)", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123", Device: "laptop"}, "https://dns.nextdns.io/abc123/laptop", "1.1.1.1", ""},
		{"nextdns doh3 + device (path)", selection{Provider: "nextdns", Protocol: "doh3", ID: "abc123", Device: "laptop"}, "h3://dns.nextdns.io/abc123/laptop", "1.1.1.1", ""},
		{"nextdns device space -> --", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "My Mac"}, "tls://My--Mac-abc123.dns.nextdns.io", "1.1.1.1", ""},
		{"nextdns device trimmed empty = no device", selection{Provider: "nextdns", Protocol: "doh", ID: "abc123", Device: "  "}, "https://dns.nextdns.io/abc123", "1.1.1.1", ""},
		{"nextdns device bad char", selection{Provider: "nextdns", Protocol: "dot", ID: "abc123", Device: "a/b"}, "", "", "invalid_device"},

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
