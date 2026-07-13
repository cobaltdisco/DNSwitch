package main

// Unix-domain-socket control server (docs/06 §1,§5; docs/07 §2). Two-gate auth:
// (1) LOCAL_PEERCRED uid == the current owner, and (2) — when this binary is
// signed (codeReq != "") — the peer's audit-token code signature satisfies our
// team requirement (S-2). The owner can change at runtime as the console user
// logs in/out (S-5); it is stored atomically. Never holds the coordinator lock
// while writing to a connection (SF-d).

import (
	"bufio"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxLineBytes = 64 * 1024
	idleTimeout  = 2 * time.Minute // reap a connection that goes idle (S-3)
)

type server struct {
	path    string
	coord   *coordinator
	logger  *slog.Logger
	ln      *net.UnixListener
	codeReq string // peer code requirement; "" = uid-only (unsigned dev build)

	ownerUID   atomic.Uint32 // read on every connection
	ownerKnown atomic.Bool   // false ⇒ no console user ⇒ reject all (fail closed)
	mu         sync.Mutex    // guards ownerGID + chown + change logging
	ownerGID   int
}

func newServer(path string, ownerUID uint32, ownerGID int, ownerKnown bool, codeReq string, coord *coordinator, logger *slog.Logger) *server {
	s := &server{path: path, coord: coord, logger: logger, codeReq: codeReq, ownerGID: ownerGID}
	s.ownerUID.Store(ownerUID)
	s.ownerKnown.Store(ownerKnown)
	return s
}

func (s *server) listen() error {
	_ = os.Remove(s.path) // unlink stale
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: s.path, Net: "unix"})
	if err != nil {
		return err
	}
	s.ln = ln
	// Explicit 0660 root:<owner-gid> after bind (don't rely on umask). The uid
	// check remains the authoritative gate; group 0 (wheel) when there's no owner.
	if err := os.Chmod(s.path, 0o660); err != nil {
		return err
	}
	gid := 0
	if s.ownerKnown.Load() {
		s.mu.Lock()
		gid = s.ownerGID
		s.mu.Unlock()
	}
	return os.Chown(s.path, 0, gid)
}

// updateOwner switches the socket owner as the console user changes (S-5). When
// known, it re-chowns the socket to the new owner's group; when not known (user
// logged out / at login window), the socket rejects all connections. Never
// touches DNS pinning. No-op when nothing changed.
func (s *server) updateOwner(uid uint32, gid int, known bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	prevKnown := s.ownerKnown.Load()
	prevUID := s.ownerUID.Load()
	if known == prevKnown && (!known || uid == prevUID) {
		return
	}
	s.ownerKnown.Store(known)
	if known {
		s.ownerUID.Store(uid)
		s.ownerGID = gid
		if err := os.Chown(s.path, 0, gid); err != nil {
			s.logger.Warn("re-chown control socket failed", "err", err)
		}
		s.logger.Info("control-socket owner updated", "uid", uid)
	} else {
		s.logger.Warn("no console user; control socket now rejects all (fail closed)")
	}
}

func (s *server) serve() {
	for {
		conn, err := s.ln.AcceptUnix()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return // clean shutdown (listener closed)
			}
			s.logger.Warn("accept failed; backing off", "err", err)
			time.Sleep(50 * time.Millisecond) // avoid a busy-loop on e.g. EMFILE (S-3)
			continue
		}
		go s.handle(conn)
	}
}

func (s *server) handle(conn *net.UnixConn) {
	defer func() { _ = conn.Close() }()

	if !s.ownerKnown.Load() {
		s.logger.Warn("rejecting connection: no console user (fail closed)")
		return
	}
	uid, err := peerUID(conn)
	if err != nil {
		s.logger.Warn("peercred check failed; dropping connection", "err", err)
		return
	}
	if uid != s.ownerUID.Load() {
		s.logger.Warn("rejecting connection from unexpected uid", "uid", uid, "want", s.ownerUID.Load())
		return
	}
	// Second gate: peer must be signed by our team (S-2). Skipped when this
	// binary is unsigned/ad-hoc (codeReq == "") so dev tooling (nc) still works.
	if s.codeReq != "" {
		ok, verr := verifyPeerCodeSignature(conn, s.codeReq)
		if verr != nil {
			s.logger.Warn("peer signature check errored; dropping connection", "err", verr)
			return
		}
		if !ok {
			s.logger.Warn("rejecting connection: peer code signature does not satisfy team requirement")
			return
		}
	}

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 4096), maxLineBytes) // bound line length
	enc := json.NewEncoder(conn)
	for {
		// Idle read deadline: reap a client that connects but never sends, so it
		// can't park a goroutine + hold an fd indefinitely (S-3). Reset per line.
		if err := conn.SetReadDeadline(time.Now().Add(idleTimeout)); err != nil {
			return
		}
		if !sc.Scan() {
			break
		}
		// Re-check ownership per request: a connection held across a console-user
		// change (fast user switch / logout) must stop being served (S-5). The
		// signature is immutable for a live process, so it need not be rechecked.
		if !s.ownerKnown.Load() || uid != s.ownerUID.Load() {
			s.logger.Warn("owner changed mid-connection; dropping", "uid", uid)
			return
		}
		var req request
		if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
			if wErr := enc.Encode(errResp("bad_request", "invalid JSON")); wErr != nil {
				return
			}
			continue
		}
		// coord.handle serializes internally and returns data only — we encode
		// the reply here, holding no lock (SF-d).
		if err := enc.Encode(s.coord.handle(req)); err != nil {
			return // client gone
		}
	}
	if err := sc.Err(); err != nil {
		s.logger.Warn("connection closed on read (idle timeout or line too long)", "err", err)
	}
}

func (s *server) close() {
	if s.ln != nil {
		_ = s.ln.Close() // unblocks the accept loop
	}
	_ = os.Remove(s.path)
}
