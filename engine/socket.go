package main

// Unix-domain-socket control server (docs/06 §1,§5). Owner-only via
// LOCAL_PEERCRED; NDJSON request→response; never holds the coordinator lock
// while writing to a connection (SF-d).

import (
	"bufio"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"os"
)

const maxLineBytes = 64 * 1024

type server struct {
	path     string
	ownerUID uint32
	ownerGID int
	coord    *coordinator
	logger   *slog.Logger
	ln       *net.UnixListener
}

func newServer(path string, ownerUID uint32, ownerGID int, coord *coordinator, logger *slog.Logger) *server {
	return &server{path: path, ownerUID: ownerUID, ownerGID: ownerGID, coord: coord, logger: logger}
}

func (s *server) listen() error {
	_ = os.Remove(s.path) // unlink stale
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: s.path, Net: "unix"})
	if err != nil {
		return err
	}
	s.ln = ln
	// Explicit 0660 root:<owner-gid> after bind (don't rely on umask). The uid
	// check remains the authoritative gate.
	if err := os.Chmod(s.path, 0o660); err != nil {
		return err
	}
	if err := os.Chown(s.path, 0, s.ownerGID); err != nil {
		return err
	}
	return nil
}

func (s *server) serve() {
	for {
		conn, err := s.ln.AcceptUnix()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return // clean shutdown (listener closed)
			}
			s.logger.Warn("accept failed", "err", err)
			continue
		}
		go s.handle(conn)
	}
}

func (s *server) handle(conn *net.UnixConn) {
	defer func() { _ = conn.Close() }()

	uid, err := peerUID(conn)
	if err != nil {
		s.logger.Warn("peercred check failed; dropping connection", "err", err)
		return
	}
	if uid != s.ownerUID {
		s.logger.Warn("rejecting connection from unexpected uid", "uid", uid, "want", s.ownerUID)
		return
	}

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 4096), maxLineBytes) // bound line length
	enc := json.NewEncoder(conn)
	for sc.Scan() {
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
		s.logger.Warn("connection read error (line too long?)", "err", err)
	}
}

func (s *server) close() {
	if s.ln != nil {
		_ = s.ln.Close() // unblocks the accept loop
	}
	_ = os.Remove(s.path)
}
