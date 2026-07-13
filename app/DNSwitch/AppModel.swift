import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var state: EngineState?
    @Published var connected = false
    @Published var lastError: String?

    // UI edit state (user-driven; seeded from the engine on first status).
    @Published var selectedProvider = "cloudflare"
    @Published var selectedProto: Proto = .doh
    @Published var nextdnsID = ""
    @Published var alidnsAcct = ""

    private let client = SocketClient(path: "/var/run/dnswitch.sock")
    private let queue = DispatchQueue(label: "dnswitch.socket")
    private var timer: Timer?
    private var seeded = false

    func onAppear() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Commands

    func refresh() { send(EngineRequest(cmd: "status")) }

    func setEnabled(_ on: Bool) {
        var r = EngineRequest(cmd: "set_enabled")
        r.enabled = on
        send(r)
    }

    /// Send a switch for the current UI selection, if it is complete.
    func applySwitch() {
        let pid = selectedProvider
        guard let info = providerInfo(pid) else { return }
        guard info.protocols.contains(selectedProto) else { return } // e.g. DoQ on Google
        var r = EngineRequest(cmd: "switch")
        r.provider = pid
        r.proto = selectedProto.rawValue
        if info.idField != nil {
            let id = pid == "nextdns" ? nextdnsID : alidnsAcct
            if pid == "nextdns" && id.isEmpty {
                lastError = "NextDNS 需要 Profile ID"
                return
            }
            r.id = id.isEmpty ? nil : id
        }
        send(r)
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
        if resp.ok, let st = resp.state {
            state = st
            lastError = nil
            if !seeded { // seed the selection from the engine only once
                seeded = true
                selectedProvider = st.provider
                if let p = Proto(rawValue: st.proto) { selectedProto = p }
            }
        } else if let e = resp.error {
            lastError = "\(e.code)：\(e.msg)"
        }
    }
}
