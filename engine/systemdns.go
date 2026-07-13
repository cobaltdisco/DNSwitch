package main

// System DNS management via `networksetup`. Runs as root (B6). All the edge
// cases here are per the Fable-5 advisor review (R-2) and the snapshot
// invariants (B-2). Phase 2 will replace shell-outs with SystemConfiguration.

import (
	"bufio"
	"context"
	"fmt"
	"log/slog"
	"net"
	"os/exec"
	"strings"
	"time"
)

const localDNS = "127.0.0.1"

type dnsManager struct {
	logger *slog.Logger
}

func newDNSManager(logger *slog.Logger) *dnsManager {
	return &dnsManager{logger: logger}
}

const networksetupTimeout = 15 * time.Second

// run executes a networksetup subcommand with a bounded timeout, so a wedged
// call cannot hold the coordinator lock — or block shutdown's restore — forever
// (S-1). networksetup ignores stdout for writes; callers may discard it.
func (m *dnsManager) run(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), networksetupTimeout)
	defer cancel()
	return exec.CommandContext(ctx, "networksetup", args...).Output()
}

// listServices returns enabled network service names. It skips the header line
// ("An asterisk (*) denotes...") and disabled ("*"-prefixed) services. (R-2)
func (m *dnsManager) listServices() ([]string, error) {
	out, err := m.run("-listallnetworkservices")
	if err != nil {
		return nil, fmt.Errorf("listallnetworkservices: %w", err)
	}
	var services []string
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first { // header line
			first = false
			continue
		}
		if line == "" || strings.HasPrefix(line, "*") { // blank or disabled
			continue
		}
		services = append(services, line)
	}
	return services, sc.Err()
}

// getDNS returns the manually-set DNS servers for a service. An empty result
// means DHCP — networksetup prints "There aren't any DNS Servers set on X." (R-2)
func (m *dnsManager) getDNS(service string) ([]string, error) {
	out, err := m.run("-getdnsservers", service)
	if err != nil {
		return nil, fmt.Errorf("getdnsservers %q: %w", service, err)
	}
	var servers []string
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if strings.Contains(line, "aren't any DNS Servers") {
			return nil, nil // DHCP
		}
		if net.ParseIP(line) == nil {
			// Not an IP (unexpected/localized output): be conservative, ignore.
			continue
		}
		servers = append(servers, line)
	}
	return servers, sc.Err()
}

// setDNS sets DNS servers for a service; an empty list means "Empty" (DHCP).
// Uses an argv array — service names contain spaces/parens ("Thunderbolt
// Bridge", "iPhone USB"), so a shell string would be wrong. (R-2)
func (m *dnsManager) setDNS(service string, servers []string) error {
	args := []string{"-setdnsservers", service}
	if len(servers) == 0 {
		args = append(args, "Empty")
	} else {
		args = append(args, servers...)
	}
	if _, err := m.run(args...); err != nil {
		return fmt.Errorf("setdnsservers %q: %w", service, err)
	}
	return nil
}

// isLoopback reports whether servers is exactly our pin — every entry a loopback
// address (127.0.0.1 / ::1). Used to distinguish "our residue" from real user
// config throughout the B-2 invariants. An empty list is NOT loopback.
func isLoopback(servers []string) bool {
	if len(servers) == 0 {
		return false
	}
	for _, s := range servers {
		ip := net.ParseIP(s)
		if ip == nil || !ip.IsLoopback() {
			return false
		}
	}
	return true
}

// pinAll snapshots each service's original DNS, then points every service at
// 127.0.0.1. The snapshot is persisted BEFORE the first write (B-2 atomicity).
// A value that is already loopback is treated as our own residue, never
// persisted as an "original" (B-2 poisoned-snapshot guard).
func (m *dnsManager) pinAll() error {
	services, err := m.listServices()
	if err != nil {
		return err
	}
	snap := &snapshot{Version: 1, PinnedTo: localDNS}
	for _, svc := range services {
		cur, err := m.getDNS(svc)
		if err != nil {
			m.logger.Warn("read dns failed; skipping service", "service", svc, "err", err)
			continue
		}
		orig := cur
		if isLoopback(cur) {
			orig = nil // residue, not user config → treat as DHCP (B-2)
		}
		snap.Services = append(snap.Services, serviceDNS{Service: svc, Servers: orig})
	}
	if len(snap.Services) == 0 {
		return fmt.Errorf("no network services to configure")
	}
	// Persist before touching anything (B-2 atomicity).
	if err := saveSnapshot(snap); err != nil {
		return fmt.Errorf("save snapshot: %w", err)
	}
	var failed []string
	for _, s := range snap.Services {
		if err := m.setDNS(s.Service, []string{localDNS}); err != nil {
			m.logger.Warn("pin failed", "service", s.Service, "err", err)
			failed = append(failed, s.Service)
			continue
		}
		m.logger.Info("pinned to local resolver", "service", s.Service)
	}
	if len(failed) > 0 {
		// SF-4: never report success on a partial pin — those services would be
		// resolving in cleartext while the caller believes we're encrypted.
		return fmt.Errorf("pinned %d/%d services; failed: %v",
			len(snap.Services)-len(failed), len(snap.Services), failed)
	}
	return nil
}

// restoreAll restores each snapshotted service to its original value — but only
// if the service is STILL pinned at 127.0.0.1 (conditional reconciliation,
// B-2 stale-clobber guard). It read-back-verifies each restore and deletes the
// snapshot only if every service succeeded; otherwise it keeps the snapshot for
// the next startup reconciliation.
func (m *dnsManager) restoreAll() {
	snap, err := loadSnapshot()
	if err != nil {
		m.logger.Error("load snapshot failed", "err", err)
		return
	}
	if snap == nil {
		return
	}
	allOK := true
	for _, s := range snap.Services {
		cur, err := m.getDNS(s.Service)
		if err != nil {
			m.logger.Warn("restore: read current failed", "service", s.Service, "err", err)
			allOK = false
			continue
		}
		if !isLoopback(cur) {
			// User/OS moved this service on since we pinned it — don't clobber.
			m.logger.Info("restore: service no longer pinned, leaving as-is",
				"service", s.Service, "current", cur)
			continue
		}
		if err := m.setDNS(s.Service, s.Servers); err != nil {
			m.logger.Warn("restore failed", "service", s.Service, "err", err)
			allOK = false
			continue
		}
		back, err := m.getDNS(s.Service)
		if err != nil || isLoopback(back) {
			m.logger.Warn("restore verify failed", "service", s.Service, "err", err)
			allOK = false
			continue
		}
		m.logger.Info("restored original dns", "service", s.Service, "servers", s.Servers)
	}
	if allOK {
		if err := deleteSnapshot(); err != nil {
			m.logger.Warn("delete snapshot failed", "err", err)
		}
	} else {
		m.logger.Warn("restore incomplete; keeping snapshot for next-start reconciliation")
	}
}

// reconcileOnStartup restores a leftover snapshot from an unclean prior exit
// (crash-recovery layer 1, docs/05 §F). Same conditional logic as restoreAll.
func (m *dnsManager) reconcileOnStartup() {
	snap, err := loadSnapshot()
	if err != nil {
		m.logger.Error("startup: load snapshot failed", "path", snapshotFile, "err", err)
		return
	}
	if snap == nil {
		m.logger.Info("startup: no leftover snapshot; clean start", "path", snapshotFile)
		return
	}
	m.logger.Warn("startup: leftover DNS snapshot found (unclean prior exit); reconciling",
		"path", snapshotFile, "services", len(snap.Services))
	m.restoreAll()
}
