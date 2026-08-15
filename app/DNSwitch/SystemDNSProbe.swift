import Foundation

/// Reads the system's DNS settings directly, without asking the engine.
///
/// Uninstalling is the one moment where "the engine says it restored your DNS"
/// is not good enough: if that is wrong, the daemon is about to be unregistered
/// and there is nothing left to fix it. Reading the real values costs about
/// 120ms, needs no privileges (these are read-only `networksetup` queries; the
/// app is deliberately not sandboxed, G4), and keeps working when the engine is
/// wedged or gone — which is exactly when its self-report would be least
/// trustworthy.
///
/// Advisory, not authoritative: someone running their own loopback resolver will
/// look "still pinned" to this. That is why the check gates a warning the user
/// can override, never a hard refusal.
enum SystemDNSProbe {
    private static let bin = "/usr/sbin/networksetup"

    /// Network services whose DNS still points at a loopback address, i.e. still
    /// at us. Empty means the machine looks clean. Blocking; call off the main
    /// actor.
    static func pinnedServices() -> [String] {
        guard let listing = run(["-listallnetworkservices"]) else { return [] }
        var pinned: [String] = []
        for line in listing.split(separator: "\n").dropFirst() { // first line is the legend
            let name = String(line)
            // "*" marks a disabled service; we never pinned those.
            if name.isEmpty || name.hasPrefix("*") { continue }
            guard let out = run(["-getdnsservers", name]) else { continue }
            if isLoopbackListing(out) { pinned.append(name) }
        }
        return pinned
    }

    /// True when every address in the listing is a loopback one. "There aren't
    /// any DNS Servers set on X." parses as no addresses, which is not loopback.
    private static func isLoopbackListing(_ out: String) -> Bool {
        var sawAddress = false
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let ip = IPv4OrV6(line) else { continue } // prose, e.g. the DHCP message
            sawAddress = true
            if !ip.isLoopback { return false }
        }
        return sawAddress
    }

    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read before waiting: networksetup's output is far under the pipe buffer,
        // but reading first is the habit that does not deadlock when it isn't.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// Minimal address parse: enough to tell 127.0.0.1 / ::1 from a real resolver,
/// without pulling in Network.framework for four lines.
private struct IPv4OrV6 {
    let isLoopback: Bool

    init?(_ s: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            isLoopback = (UInt32(bigEndian: v4.s_addr) >> 24) == 127
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            var loopback = in6addr_loopback
            isLoopback = withUnsafeBytes(of: &v6) { a in
                withUnsafeBytes(of: &loopback) { b in a.elementsEqual(b) }
            }
            return
        }
        return nil
    }
}
