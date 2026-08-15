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

/// AliDNS ships hidden: DNSwitch is aimed at users outside mainland China, where
/// it is noise. This is a UI affordance ONLY — the engine keeps validating and
/// serving alidns exactly as before, so a revealed selection works and a
/// state.json that already names alidns survives an update untouched.
///
/// Revealed by the Settings easter egg (`SettingsView.eggDoubleClick`), remembered
/// in UserDefaults.
///
/// The `inUse` clause is the safety valve: a provider that is currently selected
/// or actually running is ALWAYS listed. Without it, updating while AliDNS is
/// active would drop the running provider off the menu — no radio button lit, no
/// way to switch off it, and a Settings pane with no field for the subdomain the
/// engine is still using.
@MainActor
func aliDNSInUse(_ model: AppModel) -> Bool {
    model.state?.provider == "alidns" || model.selectedProvider == "alidns"
}

@MainActor
func aliDNSVisible(_ model: AppModel) -> Bool {
    model.showAliDNS || aliDNSInUse(model)
}

@MainActor
func visibleProviders(_ model: AppModel) -> [ProviderInfo] {
    providers.filter { $0.id != "alidns" || aliDNSVisible(model) }
}

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

/// "<marketing> (<build>)", e.g. "0.13 (13)" — CFBundleShortVersionString is what
/// a user reads as "the version"; CFBundleVersion distinguishes rebuilds of the
/// same one. The engine's `engineBuildVersion()` mirrors this format exactly, so
/// the two strings are directly comparable. Not localized (it's an identifier).
func appBuildVersion() -> String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return build.isEmpty || build == short ? short : "\(short) (\(build))"
}

/// The engine the daemon is running, when it isn't the one this app shipped with.
///
/// Replacing the app bundle does NOT relaunch the root daemon — launchd keeps the
/// running one alive until someone kickstarts it, so after an update the new app
/// happily drives the OLD engine. That's invisible without this check, and on a
/// release whose whole point is an engine fix it means the fix isn't in effect.
/// nil when there's nothing to say: no engine reply yet, or an engine too old to
/// report a version (pre-0.3), which we can't distinguish from a match anyway.
@MainActor
func engineVersionSkew(_ model: AppModel) -> String? {
    guard let engine = model.state?.engineVersion, !engine.isEmpty else { return nil }
    let app = appBuildVersion()
    guard app != "?", engine != app else { return nil }
    return engine
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
    let engineVersion: String?   // daemon build version, e.g. "0.3 (3)"
    let dnsproxyVersion: String? // embedded AdGuard dnsproxy, e.g. "v0.83.0"
    /// A disable left the original DNS not fully restored. Optional because the
    /// engine omits it when false — and because the engine answering right after
    /// an update is the PREVIOUS one, which never sends the key at all. Declared
    /// non-optional, that would be a decode failure on every poll for every user
    /// until they relaunched the daemon, i.e. a permanently stalled menu.
    let restoreOwed: Bool?
    enum CodingKeys: String, CodingKey {
        case enabled, provider, proto = "protocol", id, device, upstream, listening, pinned
        case engineVersion, dnsproxyVersion, restoreOwed
    }
}

struct EngineError: Decodable, Equatable { let code: String; let msg: String }

struct EngineResponse: Decodable {
    let v: Int
    let ok: Bool
    let state: EngineState?
    let error: EngineError?
}
