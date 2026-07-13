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
	closing bool
}

func newCoordinator(logger *slog.Logger, ctrl *controller, dns *dnsManager) *coordinator {
	return &coordinator{logger: logger, ctrl: ctrl, dns: dns}
}

// initStart brings the proxy up with the default selection, unpinned.
func (c *coordinator) initStart(ctx context.Context, sel selection) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	url, bootstrap, cerr := sel.resolve()
	if cerr != nil {
		return cerr
	}
	if err := c.ctrl.startInitial(ctx, url, bootstrap); err != nil {
		return err
	}
	c.cur, c.curURL, c.enabled = sel, url, false
	return nil
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
	sel := selection{Provider: req.Provider, Protocol: req.Protocol, ID: req.ID}
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
	return okResp(c.stateLocked())
}

func (c *coordinator) stateLocked() *stateDTO {
	return &stateDTO{
		Enabled:   c.enabled,
		Provider:  c.cur.Provider,
		Protocol:  c.cur.Protocol,
		Upstream:  c.curURL,
		Listening: c.ctrl.running(),
		Pinned:    c.enabled,
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
