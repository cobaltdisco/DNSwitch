package main

// Console-user resolution and the engine's own Team ID (docs/07 §2).
//
// consoleUser() drives socket ownership in daemon mode: the socket is owned by
// whoever is logged into the GUI, and there is NO owner (fail closed) at the
// login window / before first login. SCDynamicStoreCopyConsoleUser is flagged by
// Apple as possibly-deprecated, so it is quarantined in this one function.
//
// ownTeamID() lets the peer code-signature gate be self-configuring: we require
// control clients to be signed by the SAME team as this binary. An unsigned or
// ad-hoc dev build (plain `go build`) has no team → the gate disables itself and
// falls back to uid-only, so `sudo ./engine` + `nc` still works for testing.

/*
#cgo LDFLAGS: -framework SystemConfiguration -framework CoreFoundation -framework Security
#include <sys/types.h>
#include <stdlib.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <Security/Security.h>

// dnswitch_console_user returns the GUI console user's uid and sets *ok=1, or
// sets *ok=0 when there is no interactive user: NULL name, empty name,
// "loginwindow" (at the login screen), or uid 0. Fail closed (docs/07 §2).
static uid_t dnswitch_console_user(int *ok) {
	uid_t uid = 0;
	gid_t gid = 0;
	CFStringRef name = SCDynamicStoreCopyConsoleUser(NULL, &uid, &gid);
	if (name == NULL) {
		*ok = 0;
		return 0;
	}
	int bad = (CFStringGetLength(name) == 0) ||
	          (CFStringCompare(name, CFSTR("loginwindow"), 0) == kCFCompareEqualTo);
	CFRelease(name);
	if (bad || uid == 0) {
		*ok = 0;
		return 0;
	}
	*ok = 1;
	return uid;
}

// dnswitch_own_team returns a malloc'd UTF-8 Team Identifier of THIS running
// binary, or NULL if it is unsigned / ad-hoc / has no team. Caller frees.
static char *dnswitch_own_team(void) {
	SecCodeRef self = NULL;
	if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess || self == NULL) {
		return NULL;
	}
	SecStaticCodeRef stat = NULL;
	OSStatus st = SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &stat);
	CFRelease(self);
	if (st != errSecSuccess || stat == NULL) {
		return NULL;
	}
	CFDictionaryRef info = NULL;
	st = SecCodeCopySigningInformation(stat, kSecCSSigningInformation, &info);
	CFRelease(stat);
	if (st != errSecSuccess || info == NULL) {
		return NULL;
	}
	char *out = NULL;
	CFStringRef team = (CFStringRef)CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
	if (team != NULL && CFStringGetLength(team) > 0) {
		CFIndex len = CFStringGetLength(team);
		CFIndex max = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
		out = (char *)malloc(max);
		if (out != NULL && !CFStringGetCString(team, out, max, kCFStringEncodingUTF8)) {
			free(out);
			out = NULL;
		}
	}
	CFRelease(info);
	return out;
}
*/
import "C"

import "unsafe"

// consoleUser returns the uid of the current GUI console user and true, or
// (0, false) when there is no interactive user (login screen / not yet logged
// in / NULL). Callers MUST fail closed on false (docs/07 §2, S-5).
func consoleUser() (uint32, bool) {
	var ok C.int
	uid := C.dnswitch_console_user(&ok)
	return uint32(uid), ok != 0
}

// ownTeamID returns this binary's code-signing Team Identifier, or "" when the
// binary is unsigned / ad-hoc / teamless (a plain `go build` dev build). "" means
// the peer signature gate cannot be enforced and callers fall back to uid-only.
func ownTeamID() string {
	c := C.dnswitch_own_team()
	if c == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(c))
	return C.GoString(c)
}
