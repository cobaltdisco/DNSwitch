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
	"os/user"
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

	// Everything the embedded dnsproxy logs goes through redactHandler: the
	// library writes the id-bearing upstream URL and the queried name at Error
	// level, and this file is on disk (H2, see redactlog.go).
	dnsLogger := slog.New(newRedactHandler(
		slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn})))

	// dnsproxy's bootstrap resolver falls back to slog.Default() when no logger
	// rides the context (internal/bootstrap/resolver.go:78), and nothing in this
	// daemon puts one there — so the process default must be redacted too, or
	// that path writes the URL straight past dnsLogger.
	slog.SetDefault(dnsLogger)

	if os.Geteuid() != 0 {
		logger.Error("must run as root — use: sudo ./engine")
		os.Exit(1)
	}

	// Socket ownership + peer auth (docs/07 §2). Manual `sudo ./engine` owns by
	// the invoking user (uid-only unless signed); a launchd daemon owns by the
	// GUI console user and enforces the peer code signature when signed.
	ac := resolveAuth(logger, ownTeamID())

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

	srv := newServer(socketPath, ac.ownerUID, ac.ownerGID, ac.ownerKnown, ac.codeReq, coord, logger)
	if err := srv.listen(); err != nil {
		logger.Error("failed to open control socket", "path", socketPath, "err", err)
		coord.shutdown(ctx)
		os.Exit(1)
	}
	go srv.serve()
	logger.Info("control socket ready", "path", socketPath,
		"owner_uid", ac.ownerUID, "owner_known", ac.ownerKnown, "sig_gate", ac.codeReq != "")

	// DNS watchdog (docs/07 §5): re-pin on network drift; in daemon mode also
	// track the console user for socket ownership (S-5). Both actions are
	// idempotent and gated on state, so firing on any SC change is safe.
	wd := newWatchdog(logger, func() {
		if ac.daemonMode {
			if uid, ok := consoleUser(); ok {
				srv.updateOwner(uid, primaryGID(uid), true)
			} else {
				srv.updateOwner(0, 0, false)
			}
		}
		coord.onNetworkChange()
	})
	wd.start()

	sig := <-sigCh
	logger.Info("signal received; shutting down", "signal", sig.String())

	// BL-A: stop accepting first, then the interlocked shutdown (restore DNS if
	// pinned + stop proxy under the coordinator lock).
	srv.close()
	wd.stop()
	sctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	coord.shutdown(sctx)
	logger.Info("clean shutdown complete")
}

// authConfig captures who may drive the control socket and how (docs/07 §2).
type authConfig struct {
	ownerUID   uint32
	ownerGID   int
	ownerKnown bool   // false ⇒ no console user yet ⇒ reject all (fail closed)
	daemonMode bool   // console-user ownership (vs manual SUDO_UID dev run)
	codeReq    string // peer code requirement; "" ⇒ uid-only (unsigned build)
}

// resolveAuth decides socket ownership + peer verification. ownTeam is this
// binary's Team ID ("" when unsigned/ad-hoc). A signed build enforces the peer
// code-signature gate; an unsigned dev build falls back to uid-only so
// `sudo ./engine` + nc keeps working.
func resolveAuth(logger *slog.Logger, ownTeam string) authConfig {
	codeReq := ""
	if ownTeam != "" {
		codeReq = peerRequirement(ownTeam)
	}
	if os.Getenv("SUDO_UID") != "" {
		uid, gid, err := sudoOwner()
		if err != nil {
			logger.Error("cannot determine the owning user; run via sudo so SUDO_UID is set", "err", err)
			os.Exit(1)
		}
		if codeReq == "" {
			logger.Warn("unsigned build: control auth is uid-only (dev mode)")
		}
		return authConfig{ownerUID: uid, ownerGID: gid, ownerKnown: true, daemonMode: false, codeReq: codeReq}
	}
	// launchd daemon: owned by the GUI console user, with the peer signature as
	// the PRIMARY defense (uid alone is insufficient — S-2). If we cannot enforce
	// it (unsigned/teamless engine — most likely the app-signing/build-order trap
	// in docs/07 §1), the control socket stays reject-all: refuse control from
	// any same-uid process rather than degrade to uid-only. The core (proxy + pin
	// + watchdog) still runs, preserving the headless invariant (S-5).
	ac := authConfig{daemonMode: true, codeReq: codeReq}
	if codeReq == "" {
		logger.Error("daemon mode but engine is unsigned/teamless; control socket DISABLED (fail closed) — core DNS stays active; fix the app signing / Run-Script build order")
		return ac // ownerKnown stays false ⇒ reject all
	}
	if uid, ok := consoleUser(); ok {
		ac.ownerUID, ac.ownerGID, ac.ownerKnown = uid, primaryGID(uid), true
	} else {
		logger.Warn("no console user at startup; control socket rejects until login (headless core still active)")
	}
	return ac
}

// primaryGID returns the primary group id for uid, or 0 (wheel) if it cannot be
// resolved — group is only used to chmod the socket; the uid check is the gate.
func primaryGID(uid uint32) int {
	u, err := user.LookupId(strconv.FormatUint(uint64(uid), 10))
	if err != nil {
		return 0
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return 0
	}
	return gid
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
