// Command engine is the DNS switcher daemon. Phase 1 (docs/06): a root daemon
// that embeds AdGuard dnsproxy on 127.0.0.1:53 and exposes a Unix-socket control
// protocol; the menu-bar app switches provider/protocol and pins/unpins system
// DNS through it. Starts DISABLED (proxy running, DNS not pinned) — the app
// drives enable/switch.
//
//	sudo ./engine     # Ctrl-C to stop (restores DNS if pinned)
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

const (
	socketPath   = "/var/run/dnswitch.sock"
	selfTestName = "example.com"
)

// defaultSelection is what the proxy runs on at startup, before the app picks.
// Cloudflare DoH: universal, no id required.
var defaultSelection = selection{Provider: "cloudflare", Protocol: "doh"}

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	dnsLogger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))

	if os.Geteuid() != 0 {
		logger.Error("must run as root — use: sudo ./engine")
		os.Exit(1)
	}
	ownerUID, ownerGID, err := sudoOwner()
	if err != nil {
		logger.Error("cannot determine the owning user; run via sudo so SUDO_UID is set", "err", err)
		os.Exit(1)
	}

	// Single-instance guard (bind is not exclusive under SO_REUSEPORT — B10).
	lock, lerr := acquireLock()
	if lerr != nil {
		logger.Error("cannot start; another instance? system DNS untouched", "err", lerr)
		os.Exit(1)
	}
	defer func() { _ = lock.Close() }()

	// Trap signals before any slow startup step (SF-3).
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	mgr := newDNSManager(logger)
	ctrl := newController(logger, dnsLogger)
	coord := newCoordinator(logger, ctrl, mgr)
	ctx := context.Background()

	// Crash recovery: restore any leftover pin from an unclean prior exit.
	mgr.reconcileOnStartup()

	// Restore persisted state (Q2: auto-pin per last enabled, gated on a boot
	// self-test so a captive-portal/offline boot never bricks — BL-1), or start
	// on the default unpinned if there is no saved state.
	st, serr := loadState()
	if serr != nil {
		logger.Warn("load state failed; starting on default", "err", serr)
		st = nil
	}
	restored := false
	if st != nil {
		sel := selection{Provider: st.Provider, Protocol: st.Protocol, ID: st.ID, Device: st.Device}
		if err := coord.bootRestore(ctx, sel, st.Enabled); err != nil {
			logger.Warn("restore from saved state failed; falling back to default", "err", err)
		} else {
			restored = true
		}
	}
	if !restored {
		if err := coord.initStart(ctx, defaultSelection); err != nil {
			logger.Error("failed to start proxy; system DNS untouched", "err", err,
				"hint", "port 53 in use? sudo lsof -nP -iUDP:53 -iTCP:53")
			os.Exit(1)
		}
	}
	logger.Info("engine listening", "addr", "127.0.0.1:53")

	srv := newServer(socketPath, ownerUID, ownerGID, coord, logger)
	if err := srv.listen(); err != nil {
		logger.Error("failed to open control socket", "path", socketPath, "err", err)
		coord.shutdown(ctx)
		os.Exit(1)
	}
	go srv.serve()
	logger.Info("control socket ready", "path", socketPath, "owner_uid", ownerUID)

	sig := <-sigCh
	logger.Info("signal received; shutting down", "signal", sig.String())

	// BL-A: stop accepting first, then the interlocked shutdown (restore DNS if
	// pinned + stop proxy under the coordinator lock).
	srv.close()
	sctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	coord.shutdown(sctx)
	logger.Info("clean shutdown complete")
}

// sudoOwner returns the uid/gid of the user that invoked sudo. It refuses if
// SUDO_UID is unset (daemon run directly as root) rather than defaulting owner
// to uid 0, which would leave the menu-bar app unable to connect. (SF-e)
func sudoOwner() (uint32, int, error) {
	su, sg := os.Getenv("SUDO_UID"), os.Getenv("SUDO_GID")
	if su == "" || sg == "" {
		return 0, 0, fmt.Errorf("SUDO_UID/SUDO_GID not set")
	}
	uid, err := strconv.Atoi(su)
	if err != nil {
		return 0, 0, fmt.Errorf("bad SUDO_UID: %w", err)
	}
	gid, err := strconv.Atoi(sg)
	if err != nil {
		return 0, 0, fmt.Errorf("bad SUDO_GID: %w", err)
	}
	return uint32(uid), gid, nil
}
