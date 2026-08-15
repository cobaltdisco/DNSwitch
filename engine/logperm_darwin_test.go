package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestSecureLogFDTightensRegularFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "engine.log")
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	defer f.Close()
	// OpenFile's perm is masked by the process umask, so set it explicitly —
	// otherwise the test would pass on a machine that never had the problem.
	if err := f.Chmod(0o644); err != nil {
		t.Fatalf("chmod: %v", err)
	}

	if err := secureLogFD(int(f.Fd())); err != nil {
		t.Fatalf("secureLogFD: %v", err)
	}

	fi, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if got := fi.Mode().Perm(); got != 0o600 {
		t.Errorf("mode = %04o, want 0600", got)
	}
}

func TestSecureLogFDLeavesTightFileAlone(t *testing.T) {
	p := filepath.Join(t.TempDir(), "engine.log")
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	defer f.Close()
	if err := f.Chmod(0o640); err != nil { // group-readable: still too loose
		t.Fatalf("chmod: %v", err)
	}
	if err := secureLogFD(int(f.Fd())); err != nil {
		t.Fatalf("secureLogFD: %v", err)
	}
	fi, _ := os.Stat(p)
	if got := fi.Mode().Perm(); got != 0o600 {
		t.Errorf("group-readable file was not tightened: mode = %04o", got)
	}
}

// A terminal under `sudo ./engine`, /dev/null, or a pipe must be left alone —
// clamping the developer's tty would be actively wrong.
func TestSecureLogFDIgnoresNonRegular(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	defer r.Close()
	defer w.Close()

	var before syscall.Stat_t
	if err := syscall.Fstat(int(w.Fd()), &before); err != nil {
		t.Fatalf("fstat: %v", err)
	}
	if err := secureLogFD(int(w.Fd())); err != nil {
		t.Fatalf("secureLogFD on a pipe should be a no-op, got %v", err)
	}
	var after syscall.Stat_t
	if err := syscall.Fstat(int(w.Fd()), &after); err != nil {
		t.Fatalf("fstat: %v", err)
	}
	if before.Mode != after.Mode {
		t.Errorf("pipe mode changed: %o → %o", before.Mode, after.Mode)
	}
}
