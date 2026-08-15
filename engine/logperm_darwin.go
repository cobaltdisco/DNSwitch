package main

import (
	"os"
	"syscall"
)

// secureStderr tightens the daemon's log to 0600, in case launchd created it
// world-readable.
//
// The plist asks for Umask=0o77 so launchd creates StandardErrorPath 0600
// before exec — no window at all. But that only holds when launchd is actually
// USING the current plist, and for an SMAppService-registered daemon it keeps
// the copy it cached at REGISTRATION time: after upgrading the bundle,
// `launchctl print` still reported the previous bundle's version and none of
// the new keys, even after the app called register() again on launch (measured,
// not assumed — register() is documented as idempotent, but idempotent here
// means "no-op", not "re-read"). Only unregister+register refreshes it, and
// that costs the user a re-approval in System Settings on every upgrade.
//
// So the plist covers fresh installs and this covers upgrades. It runs on every
// start, which also handles someone deleting the log: launchd recreates it with
// the stale umask and the next engine start clamps it again. Once tightened the
// mode sticks — launchd reopens an existing file rather than recreating it.
//
// Operates on the descriptor, not a path: fd 2 IS the log, so nothing has to
// agree with the plist about where it lives, and there is no window between
// looking a path up and acting on it. A dev run's terminal is left alone.
func secureStderr() {
	if err := secureLogFD(int(os.Stderr.Fd())); err != nil {
		// Nothing to do about it and nowhere safe to say so — this runs before
		// the logger exists, and the whole point is that the sink may be
		// readable. The plist's Umask is the other half of the belt.
		_ = err
	}
}

// secureLogFD chmods fd to 0600 when it is a regular file with any group or
// other bits set. Non-regular descriptors (a terminal under `sudo ./engine`,
// /dev/null, a pipe) are left untouched: they aren't ours, and clamping a tty
// would be actively wrong.
func secureLogFD(fd int) error {
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return err
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return nil
	}
	if st.Mode&0o077 == 0 {
		return nil // already tight
	}
	return syscall.Fchmod(fd, 0o600)
}
