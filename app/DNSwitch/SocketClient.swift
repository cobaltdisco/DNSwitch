import Darwin
import Foundation

// Minimal blocking unix-domain-socket client: one connect → send one NDJSON
// request line → read one response line → close. Per-command (matches how the
// engine handles `nc -U`). Call off the main thread.
struct SocketClient {
    let path: String

    // Not localized: transport failures never reach the UI (AppModel just marks
    // itself disconnected — the menu shows the install button instead). These
    // strings exist for logging/debugging.
    enum Failure: Error, LocalizedError {
        case connect(String)
        case io(String)
        var errorDescription: String? {
            switch self {
            case .connect(let m): return "connect: \(m)"
            case .io(let m):      return "io: \(m)"
            }
        }
    }

    func roundtrip(_ request: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw Failure.connect(errnoMsg()) }
        defer { close(fd) }

        // S-2: bound blocking read/write so one slow roundtrip can't stall the
        // serial socket queue (and freeze subsequent user taps).
        var tv = timeval(tv_sec: 8, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Writing to a peer that already closed (an auth reject races our write)
        // raises SIGPIPE, whose default disposition kills the app. Turn it into an
        // EPIPE we can throw (Fable NIT-1, related hazard).
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = path.utf8CString // includes trailing NUL
        if cpath.count > MemoryLayout.size(ofValue: addr.sun_path) {
            throw Failure.connect("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            cpath.withUnsafeBytes { src in dst.copyMemory(from: src) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, size)
            }
        }
        if rc != 0 { throw Failure.connect(errnoMsg()) }

        var payload = request
        payload.append(0x0A)
        try payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { throw Failure.io(errnoMsg()) }
                off += n
            }
        }

        var resp = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw Failure.io(errnoMsg()) }
            if n == 0 { break } // EOF
            resp.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
            // A status reply is under 1 KB. A peer that streams data without
            // ever sending the newline would otherwise grow resp without bound
            // (and, since each read() lands inside its own 8s window, keep the
            // roundtrip alive indefinitely). Requires a wedged or hostile
            // daemon — cheap insurance either way.
            if resp.count > 1_000_000 { throw Failure.io("reply too large") }
        }
        // The engine's auth rejects (owner not known yet at login, uid mismatch,
        // signature gate) close the connection without writing a byte. That's a
        // transport-level "no", not a malformed reply — without this, an empty
        // Data() would fail to decode and be misreported as version skew, latching
        // the "reinstall the service" UI (Fable NIT-1).
        if resp.isEmpty { throw Failure.io("empty reply") }
        return resp
    }

    private func errnoMsg() -> String { String(cString: strerror(errno)) }
}
