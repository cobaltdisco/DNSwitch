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

let providers: [ProviderInfo] = [
    .init(id: "google", name: "Google", subtitle: "8.8.8.8 · 无过滤",
          protocols: [.dot, .doh, .doh3], idField: nil),
    .init(id: "cloudflare", name: "Cloudflare", subtitle: "1.1.1.1 · 无过滤",
          protocols: [.dot, .doh, .doh3], idField: nil),
    .init(id: "nextdns", name: "NextDNS", subtitle: "个性化 · 需 Profile ID",
          protocols: [.dot, .doh, .doh3, .doq], idField: "Profile ID"),
    .init(id: "alidns", name: "阿里 AliDNS", subtitle: "公共，或填企业子域",
          protocols: [.dot, .doh, .doh3, .doq], idField: "企业子域（留空=公共）"),
]

func providerInfo(_ id: String) -> ProviderInfo? { providers.first { $0.id == id } }

// MARK: - Wire types (match engine/protocol.go)

struct EngineRequest: Encodable {
    let v = 1
    let cmd: String
    var provider: String?
    var proto: String?
    var id: String?
    var enabled: Bool?
    enum CodingKeys: String, CodingKey {
        case v, cmd, provider, proto = "protocol", id, enabled
    }
}

struct EngineState: Decodable, Equatable {
    let enabled: Bool
    let provider: String
    let proto: String
    let upstream: String
    let listening: Bool
    let pinned: Bool
    enum CodingKeys: String, CodingKey {
        case enabled, provider, proto = "protocol", upstream, listening, pinned
    }
}

struct EngineError: Decodable, Equatable { let code: String; let msg: String }

struct EngineResponse: Decodable {
    let v: Int
    let ok: Bool
    let state: EngineState?
    let error: EngineError?
}
