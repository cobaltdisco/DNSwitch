package main

// Peer code-signature verification for the control socket (docs/07 §2, S-2).
//
// A uid match alone is insufficient: ANY process running as the owner uid could
// otherwise send commands (e.g. disable encryption). So, when this binary is
// signed with a Team ID, we additionally take the peer's audit token
// (LOCAL_PEERTOKEN) and require it to satisfy a designated code requirement —
// "anchor apple generic and certificate leaf[subject.OU] = <ourTeam>" — i.e. the
// client must be signed by the same Apple team. This runs on the existing Unix
// socket; no XPC needed.

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/libbsm.h>
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>

// dnswitch_verify_peer checks the peer connected on fd against the code
// requirement string reqStr. Returns 1 when valid, 0 when the signature does not
// satisfy the requirement, and a negative code on API error.
static int dnswitch_verify_peer(int fd, const char *reqStr) {
	audit_token_t token;
	socklen_t len = sizeof(token);
	if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) != 0) {
		return -1;
	}
	if (len != sizeof(token)) {
		return -2;
	}
	CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
	if (data == NULL) {
		return -3;
	}
	const void *keys[1] = { (const void *)kSecGuestAttributeAudit };
	const void *vals[1] = { (const void *)data };
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(data);
	if (attrs == NULL) {
		return -4;
	}
	SecCodeRef code = NULL;
	OSStatus st = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code);
	CFRelease(attrs);
	if (st != errSecSuccess || code == NULL) {
		if (code != NULL) {
			CFRelease(code);
		}
		return -5;
	}
	CFStringRef s = CFStringCreateWithCString(NULL, reqStr, kCFStringEncodingUTF8);
	if (s == NULL) {
		CFRelease(code);
		return -6;
	}
	SecRequirementRef req = NULL;
	st = SecRequirementCreateWithString(s, kSecCSDefaultFlags, &req);
	CFRelease(s);
	if (st != errSecSuccess || req == NULL) {
		CFRelease(code);
		if (req != NULL) {
			CFRelease(req);
		}
		return -7;
	}
	st = SecCodeCheckValidity(code, kSecCSDefaultFlags, req);
	CFRelease(req);
	CFRelease(code);
	return (st == errSecSuccess) ? 1 : 0;
}
*/
import "C"

import (
	"fmt"
	"net"
	"unsafe"
)

// peerRequirement builds the designated requirement string for control clients:
// signed by Apple and by our team. team is our own 10-char Team ID (trusted,
// from our own signature — no escaping needed).
func peerRequirement(team string) string {
	return fmt.Sprintf(`anchor apple generic and certificate leaf[subject.OU] = "%s"`, team)
}

// verifyPeerCodeSignature reports whether the peer on conn satisfies requirement.
// A non-nil error is an API-level failure (treat as reject); (false, nil) is a
// clean signature mismatch.
func verifyPeerCodeSignature(conn *net.UnixConn, requirement string) (bool, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return false, err
	}
	creq := C.CString(requirement)
	defer C.free(unsafe.Pointer(creq))
	rc := C.int(-100)
	if cerr := raw.Control(func(fd uintptr) {
		rc = C.dnswitch_verify_peer(C.int(fd), creq)
	}); cerr != nil {
		return false, cerr
	}
	switch {
	case rc == 1:
		return true, nil
	case rc == 0:
		return false, nil
	default:
		return false, fmt.Errorf("SecCodeCheckValidity path failed (rc=%d)", int(rc))
	}
}
