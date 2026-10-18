package main

import (
	"context"
	"net"
	"net/netip"
	"sync"
	"testing"
	"time"

	"github.com/AdguardTeam/dnsproxy/proxy"
	"github.com/AdguardTeam/dnsproxy/upstream"
	"github.com/miekg/dns"
)

func TestIsResolverARPA(t *testing.T) {
	for name, want := range map[string]bool{
		"_dns.resolver.arpa.":          true,
		"_dns.resolver.arpa":           true,
		"_DNS.Resolver.ARPA.":          true,
		"resolver.arpa.":               true,
		"_dns.1.1.1.1.resolver.arpa.":  true,
		"x.y.resolver.arpa":            true,
		"notresolver.arpa.":            false,
		"resolver.arpa.example.com.":   false,
		"arpa.":                        false,
		"1.0.0.127.in-addr.arpa.":      false,
		"example.com.":                 false,
		"_dns.resolver.arpa.attacker.": false,
	} {
		if got := isResolverARPA(name); got != want {
			t.Errorf("isResolverARPA(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestDDRNODATA(t *testing.T) {
	for _, edns := range []bool{false, true} {
		req := new(dns.Msg).SetQuestion("_dns.resolver.arpa.", dns.TypeSVCB)
		req.Id = 4242
		req.CheckingDisabled = true
		if edns {
			req.SetEdns0(1232, true)
		}
		r := ddrNODATA(req)
		if r.Id != 4242 || !r.Response || r.Rcode != dns.RcodeSuccess || !r.RecursionDesired || !r.RecursionAvailable || !r.CheckingDisabled {
			t.Fatalf("edns=%v header: %+v", edns, r.MsgHdr)
		}
		if len(r.Question) != 1 || r.Question[0] != req.Question[0] {
			t.Fatalf("edns=%v question not mirrored: %v", edns, r.Question)
		}
		if len(r.Answer) != 0 {
			t.Fatalf("edns=%v answer not empty: %v", edns, r.Answer)
		}
		soa, ok := func() (*dns.SOA, bool) {
			if len(r.Ns) != 1 {
				return nil, false
			}
			s, ok := r.Ns[0].(*dns.SOA)
			return s, ok
		}()
		if !ok || soa.Hdr.Name != "resolver.arpa." || soa.Hdr.Ttl != ddrNegativeTTL || soa.Minttl != ddrNegativeTTL {
			t.Fatalf("edns=%v authority: %v", edns, r.Ns)
		}
		o := r.IsEdns0()
		if edns && (o == nil || o.UDPSize() != 1232 || !o.Do()) {
			t.Fatalf("OPT not echoed: %v", o)
		}
		if !edns && o != nil {
			t.Fatalf("OPT added to a query without one")
		}
		if _, err := r.Pack(); err != nil {
			t.Fatalf("edns=%v pack: %v", edns, err)
		}
	}
}

// fakeUpstream is a plain-DNS server on a random loopback port that answers
// every A query with 192.0.2.1 and records each name it was asked.
type fakeUpstream struct {
	mu    sync.Mutex
	names []string
	addr  string
}

func startFakeUpstream(t *testing.T) *fakeUpstream {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeUpstream{addr: pc.LocalAddr().String()}
	srv := &dns.Server{PacketConn: pc, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, req *dns.Msg) {
		f.mu.Lock()
		f.names = append(f.names, req.Question[0].Name)
		f.mu.Unlock()
		r := new(dns.Msg).SetReply(req)
		if req.Question[0].Qtype == dns.TypeA {
			r.Answer = append(r.Answer, &dns.A{
				Hdr: dns.RR_Header{Name: req.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
				A:   net.IPv4(192, 0, 2, 1),
			})
		}
		_ = w.WriteMsg(r)
	})}
	go func() { _ = srv.ActivateAndServe() }()
	t.Cleanup(func() { _ = srv.Shutdown() })
	return f
}

func (f *fakeUpstream) asked() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.names...)
}

// The handler as the proxy runs it: resolver.arpa is answered locally and
// never reaches the upstream; every other query still does, unchanged.
func TestHandleDDRThroughProxy(t *testing.T) {
	up := startFakeUpstream(t)
	uc, err := proxy.ParseUpstreamsConfig([]string{up.addr}, &upstream.Options{Timeout: 2 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	p, err := proxy.New(&proxy.Config{UpstreamConfig: uc})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	serve := func(name string, qtype uint16) *dns.Msg {
		t.Helper()
		req := new(dns.Msg).SetQuestion(name, qtype)
		req.SetEdns0(1232, false)
		d := &proxy.DNSContext{Req: req, Addr: netip.MustParseAddrPort("127.0.0.1:5353"), Proto: proxy.ProtoUDP}
		if err := handleDDR(ctx, p, d); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if d.Res == nil {
			t.Fatalf("%s: no response", name)
		}
		return d.Res
	}

	for _, qt := range []uint16{dns.TypeSVCB, dns.TypeHTTPS, dns.TypeA, dns.TypeAAAA, dns.TypeTXT} {
		r := serve("_DNS.resolver.arpa.", qt)
		if r.Rcode != dns.RcodeSuccess || len(r.Answer) != 0 || len(r.Ns) != 1 {
			t.Fatalf("qtype %d: %v", qt, r)
		}
	}
	serve("_dns.1.1.1.1.resolver.arpa.", dns.TypeSVCB)

	r := serve("example.com.", dns.TypeA)
	if len(r.Answer) != 1 {
		t.Fatalf("passthrough answer: %v", r.Answer)
	}
	asked := up.asked()
	if len(asked) != 1 || asked[0] != "example.com." {
		t.Fatalf("upstream was asked %v, want only example.com.", asked)
	}
}

// The live config installs the handler (buildConfig is what swapTo uses).
func TestBuildConfigInstallsDDRHandler(t *testing.T) {
	cfg, err := buildConfig(nil, "tls://1.1.1.1", "1.1.1.1")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.RequestHandler == nil {
		t.Fatal("RequestHandler not set: resolver.arpa would be forwarded upstream")
	}
}
