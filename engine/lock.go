package main

// Single-instance lock. dnsproxy sets SO_REUSEADDR + SO_REUSEPORT on all its
// listeners (verified in v0.83.0), so binding 127.0.0.1:53 does NOT exclude a
// second instance — two engines would happily co-bind and stomp on each other's
// DNS snapshot. An exclusive flock is the real guard. The kernel releases it
// automatically when the process exits, including on kill -9, so recovery after
// a crash Just Works.

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

const lockFilePath = "/var/run/dnswitch.lock"

// acquireLock takes an exclusive, non-blocking flock. The returned *os.File MUST
// be kept open for the process lifetime — closing it releases the lock.
func acquireLock() (*os.File, error) {
	f, err := os.OpenFile(lockFilePath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock file %s: %w", lockFilePath, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errors.New("another instance is already running")
		}
		return nil, fmt.Errorf("flock %s: %w", lockFilePath, err)
	}
	return f, nil
}
