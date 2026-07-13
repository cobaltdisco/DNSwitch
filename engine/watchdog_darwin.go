package main

// DNS watchdog (docs/07 §5). SCDynamicStore fires goWatchdogNotify on any
// network/DNS/console-user change; we debounce a burst of events into a single
// re-evaluation. The C run-loop plumbing is in watchdog_cgo_darwin.go.
//
// The onEvent handler (wired in main) does two idempotent things: refresh the
// socket owner if the console user changed (S-5), and re-pin the primary
// resolver if it drifted off 127.0.0.1 while enabled (S-3). Both no-op when
// nothing changed, so firing on every event is safe.

import "C"

import (
	"log/slog"
	"runtime"
	"sync"
	"time"
)

const watchdogDebounce = 1500 * time.Millisecond

type watchdog struct {
	logger   *slog.Logger
	onEvent  func()
	debounce time.Duration
	events   chan struct{}
	stopCh   chan struct{}
	once     sync.Once
}

// activeWatchdog is the single instance the C callback routes to. Guarded by
// wdMu because start/stop and the callback touch it from different threads.
var (
	wdMu           sync.Mutex
	activeWatchdog *watchdog
)

func newWatchdog(logger *slog.Logger, onEvent func()) *watchdog {
	return &watchdog{
		logger:   logger,
		onEvent:  onEvent,
		debounce: watchdogDebounce,
		events:   make(chan struct{}, 1),
		stopCh:   make(chan struct{}),
	}
}

//export goWatchdogNotify
func goWatchdogNotify() {
	wdMu.Lock()
	w := activeWatchdog
	wdMu.Unlock()
	if w == nil {
		return
	}
	select {
	case w.events <- struct{}{}: // coalesce: buffer of 1, drop extras
	default:
	}
}

// start launches the debounce loop and the SC run loop (on a locked OS thread).
// Non-fatal: if SC setup fails the engine keeps running without auto-repair.
func (w *watchdog) start() {
	wdMu.Lock()
	activeWatchdog = w
	wdMu.Unlock()

	go w.loop()
	go func() {
		runtime.LockOSThread() // CFRunLoopGetCurrent is per-thread
		defer runtime.UnlockOSThread()
		if rc := scWatchdogRun(); rc < 0 {
			w.logger.Warn("DNS watchdog setup failed; running without auto-repair", "rc", rc)
		}
	}()
	w.logger.Info("DNS watchdog active", "debounce", watchdogDebounce.String())
}

// loop coalesces a burst of SC notifications into one onEvent call.
func (w *watchdog) loop() {
	var timer *time.Timer
	var timerC <-chan time.Time
	arm := func() {
		if timer == nil {
			timer = time.NewTimer(w.debounce)
			timerC = timer.C
			return
		}
		if !timer.Stop() {
			select {
			case <-timerC:
			default:
			}
		}
		timer.Reset(w.debounce)
	}
	for {
		select {
		case <-w.events:
			arm()
		case <-timerC:
			timer, timerC = nil, nil
			w.onEvent()
		case <-w.stopCh:
			if timer != nil {
				timer.Stop()
			}
			return
		}
	}
}

// stop tears down the watchdog (best effort; safe to call once).
func (w *watchdog) stop() {
	w.once.Do(func() {
		wdMu.Lock()
		if activeWatchdog == w {
			activeWatchdog = nil
		}
		wdMu.Unlock()
		close(w.stopCh)
		scWatchdogStop()
	})
}
