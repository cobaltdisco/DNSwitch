package main

// coordinator serializes all control operations and owns the split between the
// proxy (controller) and system DNS (dnsManager). It is the single lock in the
// engine; the controller and dnsManager do no locking of their own.
//
// enabled = "is system DNS pinned to us" (docs/06 Q3). The proxy always runs
// and reflects the current selection; switching while disabled still applies
// immediately (harmless — nothing points at :53 — and surfaces upstream errors
// at switch time, so enable can never fail).

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

type coordinator struct {
	mu      sync.Mutex
	logger  *slog.Logger
	ctrl    *controller
	dns     *dnsManager
	cur     selection
	curURL  string
	enabled bool
	pending bool // wanted enabled but boot self-test failed; retry when reachable
	closing bool
}

func newCoordinator(logger *slog.Logger, ctrl *controller, dns *dnsManager) *coordinator {
	return &coordinator{logger: logger, ctrl: ctrl, dns: dns}
}

// initStart brings the proxy up with the default selection, unpinned (used when
// there is no persisted state).
func (c *coordinator) initStart(ctx context.Context, sel selection) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	url, bootstrap, cerr := sel.resolve()
	if cerr != nil {
		return cerr
	}
	if _, err := c.ctrl.startInitial(ctx, url, bootstrap); err != nil {
		return err
	}
	c.cur, c.curURL, c.enabled = sel, url, false
	c.logger.Info("started on default upstream, disabled", "provider", sel.Provider, "protocol", sel.Protocol)
	return nil
}

// bootRestore applies persisted state at startup: bring the proxy up on the saved
// selection (unpinned), then — if the user had it enabled — pin ONLY if the boot
// self-test passes; otherwise stay unpinned with pending=true so the watchdog (or
// the next command) retries. Never bricks a captive-portal/offline boot (BL-1).
func (c *coordinator) bootRestore(ctx context.Context, sel selection, wantEnabled bool) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	url, bootstrap, cerr := sel.resolve()
	if cerr != nil {
		return cerr
	}
	ok, err := c.ctrl.startInitial(ctx, url, bootstrap)
	if err != nil {
		return err
	}
	c.cur, c.curURL = sel, url
	if !wantEnabled {
		c.logger.Info("boot: restored selection, disabled", "provider", sel.Provider, "protocol", sel.Protocol)
		return nil
	}
	if ok {
		if perr := c.dns.pinAll(); perr != nil {
			c.dns.restoreAll()
			c.pending = true
			c.logger.Warn("boot: pin failed; will retry", "err", perr)
		} else {
			c.enabled = true
			c.logger.Info("boot: restored enabled, system DNS pinned",
				"provider", sel.Provider, "protocol", sel.Protocol)
		}
	} else {
		c.pending = true
		c.logger.Warn("boot: upstream unreachable; staying unpinned, will pin when it recovers (pending)")
	}
	return nil
}

// persist writes the current selection + enabled to disk (durable intent, §3).
// Caller holds mu.
func (c *coordinator) persist() {
	st := &persistedState{
		Version:  1,
		Provider: c.cur.Provider,
		Protocol: c.cur.Protocol,
		ID:       c.cur.ID,
		Device:   c.cur.Device,
		Enabled:  c.enabled,
	}
	if err := saveState(st); err != nil {
		c.logger.Warn("persist state failed", "err", err)
	}
}

// retryPendingLocked completes a deferred boot pin once the upstream is reachable.
// Called opportunistically from handle() (and by the phase-2 watchdog on network
// events). Caller holds mu.
func (c *coordinator) retryPendingLocked(ctx context.Context) {
	if !c.pending || c.enabled || c.closing {
		return
	}
	if !c.ctrl.selfTest(ctx) {
		return
	}
	if err := c.dns.pinAll(); err != nil {
		c.dns.restoreAll()
		return
	}
	c.enabled, c.pending = true, false
	c.persist()
	c.logger.Info("pending enable completed; system DNS pinned")
}

// onNetworkChange is the watchdog's debounced entry point (docs/07 §5). Under
// the lock it (1) completes a deferred boot pin if the upstream just became
// reachable (pending, BL-1), and (2) re-pins the primary resolver if it drifted
// off 127.0.0.1 while enabled. Both are idempotent no-ops when nothing changed.
func (c *coordinator) onNetworkChange() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closing {
		return
	}
	if c.pending {
		c.retryPendingLocked(context.Background())
	}
	if c.enabled {
		c.dns.rePinDrifted()
	}
}

func (c *coordinator) handle(req request) response {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closing {
		return errResp("closing", "daemon is shutting down")
	}
	if req.V != protocolVersion {
		return errResp("bad_version", "unsupported protocol version")
	}
	if c.pending {
		c.retryPendingLocked(context.Background()) // opportunistic deferred-pin retry
	}
	switch req.Cmd {
	case "status":
		return okResp(c.stateLocked())
	case "switch":
		return c.switchLocked(req)
	case "set_enabled":
		return c.setEnabledLocked(req)
	default:
		return errResp("bad_request", "unknown command")
	}
}

func (c *coordinator) switchLocked(req request) response {
	sel := selection{Provider: req.Provider, Protocol: req.Protocol, ID: req.ID, Device: req.Device}
	url, bootstrap, cerr := sel.resolve()
	if cerr != nil {
		return errResp(cerr.Code, cerr.Msg)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := c.ctrl.swapTo(ctx, url, bootstrap); err != nil {
		code, msg := codeOf(err)
		// Log the underlying err server-side for debuggability (runtime stderr,
		// root-only, not the repo — H2 is about what's committed). Client sees
		// only the curated code/msg.
		c.logger.Warn("switch failed", "provider", sel.Provider, "protocol", sel.Protocol, "code", code, "err", err)
		return errResp(code, msg)
	}
	c.cur, c.curURL = sel, url
	c.persist()
	c.logger.Info("switched upstream", "provider", sel.Provider, "protocol", sel.Protocol) // id redacted
	return okResp(c.stateLocked())
}

func (c *coordinator) setEnabledLocked(req request) response {
	if req.Enabled == nil {
		return errResp("bad_request", "missing 'enabled'")
	}
	if *req.Enabled {
		if !c.enabled {
			if err := c.dns.pinAll(); err != nil {
				c.dns.restoreAll() // undo any partial pin
				code, msg := codeOf(err)
				c.logger.Warn("enable (pin) failed", "err", err)
				return errResp(code, msg)
			}
			c.enabled = true
			c.logger.Info("enabled: system DNS pinned to local resolver")
		}
	} else {
		if c.enabled {
			c.dns.restoreAll()
			c.enabled = false
			c.logger.Info("disabled: system DNS restored")
		}
	}
	c.pending = false // explicit intent supersedes a deferred boot pin
	c.persist()
	return okResp(c.stateLocked())
}

func (c *coordinator) stateLocked() *stateDTO {
	return &stateDTO{
		Enabled:   c.enabled,
		Provider:  c.cur.Provider,
		Protocol:  c.cur.Protocol,
		ID:        c.cur.ID,
		Device:    c.cur.Device,
		Upstream:  c.curURL,
		Listening: c.ctrl.running(),
		Pinned:    c.enabled,

		EngineVersion:   engineBuildVersion(),
		DnsproxyVersion: dnsproxyVer,
	}
}

// shutdown is the BL-A interlock (docs/06 §5): under mu, set closing (so any
// queued handler bails without mutating), restore DNS if pinned, then stop the
// proxy. Holding mu the whole time drains any in-flight handler first and makes
// a post-restore re-pin impossible. Caller must stop accepting connections
// (server.close) BEFORE calling this.
func (c *coordinator) shutdown(ctx context.Context) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closing = true
	if c.enabled {
		c.dns.restoreAll()
		c.enabled = false
	}
	c.ctrl.Shutdown(ctx)
}
