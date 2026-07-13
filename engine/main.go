// Command engine is the Phase 0 walking skeleton (docs/05): a root daemon that
// embeds AdGuard dnsproxy, binds 127.0.0.1:53, and points the system DNS at
// itself — with crash-safe restore. Driven from the terminal via `sudo`.
//
//	sudo ./engine     # start; Ctrl-C to stop and restore DNS
//
// No menu-bar app, no IPC, no provider switching yet (those are Phase 1).
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"
)

const (
	// R-5: use https, not h3 — the skeleton shouldn't be hostage to UDP/443,
	// and dnsproxy's h3:// has no fallback.
	phase0Upstream  = "https://dns.google/dns-query"
	phase0Bootstrap = "8.8.8.8:53" // B7: resolve dns.google via this, never the system resolver
	selfTestName    = "example.com"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	// dnsproxy is chatty at INFO (a dozen "creating/listening/entering loop" lines
	// per start). Keep the library at WARN so our own startup/reconcile lines are
	// easy to see; real dnsproxy problems still surface.
	dnsLogger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))

	if os.Geteuid() != 0 {
		logger.Error("must run as root — binding :53 and setting system DNS require root; use: sudo ./engine")
		os.Exit(1)
	}

	// Single-instance guard. dnsproxy sets SO_REUSEPORT, so binding :53 does NOT
	// exclude a second instance (verified) — this flock is the real lock. On
	// failure we exit before touching anything; the kernel releases it on exit,
	// including kill -9.
	lock, lerr := acquireLock()
	if lerr != nil {
		logger.Error("cannot start; system DNS untouched", "err", lerr)
		os.Exit(1)
	}
	defer func() { _ = lock.Close() }()

	mgr := newDNSManager(logger)
	ctrl := newController(logger, dnsLogger)
	ctx := context.Background()

	// SF-3: trap signals BEFORE any slow startup step (each networksetup shell-out
	// takes real time). Registering now means a Ctrl-C during startup is buffered
	// and handled gracefully after pinAll, rather than hard-killing mid-pin. We
	// never signal.Stop, so further signals stay trapped and can't abort cleanup.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	// Step 2 (B-1): bind before touching DNS; on a bind failure system DNS is
	// untouched. Single-instance is enforced by the flock above, NOT by this bind
	// — dnsproxy sets SO_REUSEPORT so a second bind would otherwise succeed
	// (verified). Reconcile runs after, now that we hold the lock.
	if err := ctrl.Apply(ctx, phase0Upstream, phase0Bootstrap); err != nil {
		logger.Error("failed to start proxy; system DNS untouched", "err", err,
			"hint", "is port 53 in use? check: sudo lsof -nP -iUDP:53 -iTCP:53")
		os.Exit(1)
	}
	logger.Info("proxy listening", "addr", "127.0.0.1:53", "upstream", phase0Upstream)

	// Step 1, now that we own the port (BL-1): reconcile any leftover snapshot
	// from an unclean prior exit — restores the true originals and clears the
	// stale pin, so the fresh snapshot in pinAll records real values, not residue.
	mgr.reconcileOnStartup()

	// Step 3 (B-1): self-test through the listener before touching DNS.
	testCtx, cancel := context.WithTimeout(ctx, 6*time.Second)
	err := ctrl.SelfTest(testCtx, selfTestName)
	cancel()
	if err != nil {
		logger.Error("self-test failed; system DNS untouched, shutting down", "err", err)
		shutdown(ctx, ctrl)
		os.Exit(1)
	}
	logger.Info("self-test ok", "query", selfTestName)

	// Steps 4-5 (B-1): snapshot originals, then pin system DNS at us. A partial
	// pin returns an error → restore + exit, never a false "encrypted" claim (SF-4).
	if err := mgr.pinAll(); err != nil {
		logger.Error("failed to pin system DNS; restoring and shutting down", "err", err)
		mgr.restoreAll()
		shutdown(ctx, ctrl)
		os.Exit(1)
	}
	logger.Info("system DNS now points at the local encrypted resolver — Ctrl-C to stop and restore")

	// Block until a termination signal (already buffered if it arrived during
	// startup), then clean up.
	sig := <-sigCh
	logger.Info("signal received; shutting down", "signal", sig.String())
	logger.Info("restoring system DNS...")
	mgr.restoreAll()
	shutdown(ctx, ctrl)
	logger.Info("clean shutdown complete")
}

// shutdown stops the proxy with a bounded context so a wedged proxy.Shutdown
// can't hang the exit (nit).
func shutdown(ctx context.Context, ctrl *controller) {
	sctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ctrl.Shutdown(sctx)
}
