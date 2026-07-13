package main

// LOCAL_PEERCRED peer-uid check for the control socket (docs/06 §1, SF-e).
// macOS xucred gives the peer uid (no pid, unlike Linux SO_PEERCRED) — enough
// for a uid gate. Verify the struct version before trusting the uid.

import (
	"fmt"
	"net"

	"golang.org/x/sys/unix"
)

// macOS XUCRED_VERSION (<sys/ucred.h>) is 0; x/sys/unix doesn't export it.
const macXucredVersion = 0

func peerUID(conn *net.UnixConn) (uint32, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var xucred *unix.Xucred
	var opErr error
	if cerr := raw.Control(func(fd uintptr) {
		xucred, opErr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); cerr != nil {
		return 0, cerr
	}
	if opErr != nil {
		return 0, opErr
	}
	if xucred.Version != macXucredVersion {
		return 0, fmt.Errorf("unexpected xucred version %d", xucred.Version)
	}
	return xucred.Uid, nil
}
