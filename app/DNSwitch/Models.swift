import Foundation

// UI-side mirror of the engine's provider/protocol table (docs/06 §6). The
// ENGINE is the authoritative validator; this only drives labels, DoQ greying,
// and which id field to show. Wire types must match engine/protocol.go.

enum Proto: String, CaseIterable, Identifiable {
    case dot, doh, doh3, doq
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dot: return "DoT"
        case .doh: return "DoH"
        case .doh3: return "DoH3"
        case .doq: return "DoQ"
        }
    }
}

struct ProviderInfo: Identifiable {
    let id: String            // "google" | "cloudflare" | "nextdns" | "alidns"
    let name: String
    let protocols: Set<Proto> // DoQ absent for google/cloudflare
    let takesID: Bool         // NextDNS Profile ID / AliDNS enterprise subdomain
}

let providers: [ProviderInfo] = [
    .init(id: "google", name: "Google", protocols: [.dot, .doh, .doh3], takesID: false),
    .init(id: "cloudflare", name: "Cloudflare", protocols: [.dot, .doh, .doh3], takesID: false),
    .init(id: "nextdns", name: "NextDNS", protocols: [.dot, .doh, .doh3, .doq], takesID: true),
    .init(id: "alidns", name: "AliDNS", protocols: [.dot, .doh, .doh3, .doq], takesID: true),
]

func providerInfo(_ id: String) -> ProviderInfo? { providers.first { $0.id == id } }

/// Is DNS actually encrypted right now? Drives both the menu-bar icon and the
/// toggle, which must not disagree.
///
/// `state.enabled` is only the last thing the engine told us, and it outlives the
/// engine. When launchd stops the daemon — approval revoked in Login Items ›
/// Allow in the Background, or the service removed — it exits cleanly and
/// restores the system DNS on the way out, so a remembered `enabled` becomes a
/// lie: nothing is encrypting anything. Report off.
///
/// A daemon that is merely restarting (KeepAlive) is different: it keeps its last
/// known state so the UI doesn't flicker, and it re-pins from state.json when it
/// comes back — which is also why the toggle turns itself back on once the
/// service is approved again (shutdown never persists enabled=false).
@MainActor
func encryptionActive(_ model: AppModel, _ service: ServiceManager) -> Bool {
    guard model.state?.enabled == true else { return false }
    if model.connected { return true }
    return service.isEnabled && !model.stalled // restarting, not gone
}

// MARK: - Wire types (match engine/protocol.go)

struct EngineRequest: Encodable {
    let v = 1
    let cmd: String
    var provider: String?
    var proto: String?
    var id: String?
    var device: String?
    var enabled: Bool?
    enum CodingKeys: String, CodingKey {
        case v, cmd, provider, proto = "protocol", id, device, enabled
    }
}

struct EngineState: Decodable, Equatable {
    let enabled: Bool
    let provider: String
    let proto: String
    let id: String?      // present for a profiled NextDNS / enterprise AliDNS
    let device: String?
    let upstream: String
    let listening: Bool
    let pinned: Bool
    enum CodingKeys: String, CodingKey {
        case enabled, provider, proto = "protocol", id, device, upstream, listening, pinned
    }
}

struct EngineError: Decodable, Equatable { let code: String; let msg: String }

struct EngineResponse: Decodable {
    let v: Int
    let ok: Bool
    let state: EngineState?
    let error: EngineError?
}
