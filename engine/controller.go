package main

// The DNS engine: embeds AdGuard dnsproxy and owns the live proxy instance. It
// does NO locking of its own — the coordinator serializes every call.
//
// Switching is Option B (docs/06 §4): build the new proxy, self-test its
// upstream in-process via LookupNetIP (works before Start — cache/sema are
// initialized in New, and it never touches listener state), then Start it so it
// co-binds :53 alongside the old (SO_REUSEPORT), then Shutdown the old. There is
// no no-listener gap, and revert is "do nothing": the old proxy is never torn
// down until the new one is proven (this retires the SF-1 rebuild-revert).

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strings"
	"time"

	"github.com/AdguardTeam/dnsproxy/proxy"
	"github.com/AdguardTeam/dnsproxy/upstream"
)

const (
	listenIP   = "127.0.0.1"
	listenPort = 53
)

type controller struct {
	logger    *slog.Logger // engine's own messages
	dnsLogger *slog.Logger // dnsproxy library logs (quieter)
	prx       *proxy.Proxy
}

func newController(logger, dnsLogger *slog.Logger) *controller {
	return &controller{logger: logger, dnsLogger: dnsLogger}
}

func (c *controller) running() bool { return c.prx != nil }

// buildConfig assembles a proxy.Config for one upstream. Bootstrap uses
// NewUpstreamResolver ("resolve the upstream hostname VIA this DNS"), never
// StaticResolver and never a nil Bootstrap (which would fall back to the system
// resolver we've pointed at ourselves → death-loop, B7). bootstrapAddr may be a
// space-separated list → a ParallelResolver tries them concurrently, first win
// (used to give NextDNS two anycast IPs). Each resolver is wrapped in a
// CachingResolver so the upstream hostname is re-resolved once per record TTL
// instead of on every DoT exchange / DoQ connection. R-7: explicit cache size.
func buildConfig(dnsLogger *slog.Logger, upstreamURL, bootstrapAddr string) (*proxy.Config, error) {
	var boot upstream.ParallelResolver
	for _, addr := range strings.Fields(bootstrapAddr) {
		r, err := upstream.NewUpstreamResolver(addr, &upstream.Options{
			Logger:  dnsLogger,
			Timeout: 5 * time.Second,
		})
		if err != nil {
			return nil, fmt.Errorf("bootstrap resolver %q: %w", addr, err)
		}
		// Wrap each resolver individually, as dnsproxy's own CLI does
		// (internal/cmd/proxy.go:263) — NewCachingResolver takes exactly one
		// *UpstreamResolver, so the ParallelResolver as a whole cannot be
		// wrapped. A cache miss still goes to r and never to the system
		// resolver, so B7 holds.
		boot = append(boot, upstream.NewCachingResolver(r))
	}
	if len(boot) == 0 {
		return nil, fmt.Errorf("no bootstrap resolver for %q", upstreamURL)
	}
	uc, err := proxy.ParseUpstreamsConfig([]string{upstreamURL}, &upstream.Options{
		Logger:    dnsLogger,
		Bootstrap: boot,
		Timeout:   5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("parse upstream: %w", err) // no URL in msg — may embed id
	}
	return &proxy.Config{
		Logger:          dnsLogger,
		UDPListenAddr:   []*net.UDPAddr{{IP: net.ParseIP(listenIP), Port: listenPort}},
		TCPListenAddr:   []*net.TCPAddr{{IP: net.ParseIP(listenIP), Port: listenPort}},
		UpstreamConfig:  uc,
		CacheEnabled:    true,
		CacheOptimistic: true,
		CacheSizeBytes:  4 * 1024 * 1024,
	}, nil
}

// swapTo makes upstreamURL the live upstream via Option B. Handles both the
// initial start (old == nil) and a hot switch. On any failure before the old is
// shut down, the old proxy keeps running untouched.
func (c *controller) swapTo(ctx context.Context, upstreamURL, bootstrapAddr string) error {
	cfg, err := buildConfig(c.dnsLogger, upstreamURL, bootstrapAddr)
	if err != nil {
		return err
	}
	newPrx, err := proxy.New(cfg)
	if err != nil {
		return fmt.Errorf("proxy.New: %w", err)
	}

	// Self-test the upstream in-process, before exposing a listener. Accept if
	// either A or AAAA returned — v4-only networks give empty AAAA (SF-c).
	testCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	addrs, terr := newPrx.LookupNetIP(testCtx, "ip", selfTestName)
	cancel()
	if terr != nil || len(addrs) == 0 {
		// Drop the half-built proxy (SF-2). Shutdown releases its upstreams;
		// the bootstrap resolvers need no Close of their own — plainDNS.Close
		// is a no-op and *CachingResolver isn't an io.Closer at all — so they
		// simply go with it.
		_ = newPrx.Shutdown(ctx)
		if terr != nil {
			return fmt.Errorf("%w: %v", errUpstreamUnreachable, terr)
		}
		return fmt.Errorf("%w: no addresses returned", errUpstreamUnreachable)
	}

	if err := newPrx.Start(ctx); err != nil {
		_ = newPrx.Shutdown(ctx) // SF-2
		return fmt.Errorf("start (bind %s:%d): %w", listenIP, listenPort, err)
	}

	old := c.prx
	c.prx = newPrx
	if old != nil {
		if err := old.Shutdown(ctx); err != nil {
			c.logger.Warn("shutdown old proxy failed", "err", err)
		}
	}
	return nil
}

// startInitial brings the first proxy up WITHOUT gating on the self-test.
// Binding :53 is the real "can we run" gate; the default upstream's reachability
// is not — the daemon comes up unpinned and the app (or boot-restore) decides
// whether to pin. Returns whether the self-test passed so the caller can gate a
// boot pin (BL-1); a miss is otherwise only a warning. (S-2)
func (c *controller) startInitial(ctx context.Context, upstreamURL, bootstrapAddr string) (selfTestOK bool, err error) {
	cfg, err := buildConfig(c.dnsLogger, upstreamURL, bootstrapAddr)
	if err != nil {
		return false, err
	}
	p, err := proxy.New(cfg)
	if err != nil {
		return false, fmt.Errorf("proxy.New: %w", err)
	}
	if err := p.Start(ctx); err != nil {
		_ = p.Shutdown(ctx)
		return false, fmt.Errorf("start (bind %s:%d): %w", listenIP, listenPort, err)
	}
	testCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	addrs, terr := p.LookupNetIP(testCtx, "ip", selfTestName)
	cancel()
	ok := terr == nil && len(addrs) > 0
	if !ok {
		// terr is deliberately not logged: it wraps the upstream's error, which
		// embeds the full upstream URL — for NextDNS/AliDNS that includes the
		// user's private profile id/device name, and the launchd log this goes
		// to is world-readable (same H2 rationale as coordinator.switchLocked).
		c.logger.Warn("initial upstream self-test failed; starting unpinned",
			"timeout", terr != nil && errors.Is(terr, context.DeadlineExceeded))
	}
	c.prx = p
	return ok, nil
}

// selfTest re-checks the CURRENT proxy's upstream in-process. Used to gate a
// pending pin (docs/07 §3/§5). Returns false if no proxy is running.
func (c *controller) selfTest(ctx context.Context) bool {
	if c.prx == nil {
		return false
	}
	testCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	addrs, err := c.prx.LookupNetIP(testCtx, "ip", selfTestName)
	return err == nil && len(addrs) > 0
}

func (c *controller) Shutdown(ctx context.Context) {
	if c.prx != nil {
		if err := c.prx.Shutdown(ctx); err != nil {
			c.logger.Warn("proxy shutdown failed", "err", err)
		}
		c.prx = nil
	}
}
