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
    let subtitle: String
    let protocols: Set<Proto> // DoQ absent for google/cloudflare
    let idField: String?      // nil = no id; else the field label
}

// subtitle holds a localization key, rendered via Text(LocalizedStringKey(...)).
let providers: [ProviderInfo] = [
    .init(id: "google", name: "Google", subtitle: "provider.sub.google",
          protocols: [.dot, .doh, .doh3], idField: nil),
    .init(id: "cloudflare", name: "Cloudflare", subtitle: "provider.sub.cloudflare",
          protocols: [.dot, .doh, .doh3], idField: nil),
    .init(id: "nextdns", name: "NextDNS", subtitle: "provider.sub.nextdns",
          protocols: [.dot, .doh, .doh3, .doq], idField: "Profile ID"),
    .init(id: "alidns", name: "AliDNS", subtitle: "provider.sub.alidns",
          protocols: [.dot, .doh, .doh3, .doq], idField: "acct"),
]

func providerInfo(_ id: String) -> ProviderInfo? { providers.first { $0.id == id } }

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
