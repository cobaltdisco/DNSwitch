package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/AdguardTeam/dnsproxy/proxy"
	"github.com/miekg/dns"
)

// The budgets in controller.go and coordinator.go only work in this order.
func TestTimeoutBudgets(t *testing.T) {
	if upstreamTimeout >= selfTestTimeout {
		t.Errorf("selfTestTimeout (%s) must exceed upstreamTimeout (%s): one stalled attempt would fail every self-test",
			selfTestTimeout, upstreamTimeout)
	}
	if selfTestTimeout >= switchTimeout {
		t.Errorf("selfTestTimeout (%s) must stay under switchTimeout (%s): a refused switch would reach the app as a timeout",
			selfTestTimeout, switchTimeout)
	}
	if pendingTestTimeout >= switchTimeout {
		t.Errorf("pendingTestTimeout (%s) must stay under switchTimeout (%s)", pendingTestTimeout, switchTimeout)
	}
}

// startLossyBootstrap is a plain-DNS server that answers every A query with
// 127.0.0.1 but never answers the first packet it receives, like a resolver
// reached over a path that just lost one UDP datagram.
func startLossyBootstrap(t *testing.T) (addr string, dropped *atomic.Int32) {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dropped = &atomic.Int32{}
	var seen atomic.Int32
	srv := &dns.Server{PacketConn: pc, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, req *dns.Msg) {
		if seen.Add(1) == 1 {
			dropped.Add(1)
			return
		}
		r := new(dns.Msg).SetReply(req)
		if req.Question[0].Qtype == dns.TypeA {
			r.Answer = append(r.Answer, &dns.A{
				Hdr: dns.RR_Header{Name: req.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
				A:   net.IPv4(127, 0, 0, 1),
			})
		}
		_ = w.WriteMsg(r)
	})}
	go func() { _ = srv.ActivateAndServe() }()
	t.Cleanup(func() { _ = srv.Shutdown() })
	return pc.LocalAddr().String(), dropped
}

// The reason selfTestTimeout is longer than upstreamTimeout. One lost bootstrap
// datagram makes dnsproxy wait out a full upstreamTimeout before it asks again.
// A DoH, DoH3 or DoQ upstream is only dialled after that, under the self-test's
// own context, so with a 5s self-test the dial never happened and a healthy
// upstream was refused as unreachable. With selfTestTimeout there is budget
// left to reach it.
//
// The upstream here is a bare TCP listener: buildConfig has no way to trust a
// test certificate, so the handshake cannot succeed, and it does not need to.
// What is pinned is that the self-test gets as far as connecting. It has to be
// DoH. A plain-DNS upstream is retried by dnsproxy on a fresh context, and DoT
// bootstraps once per query, so the query that lost no packet dials at once;
// either would pass at any timeout. DoH builds one client for both queries
// behind that single lookup, as DoH3 and DoQ do. This runs the real library
// down the path swapTo and startInitial take, and costs one upstreamTimeout,
// hence -short skips it.
func TestSelfTestReachesUpstreamAfterLostBootstrapPacket(t *testing.T) {
	if testing.Short() {
		t.Skip("waits out one upstream timeout; skipped under -short")
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	var dialled atomic.Int32
	go func() {
		for {
			c, aerr := ln.Accept()
			if aerr != nil {
				return
			}
			dialled.Add(1)
			_ = c.Close()
		}
	}()
	_, port, err := net.SplitHostPort(ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	boot, dropped := startLossyBootstrap(t)

	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	cfg, err := buildConfig(quiet, "https://upstream.test:"+port+"/dns-query", boot)
	if err != nil {
		t.Fatalf("buildConfig: %v", err)
	}
	prx, err := proxy.New(cfg)
	if err != nil {
		t.Fatalf("proxy.New: %v", err)
	}
	t.Cleanup(func() { _ = prx.Shutdown(context.Background()) })

	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), selfTestTimeout)
	_, _ = prx.LookupNetIP(ctx, "ip", selfTestName) // fails at the handshake, by design
	cancel()
	took := time.Since(start)

	if dropped.Load() != 1 {
		t.Fatalf("bootstrap dropped %d packets, want exactly 1", dropped.Load())
	}
	if took < upstreamTimeout {
		t.Fatalf("self-test took %s; the lost packet should have cost a full upstreamTimeout (%s)", took, upstreamTimeout)
	}
	if dialled.Load() == 0 {
		t.Fatalf("after one lost bootstrap packet the self-test never dialled the upstream (took %s of %s): "+
			"no budget was left, so a healthy upstream would be refused", took, selfTestTimeout)
	}
}
