#if DEBUG
import AppKit
import ServiceManagement

/// Debug-only QA hook (docs/12 D1). Launched with `-QAMockEngine <socket>`, the
/// App talks to a mock engine listening at that path and takes the daemon's
/// service status from `<socket>.service` ("notRegistered", "requiresApproval",
/// "enabled" or "notFound") instead of asking SMAppService. In that mode the App
/// never calls SMAppService at all — no register, unregister, heal or login-item
/// change; such requests are only appended to `<socket>.ops` for the QA script
/// to check. QA runs it under its own bundle id (com.fx.dnswitch.qa).
///
/// None of this exists in a Release build; the release QA checks the binary for
/// it (P08).
enum QAMockEngine {
    static let socketPath: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-QAMockEngine"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    static var isActive: Bool { socketPath != nil }

    static var serviceStatus: SMAppService.Status {
        guard let p = socketPath,
              let s = try? String(contentsOfFile: p + ".service", encoding: .utf8) else { return .notRegistered }
        switch s.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "enabled": return .enabled
        case "requiresApproval": return .requiresApproval
        case "notFound": return .notFound
        default: return .notRegistered
        }
    }

    /// `-QAAppearance dark|light` pins the App's appearance for screenshots, so
    /// QA never has to change the system's.
    @MainActor static func applyAppearance() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-QAAppearance"), i + 1 < args.count else { return }
        NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
    }

    /// Records a request the App would have sent to SMAppService.
    static func record(_ op: String) {
        guard let p = socketPath else { return }
        // O_APPEND: records from the main actor and detached tasks never overwrite each other.
        let fd = open(p + ".ops", O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let line = Array((op + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
#endif
