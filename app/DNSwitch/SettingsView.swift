import SwiftUI
import AppKit

/// The ⌘, settings window: per-provider config moved out of the menu. Binds to
/// the shared AppModel; edits persist and auto-apply (debounced) to the live
/// provider. Language is auto-detected from the system (no manual override).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager
    @State private var confirmRemove = false

    // MARK: - AliDNS easter egg
    //
    // AliDNS ships hidden (aliDNSVisible). Two consecutive double-clicks on the
    // "Engine" label bring it out; once it's out, one more puts it away.
    //
    // "Consecutive" is what `eggWindow` enforces: without it every stray
    // double-click would accumulate forever, and a user who double-clicked the
    // label once today and once next week would unlock it by accident and have no
    // idea why a new provider appeared.
    private static let eggWindow: TimeInterval = 2
    @State private var eggTaps = 0
    @State private var eggLast = Date.distantPast

    var body: some View {
        Form {
            Section("settings.nextdns.header") {
                TextField("settings.nextdns.profileID", text: $model.nextdnsID,
                          prompt: Text(verbatim: "abc123"))
                TextField("settings.nextdns.device", text: $model.nextdnsDevice,
                          prompt: Text("settings.nextdns.devicePrompt"))
                    .disabled(model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(nextdnsHint).font(.caption).foregroundStyle(.secondary)
            }

            // Only once the egg is unlocked — or AliDNS is what's actually running,
            // in which case its subdomain must stay editable.
            if aliDNSVisible(model) {
                Section("settings.alidns.header") {
                    TextField("settings.alidns.acct", text: $model.alidnsAcct,
                              prompt: Text(verbatim: "779231-xxxxxxxx"))
                    Text("settings.alidns.hint").font(.caption).foregroundStyle(.secondary)
                }
            }

            // Deleting the app does NOT remove the root daemon — launchd keeps the
            // registration, so this is the only in-app way out. It's also the safe
            // order: turn encryption off (system DNS restored over the live socket)
            // and only then unregister.
            Section("settings.service.header") {
                HStack {
                    Text("settings.service.remove")
                    Spacer()
                    if service.busy { ProgressView().controlSize(.small) }
                    Button("settings.service.removeButton", role: .destructive) {
                        confirmRemove = true
                    }
                    .disabled(service.busy || service.status == .notRegistered)
                }
                Text("settings.service.hint").font(.caption).foregroundStyle(.secondary)
                if let e = service.lastError {
                    Text(e).font(.caption2).foregroundStyle(.red)
                }
            }

            // Versions, so a running build is identifiable at a glance: the app
            // (from its bundle) plus the engine daemon's build version and the
            // AdGuard dnsproxy it embeds (both reported over the socket — "—" when
            // the engine isn't reachable).
            Section("settings.about.header") {
                LabeledContent("settings.about.appVersion") {
                    Text(verbatim: appVersion).textSelection(.enabled)
                }
                LabeledContent {
                    Text(verbatim: engineVersion).textSelection(.enabled)
                } label: {
                    // Carries the AliDNS easter egg (see eggDoubleClick). Nothing
                    // about the label hints at it — that's the point — so it must
                    // stay a plain, correct-looking row.
                    Text("settings.about.engineVersion")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: eggDoubleClick)
                }
                LabeledContent("settings.about.dnsproxyVersion") {
                    Text(verbatim: dnsproxyVersion).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // Poll runs only while the menu panel is open, so state can be stale here;
        // refresh both the service status and the engine state (which carries the
        // versions) when the settings window appears.
        .onAppear { service.refresh(); model.refresh() }
        .confirmationDialog("settings.service.confirmTitle", isPresented: $confirmRemove) {
            Button("settings.service.removeButton", role: .destructive) {
                service.removeService(disabling: model)
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.service.confirmMsg")
        }
    }

    private func eggDoubleClick() {
        let now = Date()
        eggTaps = now.timeIntervalSince(eggLast) < Self.eggWindow ? eggTaps + 1 : 1
        eggLast = now
        if model.showAliDNS {          // already out: one double-click puts it away
            setEgg(false)
        } else if eggTaps >= 2 {
            setEgg(true)
        }
    }

    private func setEgg(_ on: Bool) {
        eggTaps = 0
        withAnimation { model.showAliDNS = on }
        // A section silently appearing or vanishing is invisible to VoiceOver, and
        // the gesture is undiscoverable by design, so say what happened (same
        // reasoning as the toggle-refusal announcement in MenuView, Fable B3).
        // Report what is actually true, not what was requested: turning the egg off
        // while AliDNS is the running provider leaves it on screen (aliDNSVisible).
        let shown = aliDNSVisible(model)
        let msg = String(localized: shown ? "egg.alidns.shown" : "egg.alidns.hidden")
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: msg,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private var nextdnsHint: LocalizedStringKey {
        model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty
            ? "settings.nextdns.emptyHint"
            : "settings.nextdns.setHint"
    }

    /// "<marketing> (<build>)", e.g. "0.2 (2)" — CFBundleShortVersionString is
    /// what a user reads as "the version"; CFBundleVersion distinguishes rebuilds
    /// of the same version. Not localized (it's an identifier).
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    // From the engine's status; "—" when it isn't reachable (or an old engine
    // that predates these fields, which omits them).
    private var engineVersion: String { orDash(model.state?.engineVersion) }
    private var dnsproxyVersion: String { orDash(model.state?.dnsproxyVersion) }
    private func orDash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s
    }
}
