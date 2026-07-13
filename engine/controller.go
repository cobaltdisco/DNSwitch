package main

// The DNS engine: embeds AdGuard dnsproxy as a library and owns its lifecycle.
// Switching a provider/protocol is a rebuild of the proxy with a new upstream
// (in-process, no external restart) — Phase 1 will drive Apply over the socket;
// Phase 0 calls it once with a hardcoded upstream.

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/AdguardTeam/dnsproxy/proxy"
	"github.com/AdguardTeam/dnsproxy/upstream"
	"github.com/miekg/dns"
)

const (
	listenIP   = "127.0.0.1"
	listenPort = 53
)

type controller struct {
	mu        sync.Mutex
	logger    *slog.Logger // engine's own messages
	dnsLogger *slog.Logger // dnsproxy library logs (kept quieter so our lines stand out)
	prx       *proxy.Proxy
	// curURL/curBootstrap is the last successfully-applied spec. We rebuild from
	// the spec (not the *Proxy) to revert a failed switch, because a Shutdown
	// proxy cannot be restarted — Shutdown closes its UpstreamConfig and nils its
	// listeners (verified in dnsproxy v0.83.0). (SF-1)
	curURL       string
	curBootstrap string
}

func newController(logger, dnsLogger *slog.Logger) *controller {
	return &controller{logger: logger, dnsLogger: dnsLogger}
}

// buildConfig assembles a proxy.Config for a single upstream.
//
// R-1 (bootstrap semantics): opts.Bootstrap is a resolver interface; nil would
// fall back to net.DefaultResolver = the SYSTEM resolver, which we've pointed at
// ourselves → a resolution death-loop (B7). We build it with NewUpstreamResolver
// ("resolve the upstream's hostname VIA this plain-DNS server"), NOT
// StaticResolver ("the hostname's address IS this IP"), because StaticResolver
// would break SNI/cert validation for hostnamed providers like NextDNS.
func buildConfig(logger *slog.Logger, upstreamURL, bootstrapAddr string) (*proxy.Config, error) {
	boot, err := upstream.NewUpstreamResolver(bootstrapAddr, &upstream.Options{
		Logger:  logger,
		Timeout: 5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("bootstrap resolver %q: %w", bootstrapAddr, err)
	}
	uc, err := proxy.ParseUpstreamsConfig([]string{upstreamURL}, &upstream.Options{
		Logger:    logger,
		Bootstrap: boot,
		Timeout:   5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("parse upstream %q: %w", upstreamURL, err)
	}
	return &proxy.Config{
		Logger:          logger,
		UDPListenAddr:   []*net.UDPAddr{{IP: net.ParseIP(listenIP), Port: listenPort}},
		TCPListenAddr:   []*net.TCPAddr{{IP: net.ParseIP(listenIP), Port: listenPort}},
		UpstreamConfig:  uc,
		CacheEnabled:    true,
		CacheOptimistic: true,
		CacheSizeBytes:  4 * 1024 * 1024, // R-7: set explicitly, not the zero value
	}, nil
}

// buildAndStart builds a fresh proxy for one upstream and starts it (binds
// :53). On a Start failure it closes the (possibly partially-bound) listener
// before returning, since dnsproxy requires manual cleanup in that case. (SF-2)
func buildAndStart(ctx context.Context, logger *slog.Logger, upstreamURL, bootstrapAddr string) (*proxy.Proxy, error) {
	cfg, err := buildConfig(logger, upstreamURL, bootstrapAddr)
	if err != nil {
		return nil, err
	}
	p, err := proxy.New(cfg)
	if err != nil {
		return nil, fmt.Errorf("proxy.New: %w", err)
	}
	if err := p.Start(ctx); err != nil {
		_ = p.Shutdown(ctx) // SF-2: release any listener bound before the failure
		return nil, fmt.Errorf("start (bind %s:%d): %w", listenIP, listenPort, err)
	}
	return p, nil
}

// Apply makes upstreamURL the live upstream.
//
// Two proxies cannot both bind 127.0.0.1:53, so we shut the old one down before
// starting the new. If the new one fails to start, we revert by REBUILDING the
// old from its cached spec (a Shutdown proxy can't be restarted — SF-1). In
// Phase 0 there is no old proxy, so this is just buildAndStart (= bind :53).
func (c *controller) Apply(ctx context.Context, upstreamURL, bootstrapAddr string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	old := c.prx
	oldURL, oldBootstrap := c.curURL, c.curBootstrap
	if old != nil {
		if err := old.Shutdown(ctx); err != nil {
			c.logger.Warn("shutdown old proxy failed", "err", err)
		}
		c.prx, c.curURL, c.curBootstrap = nil, "", ""
	}

	newPrx, err := buildAndStart(ctx, c.dnsLogger, upstreamURL, bootstrapAddr)
	if err != nil {
		if oldURL != "" { // revert by rebuilding the previous spec
			if revPrx, rerr := buildAndStart(ctx, c.dnsLogger, oldURL, oldBootstrap); rerr == nil {
				c.prx, c.curURL, c.curBootstrap = revPrx, oldURL, oldBootstrap
				c.logger.Warn("new upstream failed to start; reverted to previous", "err", err)
			} else {
				c.logger.Error("new failed AND revert failed; no listener", "err", err, "revert_err", rerr)
			}
		}
		return err
	}
	c.prx, c.curURL, c.curBootstrap = newPrx, upstreamURL, bootstrapAddr
	return nil
}

// SelfTest queries the live listener at 127.0.0.1:53 to prove end-to-end
// resolution BEFORE we touch system DNS (B-1 step 3).
func (c *controller) SelfTest(ctx context.Context, name string) error {
	msg := new(dns.Msg)
	msg.SetQuestion(dns.Fqdn(name), dns.TypeA)
	cl := &dns.Client{Timeout: 5 * time.Second}
	resp, _, err := cl.ExchangeContext(ctx, msg, net.JoinHostPort(listenIP, fmt.Sprint(listenPort)))
	if err != nil {
		return fmt.Errorf("self-test query: %w", err)
	}
	if resp.Rcode != dns.RcodeSuccess {
		return fmt.Errorf("self-test rcode: %s", dns.RcodeToString[resp.Rcode])
	}
	if len(resp.Answer) == 0 {
		return fmt.Errorf("self-test: no answer records")
	}
	return nil
}

func (c *controller) Shutdown(ctx context.Context) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.prx != nil {
		if err := c.prx.Shutdown(ctx); err != nil {
			c.logger.Warn("proxy shutdown failed", "err", err)
		}
		c.prx = nil
	}
}
