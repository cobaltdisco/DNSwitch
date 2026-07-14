import Foundation
import ServiceManagement

/// Wraps SMAppService registration for the root engine daemon (docs/07 §1).
/// The daemon's plist ships inside the app bundle at
/// Contents/Library/LaunchDaemons/<plistName>; registering it asks the user to
/// approve the background item in System Settings › General › Login Items.
@MainActor
final class ServiceManager: ObservableObject {
    /// Must match the embedded plist's filename and its `Label`.
    static let plistName = "com.fx.dnswitch.engine.plist"

    @Published var status: SMAppService.Status
    @Published var lastError: String?
    @Published var busy = false

    private let service = SMAppService.daemon(plistName: ServiceManager.plistName)
    private var healed = false

    init() {
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    /// Self-heal on launch: if the daemon is already enabled, re-register once so
    /// a plist change from an app update actually propagates (Apple-recommended;
    /// register() is idempotent and prompt-free when already approved). First-time
    /// install stays an explicit, user-initiated action via the banner button.
    func healIfNeeded() {
        guard !healed else { return }
        healed = true
        if status == .enabled { register() }
    }

    /// Register (or re-register) the daemon. Idempotent; after a success the
    /// status is often `.requiresApproval` until the user toggles it on in Login
    /// Items. The SMAppService call is synchronous (XPC to `smd`), so it runs off
    /// the main actor to keep the menu responsive.
    func register() {
        run { try SMAppService.daemon(plistName: ServiceManager.plistName).register() }
    }

    func unregister() {
        run { try SMAppService.daemon(plistName: ServiceManager.plistName).unregister() }
    }

    /// Runs a throwing SMAppService op off the main actor, then refreshes status.
    /// `op` returns an optional error string (Sendable) so nothing non-Sendable
    /// crosses the actor boundary.
    private func run(_ op: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            let errText: String? = await Task.detached(priority: .userInitiated) {
                do { try op(); return nil }
                catch {
                    let ns = error as NSError
                    // `.notFound` usually means the app is translocated / outside
                    // /Applications — SMAppService can't resolve a stable path.
                    return "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
                }
            }.value
            lastError = errText
            refresh()
            busy = false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
