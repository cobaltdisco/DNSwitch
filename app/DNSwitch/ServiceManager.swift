import Foundation
import ServiceManagement

/// Wraps SMAppService registration for the root engine daemon (docs/07 §1).
/// The daemon's plist ships inside the app bundle at
/// Contents/Library/LaunchDaemons/<plistName>; registering it asks the user to
/// approve the background item in System Settings › General › Login Items.
@MainActor
final class ServiceManager: ObservableObject {
    static let shared = ServiceManager()

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

    /// Guarded: a @Published set fires objectWillChange even when the value is
    /// identical, and this runs on every poll tick while the panel is open.
    func refresh() {
        let s = service.status
        if status != s { status = s }
    }

    /// Uninstall: turn encryption off first — and wait for the engine to confirm,
    /// so the system DNS is restored over the live socket rather than by the
    /// SIGTERM path — then unregister. `busy` covers the whole span so the button
    /// can't be fired twice mid-flight (Fable NIT-4).
    func removeService(disabling model: AppModel) {
        guard !busy else { return }
        busy = true
        model.disableThen { [weak self] in
            guard let self else { return }
            self.busy = false // hand off to run()'s own busy, same runloop turn
            self.unregister()
        }
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
    /// the main actor to keep the menu responsive. `done` fires once the status has
    /// been refreshed — the caller uses it to re-poll the engine immediately
    /// instead of waiting out the 5s timer (Fable N5).
    func register(_ done: (() -> Void)? = nil) {
        run({ try SMAppService.daemon(plistName: ServiceManager.plistName).register() }, done)
    }

    func unregister() {
        run({ try SMAppService.daemon(plistName: ServiceManager.plistName).unregister() })
    }

    /// Runs a throwing SMAppService op off the main actor, then refreshes status.
    /// `op` returns an optional error string (Sendable) so nothing non-Sendable
    /// crosses the actor boundary.
    private func run(_ op: @escaping () throws -> Void, _ done: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            let errText: String? = await Task.detached(priority: .userInitiated) {
                do { try op(); return nil }
                catch {
                    let ns = error as NSError
                    // `.notFound` usually means the app is translocated / outside
                    // /Applications — SMAppService can't resolve a stable path.
                    return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
                }
            }.value
            lastError = errText
            refresh()
            // Landing in .requiresApproval is the normal first-install outcome —
            // register() throws "Operation not permitted" on the way there on some
            // macOS versions. The button already says "Approve in System Settings";
            // a red error next to it would just be noise (Fable N1).
            if status == .requiresApproval {
                lastError = nil
            } else if let e = lastError, status == .notFound {
                // The raw NSError never says what actually went wrong: SMAppService
                // can't resolve the daemon because the app is translocated / not in
                // /Applications. Say the thing the user can act on (Fable NIT-3).
                lastError = e + "\n" + String(localized: "service.notFound.hint")
            }
            busy = false
            done?()
        }
    }

    func openLoginItemsSettings() {
        lastError = nil // don't leave a stale register error next to the Approve button
        SMAppService.openSystemSettingsLoginItems()
    }
}
