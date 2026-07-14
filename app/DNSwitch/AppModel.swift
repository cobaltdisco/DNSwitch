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

    // UI edit state (user-driven; seeded from the engine on first status).
    @Published var selectedProvider = "cloudflare"
    @Published var selectedProto: Proto = .doh

    // Per-provider config, edited in Settings and persisted locally (the app is
    // the UI source of truth; the engine also persists them in state.json).
    @Published var nextdnsID = UserDefaults.standard.string(forKey: PrefKey.nextdnsID) ?? "" {
        didSet { UserDefaults.standard.set(nextdnsID, forKey: PrefKey.nextdnsID) }
    }
    @Published var nextdnsDevice = UserDefaults.standard.string(forKey: PrefKey.nextdnsDevice) ?? "" {
        didSet { UserDefaults.standard.set(nextdnsDevice, forKey: PrefKey.nextdnsDevice) }
    }
    @Published var alidnsAcct = UserDefaults.standard.string(forKey: PrefKey.alidnsAcct) ?? "" {
        didSet { UserDefaults.standard.set(alidnsAcct, forKey: PrefKey.alidnsAcct) }
    }

    private let client = SocketClient(path: "/var/run/dnswitch.sock")
    private let queue = DispatchQueue(label: "dnswitch.socket")
    private var timer: Timer?
    private var seeded = false

    func onAppear() {
        refresh()
        // S-1: MenuBarExtra fires onAppear on every panel open; create the poll
        // timer only once so opens don't multiply timers.
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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

    /// Re-apply the current selection after its config changed in Settings, so an
    /// edited Profile ID / subdomain takes effect immediately for the live provider.
    func configChanged(for provider: String) {
        if selectedProvider == provider { applySwitch() }
    }

    // MARK: - Transport

    private func send(_ req: EngineRequest) {
        guard let data = try? JSONEncoder().encode(req) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let respData = try self.client.roundtrip(data)
                let resp = try JSONDecoder().decode(EngineResponse.self, from: respData)
                Task { @MainActor in self.apply(resp) }
            } catch {
                Task { @MainActor in
                    self.connected = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ resp: EngineResponse) {
        connected = true
        guard resp.v == 1 else { // defensive: reject an unknown protocol version
            lastError = String(format: String(localized: "error.version"), resp.v)
            return
        }
        if resp.ok, let st = resp.state {
            state = st
            lastError = nil
            if !seeded { // seed the selection from the engine only once
                seeded = true
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
            }
        } else if let e = resp.error {
            lastError = "\(e.code)：\(e.msg)"
        }
    }
}
