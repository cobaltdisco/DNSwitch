import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp — the "launch DNSwitch at login" login item.
/// Separate from ServiceManager on purpose: that one manages the root engine
/// daemon, this one only the unprivileged menu-bar app. Registering needs no
/// approval flow — macOS just posts a "login item added" notification and lists
/// the app in System Settings › General › Login Items, where the user can also
/// flip it behind our back (hence refresh() on every Settings appearance).
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published var enabled: Bool
    @Published var lastError: String?
    @Published var busy = false

    init() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    /// Guarded like ServiceManager.refresh: a @Published set fires
    /// objectWillChange even when the value is identical.
    func refresh() {
        let on = SMAppService.mainApp.status == .enabled
        if enabled != on { enabled = on }
    }

    /// Flip the login item. Optimistic: `enabled` follows the toggle immediately
    /// so the control doesn't fight the user's click; the refresh() after the
    /// SMAppService call snaps it back to reality if the call failed. The call is
    /// synchronous XPC to `smd`, so it runs off the main actor (same pattern as
    /// ServiceManager.run).
    func setEnabled(_ on: Bool) {
        guard !busy, on != enabled else { return }
        enabled = on
        busy = true
        Task {
            let errText: String? = await Task.detached(priority: .userInitiated) {
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    return nil
                } catch {
                    let ns = error as NSError
                    return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
                }
            }.value
            lastError = errText
            refresh()
            busy = false
        }
    }
}
