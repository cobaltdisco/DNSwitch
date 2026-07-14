import Foundation
import SwiftUI

enum PrefKey {
    static let nextdnsID = "nextdnsID"
    static let nextdnsDevice = "nextdnsDevice"
    static let alidnsAcct = "alidnsAcct"
}

@MainActor
final class AppModel: ObservableObject {
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

    private let client = SocketClient(path: "/var/run/dnswitch.sock")
    private let queue = DispatchQueue(label: "dnswitch.socket")
    private var timer: Timer?
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

    /// Hook the poll timer can use to re-check things the engine can't tell us —
    /// namely the SMAppService status, which changes behind our back when the user
    /// flips DNSwitch off in Login Items › Allow in the Background (that stops the
    /// daemon, so we'd otherwise only see "engine went quiet"). Set once by the
    /// menu; only fires while disconnected, so we don't XPC to `smd` every 5s.
    var onPoll: (() -> Void)?

    func onAppear() {
        refresh()
        // S-1: MenuBarExtra fires onAppear on every panel open; create the poll
        // timer only once so opens don't multiply timers.
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.connected { self.onPoll?() }
                self.refresh()
            }
        }
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
                    self.lastError = String(localized: "error.badResponse")
                    done?()
                }
            }
        }
    }

    /// Lost the engine. `firstFailure` starts the grace period in which a restart
    /// still looks like a restart; past it the menu stops pretending.
    private func markDisconnected(stalledNow: Bool = false) {
        connected = false
        let since = firstFailure ?? Date()
        firstFailure = since
        if stalledNow || Date().timeIntervalSince(since) > 20 { stalled = true }
    }

    private func apply(_ resp: EngineResponse) {
        connected = true
        firstFailure = nil
        stalled = false
        guard resp.v == 1 else { // defensive: reject an unknown protocol version
            lastError = String(format: String(localized: "error.version"), resp.v)
            return
        }
        if resp.ok, let st = resp.state {
            state = st
            lastError = nil
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
            lastError = "\(e.code)：\(e.msg)"
        }
    }
}
