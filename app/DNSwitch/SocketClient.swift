import Darwin
import Foundation

// Minimal blocking unix-domain-socket client: one connect → send one NDJSON
// request line → read one response line → close. Per-command (matches how the
// engine handles `nc -U`). Call off the main thread.
struct SocketClient {
    let path: String

    enum Failure: Error, LocalizedError {
        case connect(String)
        case io(String)
        var errorDescription: String? {
            switch self {
            case .connect(let m): return "无法连接引擎：\(m)"
            case .io(let m): return "通信失败：\(m)"
            }
        }
    }

    func roundtrip(_ request: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw Failure.connect(errnoMsg()) }
        defer { close(fd) }

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
        }
        return resp
    }

    private func errnoMsg() -> String { String(cString: strerror(errno)) }
}
