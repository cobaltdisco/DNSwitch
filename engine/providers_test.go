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
		{"google doh", selection{"google", "doh", ""}, "https://dns.google/dns-query", "8.8.8.8", ""},
		{"google dot", selection{"google", "dot", ""}, "tls://dns.google", "8.8.8.8", ""},
		{"google doh3", selection{"google", "doh3", ""}, "h3://dns.google/dns-query", "8.8.8.8", ""},
		{"google doq -> unsupported", selection{"google", "doq", ""}, "", "", "unsupported_protocol"},
		{"cloudflare dot uses 1.1.1.1", selection{"cloudflare", "dot", ""}, "tls://1.1.1.1", "1.1.1.1", ""},
		{"cloudflare doh", selection{"cloudflare", "doh", ""}, "https://cloudflare-dns.com/dns-query", "1.1.1.1", ""},
		{"cloudflare doq -> unsupported", selection{"cloudflare", "doq", ""}, "", "", "unsupported_protocol"},
		{"nextdns doq needs id", selection{"nextdns", "doq", ""}, "", "", "missing_id"},
		{"nextdns doq with id", selection{"nextdns", "doq", "abc123"}, "quic://abc123.dns.nextdns.io", "1.1.1.1", ""},
		{"nextdns doh with id", selection{"nextdns", "doh", "abc123"}, "https://dns.nextdns.io/abc123", "1.1.1.1", ""},
		{"nextdns bad id", selection{"nextdns", "doh", "a/b"}, "", "", "invalid_id"},
		{"nextdns id with dot rejected", selection{"nextdns", "doh", "a.b"}, "", "", "invalid_id"},
		{"alidns public doh (no id)", selection{"alidns", "doh", ""}, "https://dns.alidns.com/dns-query", "223.5.5.5", ""},
		{"alidns public doq (no id)", selection{"alidns", "doq", ""}, "quic://dns.alidns.com", "223.5.5.5", ""},
		{"alidns enterprise doh (id)", selection{"alidns", "doh", "acct1"}, "https://acct1.alidns.com/dns-query", "223.5.5.5", ""},
		{"alidns enterprise doq (id)", selection{"alidns", "doq", "acct1"}, "quic://acct1.alidns.com", "223.5.5.5", ""},
		{"alidns bad id", selection{"alidns", "doh", "a b"}, "", "", "invalid_id"},
		{"unknown provider", selection{"quad9", "doh", ""}, "", "", "unknown_provider"},
		{"bad protocol", selection{"google", "sdns", ""}, "", "", "unsupported_protocol"},
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
