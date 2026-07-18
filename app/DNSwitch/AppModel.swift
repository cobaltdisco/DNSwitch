import Foundation
import SwiftUI

enum PrefKey {
    static let nextdnsID = "nextdnsID"
    static let nextdnsDevice = "nextdnsDevice"
    static let alidnsAcct = "alidnsAcct"
    static let showAliDNS = "showAliDNS"
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var state: EngineState?
    @Published var connected = false
    @Published var lastError: String?
    /// The engine has been unreachable long enough that this isn't just a restart
    /// (or it answered with something we can't decode). The menu escalates from a
    /// spinner to a repair button (Fable B2).
    @Published var stalled = false

    // UI edit state (user-driven; seeded from the engine on first status).
    @Published var selectedProvider = "cloudflare"
    @Published var selectedProto: Proto = .doh

    // Per-provider config, edited in Settings and persisted locally (the app is
    // the UI source of truth; the engine also persists them in state.json).
    @Published var nextdnsID = UserDefaults.standard.string(forKey: PrefKey.nextdnsID) ?? "" {
        didSet {
            UserDefaults.standard.set(nextdnsID, forKey: PrefKey.nextdnsID)
            scheduleConfigApply(for: "nextdns")
        }
    }
    @Published var nextdnsDevice = UserDefaults.standard.string(forKey: PrefKey.nextdnsDevice) ?? "" {
        didSet {
            UserDefaults.standard.set(nextdnsDevice, forKey: PrefKey.nextdnsDevice)
            scheduleConfigApply(for: "nextdns")
        }
    }
    @Published var alidnsAcct = UserDefaults.standard.string(forKey: PrefKey.alidnsAcct) ?? "" {
        didSet {
            UserDefaults.standard.set(alidnsAcct, forKey: PrefKey.alidnsAcct)
            scheduleConfigApply(for: "alidns")
        }
    }

    /// Is the AliDNS easter egg unlocked? Absent key => false => hidden, which is
    /// the shipping default (see `aliDNSVisible`). Not a secret and not security —
    /// just a provider most users of this app have no use for.
    @Published var showAliDNS = UserDefaults.standard.bool(forKey: PrefKey.showAliDNS) {
        didSet { UserDefaults.standard.set(showAliDNS, forKey: PrefKey.showAliDNS) }
    }

    private let client = SocketClient(path: "/var/run/dnswitch.sock")
    private let queue = DispatchQueue(label: "dnswitch.socket")
    private var timer: Timer? // lives only while the panel is open
    private var seeded = false
    private var seeding = false // suppress config auto-apply while seeding from status
    private var applyDebounce: Task<Void, Never>?
    private var firstFailure: Date? // when the engine first went quiet (stall clock)

    init() {
        // One-time migration: an earlier build's in-app language switch (removed)
        // could have written an AppleLanguages override. Scrub it ONCE — doing it
        // every launch would also wipe macOS's own per-app Language setting
        // (System Settings › Language & Region), which writes the same key (Fable #2).
        let d = UserDefaults.standard
        if !d.bool(forKey: "didClearLegacyLanguage") {
            d.removeObject(forKey: "AppleLanguages")
            d.removeObject(forKey: "appLanguage")
            d.set(true, forKey: "didClearLegacyLanguage")
        }
    }

    /// Re-checks what the engine can't tell us: the SMAppService status, which
    /// changes behind our back when the user flips DNSwitch off in Login Items ›
    /// Allow in the Background (that stops the daemon, so we'd otherwise only see
    /// "the engine went quiet"). Only runs while disconnected — no XPC to `smd`
    /// on the happy path.
    private var onPoll: (() -> Void)?

    /// Poll only while the panel is open (S-1: MenuBarExtra re-runs onAppear on
    /// every open, so this is idempotent). Deliberately NOT a background timer: an
    /// idle menu-bar app should cost nothing, and a 5s tick with an XPC status
    /// check measured ~0.4% of a core. The trade-off is accepted and known — with
    /// the panel closed the icon can lag reality (engine crashed, service switched
    /// off in Login Items) until the next open or an app relaunch.
    func beginLiveUpdates(watching service: ServiceManager) {
        onPoll = { [weak service] in service?.refresh() }
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.connected { self.onPoll?() }
                self.refresh()
            }
        }
    }

    func endLiveUpdates() {
        timer?.invalidate()
        timer = nil
    }

    /// Select a provider, reconciling the protocol to one it supports (S-3):
    /// e.g. switching from a DoQ provider to Google (no DoQ) falls back to DoH.
    func selectProvider(_ pid: String) {
        selectedProvider = pid
        if let info = providerInfo(pid), !info.protocols.contains(selectedProto) {
            selectedProto = .doh // every provider supports DoH
        }
    }

    // MARK: - Commands

    func refresh() { send(EngineRequest(cmd: "status")) }

    func setEnabled(_ on: Bool) {
        var r = EngineRequest(cmd: "set_enabled")
        r.enabled = on
        send(r)
    }

    /// Turn encryption off and call back once the engine has answered, i.e. once
    /// the system DNS is restored. Used before tearing the daemon down, so the
    /// restore happens over the live socket instead of relying on the SIGTERM
    /// path. No-op (still calls back) if there's nothing to turn off.
    func disableThen(_ done: @escaping () -> Void) {
        guard connected, state?.enabled == true else { done(); return }
        var r = EngineRequest(cmd: "set_enabled")
        r.enabled = false
        send(r, then: done)
    }

    /// Send a switch for the current UI selection. NextDNS and AliDNS both take an
    /// optional id: empty NextDNS ID -> free config-less resolver; empty AliDNS
    /// subdomain -> public resolver (the engine validates either way).
    func applySwitch() {
        let pid = selectedProvider
        guard let info = providerInfo(pid) else { return }
        guard info.protocols.contains(selectedProto) else { return } // e.g. DoQ on Google
        var r = EngineRequest(cmd: "switch")
        r.provider = pid
        r.proto = selectedProto.rawValue
        switch pid {
        case "nextdns":
            let id = nextdnsID.trimmingCharacters(in: .whitespaces)
            r.id = id.isEmpty ? nil : id
            if !id.isEmpty { // device reporting only applies with a profile
                let dev = nextdnsDevice.trimmingCharacters(in: .whitespaces)
                r.device = dev.isEmpty ? nil : dev
            }
        case "alidns":
            let acct = alidnsAcct.trimmingCharacters(in: .whitespaces)
            r.id = acct.isEmpty ? nil : acct
        default:
            break
        }
        send(r)
    }

    /// After a config field changes (Settings edit), re-apply the switch shortly
    /// once typing settles — so an edited Profile ID / subdomain takes effect
    /// without needing a manual provider/protocol switch. Debounced so it doesn't
    /// fire per keystroke; only for the currently-selected provider.
    private func scheduleConfigApply(for provider: String) {
        guard !seeding, selectedProvider == provider else { return }
        applyDebounce?.cancel()
        applyDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Re-check after the sleep: the user may have switched providers in
            // the meantime, in which case this edit no longer applies (Fable #1).
            guard let self, !Task.isCancelled, self.selectedProvider == provider else { return }
            self.applySwitch()
        }
    }

    // MARK: - Transport

    /// `then` runs on the main actor once the roundtrip settles — success or not,
    /// so a caller waiting on it can't hang.
    private func send(_ req: EngineRequest, then done: (() -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(req) else { done?(); return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let respData = try self.client.roundtrip(data)
                let resp = try JSONDecoder().decode(EngineResponse.self, from: respData)
                Task { @MainActor in
                    self.apply(resp)
                    done?()
                }
            } catch is SocketClient.Failure {
                // Transport failure = the daemon isn't there (not installed yet,
                // restarting, being kickstarted). Not an error to shout about: the
                // menu already shows the install button / spinner, and a toggle
                // press explains itself. lastError stays reserved for errors the
                // engine actually returns (bad id, unsupported protocol, …).
                Task { @MainActor in
                    self.markDisconnected()
                    done?()
                }
            } catch {
                // The engine answered with something we can't decode — app/daemon
                // version skew. Silence would strand the user on the spinner, so
                // go straight to the stalled UI (Fable N2).
                NSLog("DNSwitch: undecodable engine response: \(error)")
                Task { @MainActor in
                    self.markDisconnected(stalledNow: true)
                    let msg = String(localized: "error.badResponse")
                    if self.lastError != msg { self.lastError = msg } // guarded: repeats every poll tick while skewed
                    done?()
                }
            }
        }
    }

    /// Lost the engine. `firstFailure` starts the grace period in which a restart
    /// still looks like a restart; past it the menu stops pretending.
    ///
    /// Every assignment here and in `apply` is guarded: a @Published set fires
    /// objectWillChange even when the value is identical, and an unguarded poll
    /// would re-render the whole menu (and the menu-bar icon) every 5s for nothing.
    private func markDisconnected(stalledNow: Bool = false) {
        if connected { connected = false }
        let since = firstFailure ?? Date()
        firstFailure = since
        let gone = stalledNow || Date().timeIntervalSince(since) > 20
        if gone, !stalled { stalled = true }
    }

    private func apply(_ resp: EngineResponse) {
        if !connected { connected = true }
        firstFailure = nil
        if stalled { stalled = false }
        guard resp.v == 1 else { // defensive: reject an unknown protocol version
            let msg = String(format: String(localized: "error.version"), resp.v)
            if lastError != msg { lastError = msg } // guarded: repeats every poll tick
            return
        }
        if resp.ok, let st = resp.state {
            if state != st { state = st }
            if lastError != nil { lastError = nil }
            if !seeded { // seed the selection from the engine only once
                seeded = true
                seeding = true // don't let the field didSets trigger a re-apply
                selectedProvider = st.provider
                if let p = Proto(rawValue: st.proto) { selectedProto = p }
                // Seed per-provider config from a boot-restored profile, but only
                // if we don't already have it locally — otherwise the app would
                // mislabel a profiled engine state as config-less (Fable #1).
                if let id = st.id, !id.isEmpty {
                    switch st.provider {
                    case "nextdns":
                        if nextdnsID.isEmpty { nextdnsID = id }
                        if nextdnsDevice.isEmpty, let d = st.device { nextdnsDevice = d }
                    case "alidns":
                        if alidnsAcct.isEmpty { alidnsAcct = id }
                    default: break
                    }
                }
                seeding = false
            }
        } else if let e = resp.error {
            let msg = "\(e.code): \(e.msg)"
            if lastError != msg { lastError = msg } // guarded: a failing switch is re-polled
        }
    }
}
