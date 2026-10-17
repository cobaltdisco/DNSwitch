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

    /// Services still pointing at us when the uninstall had to stop. Non-nil
    /// means the "Try again" block is showing. Deliberately NOT `lastError`:
    /// `run()` overwrites that on every SMAppService call.
    @Published var restoreWarning: [String]?
    /// Uninstall is mid-flight. Separate from `busy` because the retry block
    /// waits for a human: `busy` must be false while it is on screen or it would
    /// also disable Install and Reinstall in the menu.
    @Published var uninstalling = false

    /// Uninstall: turn encryption off, make sure the machine came back, and only
    /// then unregister. This is the last moment anything can fix a bad restore —
    /// afterwards the daemon is gone.
    func removeService(disabling model: AppModel) {
        guard !uninstalling else { return }
        uninstalling = true
        busy = true
        restoreWarning = nil
        model.disableThen { [weak self] outcome in
            self?.finishOrStop(outcome, confirmed: engineReportsRestore(model))
        }
    }

    /// "Try again": the whole uninstall once more, minus the confirmation.
    func retryRestore(disabling model: AppModel) {
        guard uninstalling, !busy else { return }
        busy = true
        model.disableThen { [weak self] outcome in
            self?.finishOrStop(outcome, confirmed: engineReportsRestore(model))
        }
    }

    /// Two independent ways to know the machine is clean; either one is enough.
    ///
    /// 1. The engine confirms it restored every service it changed — and is new
    ///    enough (0.15+) that "nothing owed" is a real report. It keeps its
    ///    own record (the snapshot) and read-back-verifies each restore, so a
    ///    `.restored` reply is exact — and, unlike the probe, it is not fooled
    ///    by some other local DNS tool (dnsmasq, another DNS app) that also
    ///    points the system at 127.0.0.1. Trusting it is what lets the uninstall
    ///    finish for those users without an "uninstall anyway" button.
    /// 2. The engine could not confirm (unreachable, or still owes a restore):
    ///    read the system's DNS directly. Nothing on loopback = clean.
    ///
    /// Only when both fail does the uninstall stop and offer "Try again". If the
    /// engine itself is broken, the shown advice — reinstall it from the menu,
    /// then uninstall again — works because the engine repairs any leftover pin
    /// when it starts (reconcileOnStartup).
    private func finishOrStop(_ outcome: AppModel.DisableOutcome, confirmed: Bool) {
        if outcome == .restored && confirmed {
            restoreWarning = nil
            finishUninstall()
            return
        }
        Task {
            let pinned = await Task.detached(priority: .userInitiated) {
                SystemDNSProbe.pinnedServices()
            }.value
            if pinned.isEmpty {
                self.restoreWarning = nil
                self.finishUninstall()
            } else {
                // busy goes false so the rest of the UI stays usable while the
                // block is on screen.
                self.restoreWarning = pinned
                self.busy = false
            }
        }
    }

    /// User closed the window or backed out. Nothing was unregistered.
    func cancelUninstall() {
        uninstalling = false
        restoreWarning = nil
        busy = false
    }

    private func finishUninstall() {
        perform { try SMAppService.daemon(plistName: ServiceManager.plistName).unregister() } then: { [weak self] in
            self?.uninstalling = false
            self?.restoreWarning = nil
        }
    }

    /// Self-heal on launch: if the daemon is already enabled, re-register once —
    /// prompt-free when already approved, and it re-points launchd at the current
    /// bundle after the app moves. First-time install stays an explicit,
    /// user-initiated action via the banner button.
    ///
    /// It does NOT propagate plist changes, despite what this comment used to
    /// claim: measured on macOS 26, after upgrading the bundle `launchctl print`
    /// still reported the previous bundle's version and none of the new keys,
    /// even after this ran. register() is idempotent in the sense of "no-op",
    /// not "re-read"; only unregister+register refreshes the cached job, at the
    /// cost of a re-approval. Anything the engine needs from its plist must
    /// therefore also work when launchd is running the OLD one (see
    /// engine/logperm_darwin.go).
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
        perform(op, then: done)
    }

    /// The body of `run` without its guard, for callers that already own `busy`
    /// (the uninstall flow holds it across a socket round trip and a probe, so
    /// it cannot go through a guard that would reject its own second step).
    /// Every exit path clears `busy` — a latched one would disable Uninstall,
    /// Install and Reinstall all at once.
    private func perform(_ op: @escaping () throws -> Void, then done: (() -> Void)? = nil) {
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
