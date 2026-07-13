package main

// VPN classification for the pin/re-pin path (docs/07 §5, S-4). We must never
// point a VPN service's DNS at 127.0.0.1 — that would hijack or break its
// tunnel resolver. Modern NE/utun VPNs (Tailscale/WireGuard) never appear in
// `networksetup -listallnetworkservices` (they use scoped resolvers), so they're
// already skipped for free. What CAN appear are system-configured VPNs
// (IKEv2/L2TP/IPSec); we skip them by INTERFACE TYPE / BSD-name family, never by
// service name.

/*
#cgo LDFLAGS: -framework SystemConfiguration -framework CoreFoundation
#include <stdlib.h>
#include <SystemConfiguration/SystemConfiguration.h>

// dnswitch_vpn_service_names returns a malloc'd, newline-separated UTF-8 list of
// network-service NAMES whose interface is VPN-like. Empty string means "none".
// NULL means the enumeration itself failed. Caller frees.
static char *dnswitch_vpn_service_names(void) {
	SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("com.dnswitch.engine"), NULL);
	if (prefs == NULL) {
		return NULL;
	}
	CFArrayRef services = SCNetworkServiceCopyAll(prefs);
	if (services == NULL) {
		CFRelease(prefs);
		return NULL;
	}
	CFMutableStringRef acc = CFStringCreateMutable(NULL, 0);
	if (acc == NULL) {
		CFRelease(services);
		CFRelease(prefs);
		return NULL;
	}
	CFIndex n = CFArrayGetCount(services);
	for (CFIndex i = 0; i < n; i++) {
		SCNetworkServiceRef svc = (SCNetworkServiceRef)CFArrayGetValueAtIndex(services, i);
		SCNetworkInterfaceRef intf = SCNetworkServiceGetInterface(svc);
		if (intf == NULL) {
			continue;
		}
		int isVPN = 0;
		CFStringRef type = SCNetworkInterfaceGetInterfaceType(intf);
		if (type != NULL) {
			if (CFStringCompare(type, CFSTR("VPN"), 0) == kCFCompareEqualTo ||
			    CFStringCompare(type, CFSTR("IPSec"), 0) == kCFCompareEqualTo ||
			    CFStringCompare(type, CFSTR("L2TP"), 0) == kCFCompareEqualTo ||
			    CFStringCompare(type, CFSTR("PPP"), 0) == kCFCompareEqualTo) {
				isVPN = 1;
			}
		}
		if (!isVPN) {
			CFStringRef bsd = SCNetworkInterfaceGetBSDName(intf);
			if (bsd != NULL &&
			    (CFStringHasPrefix(bsd, CFSTR("utun")) ||
			     CFStringHasPrefix(bsd, CFSTR("ipsec")) ||
			     CFStringHasPrefix(bsd, CFSTR("ppp")) ||
			     CFStringHasPrefix(bsd, CFSTR("tun")) ||
			     CFStringHasPrefix(bsd, CFSTR("tap")))) {
				isVPN = 1;
			}
		}
		if (isVPN) {
			CFStringRef name = SCNetworkServiceGetName(svc);
			if (name != NULL) {
				CFStringAppend(acc, name);
				CFStringAppend(acc, CFSTR("\n"));
			}
		}
	}
	CFRelease(services);
	CFRelease(prefs);

	CFIndex len = CFStringGetLength(acc);
	CFIndex max = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
	char *buf = (char *)malloc(max);
	if (buf != NULL && !CFStringGetCString(acc, buf, max, kCFStringEncodingUTF8)) {
		free(buf); // must not report "no VPNs" (fail-open) on a conversion failure
		buf = NULL;
	}
	CFRelease(acc);
	return buf; // NULL ⇒ classification failed; caller must fail closed
}
*/
import "C"

import (
	"fmt"
	"strings"
	"unsafe"
)

// vpnServiceNames returns the set of network-service names that are VPN-like and
// must be excluded from DNS pinning (docs/07 §5). A non-nil error means the
// classification failed and the caller should not pin blindly.
func vpnServiceNames() (map[string]bool, error) {
	c := C.dnswitch_vpn_service_names()
	if c == nil {
		return nil, fmt.Errorf("SCNetworkServiceCopyAll enumeration failed")
	}
	defer C.free(unsafe.Pointer(c))
	out := map[string]bool{}
	for _, line := range strings.Split(C.GoString(c), "\n") {
		if line != "" {
			out[line] = true
		}
	}
	return out, nil
}
