package main

// System DNS management via `networksetup`. Runs as root (B6). All the edge
// cases here are per the Fable-5 advisor review (R-2) and the snapshot
// invariants (B-2). Phase 2 will replace shell-outs with SystemConfiguration.

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os/exec"
	"strings"
	"time"
)

const localDNS = "127.0.0.1"

// Absolute path, not a bare name: under launchd the daemon does NOT inherit a
// login PATH (chunk ② was only ever run via `sudo`, which did). A missing
// /usr/sbin would otherwise make every pin fail silently as a warning. (chunk ③)
const networksetupBin = "/usr/sbin/networksetup"

type dnsManager struct {
	logger *slog.Logger
	// run executes a networksetup subcommand. A field rather than a method so
	// tests can substitute a fake: every read and write in this file goes
	// through it, so swapping it exercises the real pin/restore logic against
	// scripted networksetup behaviour. Deliberately NOT an interface around
	// dnsManager — a fake dnsManager would make the tests assert on the fake
	// instead of on the code that ships.
	run func(args ...string) ([]byte, error)
}

func newDNSManager(logger *slog.Logger) *dnsManager {
	return &dnsManager{logger: logger, run: runNetworksetup}
}

const networksetupTimeout = 15 * time.Second

// runNetworksetup executes a networksetup subcommand with a bounded timeout, so
// a wedged call cannot hold the coordinator lock — or block shutdown's restore —
// forever (S-1). networksetup ignores stdout for writes; callers may discard it.
func runNetworksetup(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), networksetupTimeout)
	defer cancel()
	return exec.CommandContext(ctx, networksetupBin, args...).Output()
}

// listServices returns enabled, non-VPN network service names. It skips the
// header line ("An asterisk (*) denotes...") and disabled ("*"-prefixed)
// services (R-2), and excludes VPN-like services by interface type so we never
// pin a tunnel's DNS (docs/07 §5, S-4). If VPN classification fails we log and
// proceed without skipping rather than pin nothing.
func (m *dnsManager) listServices() ([]string, error) {
	out, err := m.run("-listallnetworkservices")
	if err != nil {
		return nil, fmt.Errorf("listallnetworkservices: %w", err)
	}
	// Fail CLOSED: if we can't tell which services are VPNs, refuse to enumerate
	// rather than risk pinning a tunnel's DNS (docs/07 §5 red line, S-4). pinAll
	// then reports the enable as failed (SF-4) and rePinDrifted declines; neither
	// restoreAll nor reconcileOnStartup calls this, so restores are unaffected.
	vpn, verr := vpnServiceNames()
	if verr != nil {
		return nil, fmt.Errorf("classify VPN services: %w", verr)
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
		if vpn[line] {
			m.logger.Info("skipping VPN service", "service", line)
			continue
		}
		services = append(services, line)
	}
	return services, sc.Err()
}

// errServiceGone means the snapshot names a network service macOS no longer
// has: the user deleted it, renamed it, or it turned into something we skip.
// It is not a failure to act on — there is nothing left to restore — so restore
// tolerates it instead of holding the snapshot open forever.
//
// networksetup reports this on STDOUT with exit status 4 (measured), which is
// why the marker is matched against the captured output rather than the error.
var errServiceGone = errors.New("network service no longer exists")

const notAServiceMarker = "is not a recognized network service"

// getDNS returns the manually-set DNS servers for a service. An empty result
// means DHCP — networksetup prints "There aren't any DNS Servers set on X." (R-2)
func (m *dnsManager) getDNS(service string) ([]string, error) {
	out, err := m.run("-getdnsservers", service)
	if err != nil {
		if strings.Contains(string(out), notAServiceMarker) {
			return nil, fmt.Errorf("%w: %q", errServiceGone, service)
		}
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
//
// It MERGES with any existing snapshot rather than replacing it. A restore that
// fails deliberately keeps the snapshot so a retry is possible; without the
// merge, re-enabling would read those services back while they are STILL pinned
// at 127.0.0.1, record that as "was on DHCP", and destroy the only copy of the
// user's real settings.
//
// The merge rule is LIVE VALUE WINS, unless the live value is our own loopback:
// pinAll only ever runs while we do NOT own the system DNS (every caller checks
// enabled first), so a non-loopback value there is the user's current choice and
// must replace whatever we recorded before. Only when the service is still
// showing our pin do we fall back to the recorded original.
//
// Note the asymmetry with rePinDrifted, which must NOT adopt this rule: that one
// runs while we DO own the DNS, so a non-loopback value is drift to be corrected,
// not a choice to be honoured. The two look similar and mean opposite things.
func (m *dnsManager) pinAll() error {
	services, err := m.listServices()
	if err != nil {
		return err
	}
	// An unreadable snapshot may be the only record of the user's original DNS,
	// so refuse to pin rather than overwrite it with a fresh one.
	prev, err := loadSnapshot()
	if err != nil {
		return fmt.Errorf("load snapshot: %w", err)
	}
	recorded := map[string][]string{}
	if prev != nil {
		if prev.Version != 1 {
			return fmt.Errorf("snapshot version %d unsupported; refusing to pin", prev.Version)
		}
		for _, s := range prev.Services {
			// Presence-keyed: a DHCP original is a nil slice, so membership must
			// be tested with the two-value form, never len(Servers) > 0.
			recorded[s.Service] = s.Servers
		}
	}

	snap := &snapshot{Version: 1, PinnedTo: localDNS}
	// The write set is built from the LIVE services, never from snap.Services —
	// that slice also carries stale entries for services macOS no longer has,
	// and pinning those would fail forever.
	var toPin []string
	seen := map[string]bool{}
	for _, svc := range services {
		cur, err := m.getDNS(svc)
		if err != nil {
			// Pre-existing SF-4 gap: a service we cannot read is skipped, so a
			// flapping interface does not block enabling. Left as-is here on
			// purpose; changing it needs its own decision.
			m.logger.Warn("read dns failed; skipping service", "service", svc, "err", err)
			continue
		}
		seen[svc] = true
		toPin = append(toPin, svc)
		orig := cur
		if isLoopback(cur) {
			if rec, ok := recorded[svc]; ok {
				orig = rec // our residue: the recorded original is the truth
			} else {
				orig = nil // residue with no record → treat as DHCP (B-2)
			}
		}
		snap.Services = append(snap.Services, serviceDNS{Service: svc, Servers: orig})
	}
	// Carry forward entries for services we can no longer see — deleted, renamed,
	// or newly VPN-classified. They are not pinned, but keeping the record means
	// a later restore can still put them back if they return.
	if prev != nil {
		for _, s := range prev.Services {
			if !seen[s.Service] {
				snap.Services = append(snap.Services, s)
			}
		}
	}

	if len(toPin) == 0 {
		return fmt.Errorf("no network services to configure")
	}
	// Persist before touching anything (B-2 atomicity).
	if err := saveSnapshot(snap); err != nil {
		return fmt.Errorf("save snapshot: %w", err)
	}
	var failed []string
	for _, svc := range toPin {
		if err := m.setDNS(svc, []string{localDNS}); err != nil {
			m.logger.Warn("pin failed", "service", svc, "err", err)
			failed = append(failed, svc)
			continue
		}
		m.logger.Info("pinned to local resolver", "service", svc)
	}
	if len(failed) > 0 {
		// SF-4: never report success on a partial pin — those services would be
		// resolving in cleartext while the caller believes we're encrypted.
		return fmt.Errorf("pinned %d/%d services; failed: %v",
			len(toPin)-len(failed), len(toPin), failed)
	}
	return nil
}

// rePinDrifted forces any managed service whose DNS has drifted off 127.0.0.1
// back to the local resolver (docs/07 §5). Called by the watchdog while enabled.
// Invariants:
//   - compare-before-write (S-3): a service already at loopback is not written,
//     so our own writes don't retrigger the SC notification into a feedback loop;
//   - a service that appears after the initial pin (e.g. a hot-plugged adapter) is
//     adopted into the snapshot with its pre-pin original — DHCP/loopback residue
//     recorded as nil — and the enlarged snapshot is persisted BEFORE any write
//     (B-2), so a crash can't strand a service we pinned but never recorded; if
//     the save fails we decline to pin;
//   - never runs without a snapshot (enabled ⇒ pinAll already wrote one); a
//     missing snapshot means inconsistent state, so it declines rather than pin
//     with no way back.
//
// The caller (coordinator) holds the lock and has already checked enabled.
func (m *dnsManager) rePinDrifted() {
	snap, err := loadSnapshot()
	if err != nil {
		m.logger.Error("re-pin: load snapshot failed", "err", err)
		return
	}
	if snap == nil {
		m.logger.Warn("re-pin: enabled but no snapshot; declining")
		return
	}
	services, err := m.listServices() // already VPN-filtered
	if err != nil {
		m.logger.Warn("re-pin: list services failed", "err", err)
		return
	}
	known := make(map[string]bool, len(snap.Services))
	for _, s := range snap.Services {
		known[s.Service] = true
	}

	// Pass 1: classify. Adopt any service we don't yet manage into the snapshot,
	// recording its pre-pin original (loopback residue counts as DHCP, never
	// persisted as an "original" — B-2). Collect only drifted services to write
	// (compare-before-write, S-3).
	var toWrite []string
	snapChanged := false
	for _, svc := range services {
		cur, err := m.getDNS(svc)
		if err != nil {
			m.logger.Warn("re-pin: read dns failed; skipping", "service", svc, "err", err)
			continue
		}
		alreadyOurs := isLoopback(cur)
		if !known[svc] {
			orig := cur
			if alreadyOurs {
				orig = nil
			}
			snap.Services = append(snap.Services, serviceDNS{Service: svc, Servers: orig})
			known[svc] = true
			snapChanged = true
			m.logger.Info("re-pin: now managing service", "service", svc)
		}
		if !alreadyOurs {
			toWrite = append(toWrite, svc)
		}
	}

	// Persist the enlarged snapshot BEFORE any write (B-2 atomicity): a crash
	// between pin and save must never strand a service we pinned but never
	// recorded. If the save fails, decline to pin — never write what we haven't
	// durably recorded.
	if snapChanged {
		if err := saveSnapshot(snap); err != nil {
			m.logger.Warn("re-pin: save snapshot failed; not pinning newly-seen services", "err", err)
			return
		}
	}

	// Pass 2: write.
	for _, svc := range toWrite {
		if err := m.setDNS(svc, []string{localDNS}); err != nil {
			m.logger.Warn("re-pin failed", "service", svc, "err", err)
			continue
		}
		m.logger.Info("re-pinned drifted service", "service", svc)
	}
}

// restoreAll restores each snapshotted service to its original value — but only
// if the service is STILL pinned at 127.0.0.1 (conditional reconciliation,
// B-2 stale-clobber guard). It read-back-verifies each restore and deletes the
// snapshot only if every service succeeded; otherwise it keeps the snapshot for
// the next startup reconciliation.
// It returns an error when anything is still owed, so callers can tell the user
// instead of reporting a restore that did not happen. The snapshot's presence on
// disk is the durable form of the same fact — that is what survives a crash.
func (m *dnsManager) restoreAll() error {
	snap, err := loadSnapshot()
	if err != nil {
		// Nothing was restored and we cannot tell what should be.
		m.logger.Error("load snapshot failed", "err", err)
		return fmt.Errorf("load snapshot: %w", err)
	}
	if snap == nil {
		return nil // nothing pinned, nothing owed
	}
	allOK := true
	for _, s := range snap.Services {
		cur, err := m.getDNS(s.Service)
		if err != nil {
			if errors.Is(err, errServiceGone) {
				// Nothing to restore and nothing to retry: the service is gone.
				// Deliberately does NOT clear allOK — otherwise one deleted or
				// renamed service would keep the snapshot alive forever and
				// every restore would report failure from then on.
				m.logger.Info("restore: service no longer exists, dropping", "service", s.Service)
				continue
			}
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
	if !allOK {
		m.logger.Warn("restore incomplete; keeping snapshot for next-start reconciliation")
		return fmt.Errorf("restore incomplete; original DNS not fully put back")
	}
	if err := deleteSnapshot(); err != nil {
		// The DNS values are right, but the record outlives them — and callers
		// derive "a restore is still owed" from that file existing. Report it
		// rather than let the state lie; retrying is harmless and idempotent.
		m.logger.Warn("delete snapshot failed", "err", err)
		return fmt.Errorf("delete snapshot: %w", err)
	}
	return nil
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
	if err := m.restoreAll(); err != nil {
		// Startup has no caller to report to; the snapshot stays on disk and the
		// next command (or the next start) tries again.
		m.logger.Warn("startup: reconciliation incomplete", "err", err)
	}
}
