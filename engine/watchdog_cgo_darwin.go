package main

// SCDynamicStore run-loop plumbing for the DNS watchdog (docs/07 §5). This file
// holds the C definitions; the exported Go callback goWatchdogNotify lives in
// watchdog_darwin.go (cgo forbids //export in a file that also defines C code).
//
// We watch the network/DNS state keys and the console-user key, then let Go
// debounce and act. SC does the observing/enumerating; DNS writes still go
// through networksetup (proven in phase 0/1).

/*
#cgo LDFLAGS: -framework SystemConfiguration -framework CoreFoundation
#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>

// Implemented in Go (watchdog_darwin.go).
extern void goWatchdogNotify(void);

// gStore/gSource are touched only on the run-loop thread. gRunLoop is published
// by the run-loop thread and read by dnswitch_watchdog_stop from another thread,
// so it is atomic. (A stop landing before the loop starts is a no-op; that only
// happens at process exit, where a parked thread is harmless.)
static SCDynamicStoreRef gStore = NULL;
static CFRunLoopSourceRef gSource = NULL;
static _Atomic(CFRunLoopRef) gRunLoop = NULL;

static void dnswitch_store_cb(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
	(void)store; (void)changedKeys; (void)info;
	goWatchdogNotify();
}

// dnswitch_watchdog_run sets up the SCDynamicStore notifications on the CURRENT
// thread and then runs its run loop, blocking until dnswitch_watchdog_stop.
// Returns 0 after a clean stop, negative on setup failure.
static int dnswitch_watchdog_run(void) {
	gStore = SCDynamicStoreCreate(NULL, CFSTR("com.dnswitch.engine"), dnswitch_store_cb, NULL);
	if (gStore == NULL) {
		return -1;
	}
	CFMutableArrayRef keys = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFArrayAppendValue(keys, CFSTR("State:/Network/Global/DNS"));
	CFArrayAppendValue(keys, CFSTR("State:/Network/Global/IPv4"));
	CFArrayAppendValue(keys, CFSTR("State:/Network/Global/IPv6"));
	CFArrayAppendValue(keys, CFSTR("State:/Users/ConsoleUser"));

	CFMutableArrayRef patterns = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFArrayAppendValue(patterns, CFSTR("Setup:/Network/Service/[^/]+/DNS"));

	Boolean set = SCDynamicStoreSetNotificationKeys(gStore, keys, patterns);
	CFRelease(keys);
	CFRelease(patterns);
	if (!set) {
		CFRelease(gStore);
		gStore = NULL;
		return -2;
	}
	gSource = SCDynamicStoreCreateRunLoopSource(NULL, gStore, 0);
	if (gSource == NULL) {
		CFRelease(gStore);
		gStore = NULL;
		return -3;
	}
	CFRunLoopRef rl = CFRunLoopGetCurrent();
	atomic_store(&gRunLoop, rl);
	CFRunLoopAddSource(rl, gSource, kCFRunLoopDefaultMode);
	CFRunLoopRun();

	atomic_store(&gRunLoop, NULL);
	CFRunLoopRemoveSource(rl, gSource, kCFRunLoopDefaultMode);
	CFRelease(gSource);
	gSource = NULL;
	CFRelease(gStore);
	gStore = NULL;
	return 0;
}

// dnswitch_watchdog_stop asks the run loop to exit (best effort).
static void dnswitch_watchdog_stop(void) {
	CFRunLoopRef rl = atomic_load(&gRunLoop);
	if (rl != NULL) {
		CFRunLoopStop(rl);
	}
}
*/
import "C"

// scWatchdogRun installs the SC notifications and runs the CFRunLoop, blocking
// until scWatchdogStop. Must be called on a locked OS thread. Returns a negative
// setup-error code, or 0 after a clean stop.
func scWatchdogRun() int { return int(C.dnswitch_watchdog_run()) }

// scWatchdogStop signals the run loop started by scWatchdogRun to exit.
func scWatchdogStop() { C.dnswitch_watchdog_stop() }
