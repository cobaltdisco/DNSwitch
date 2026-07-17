import SwiftUI

/// The ⌘, settings window: per-provider config moved out of the menu. Binds to
/// the shared AppModel; edits persist and auto-apply (debounced) to the live
/// provider. Language is auto-detected from the system (no manual override).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager
    @State private var confirmRemove = false

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

            Section("settings.alidns.header") {
                TextField("settings.alidns.acct", text: $model.alidnsAcct,
                          prompt: Text(verbatim: "779231-xxxxxxxx"))
                Text("settings.alidns.hint").font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("settings.about.engineVersion") {
                    Text(verbatim: engineVersion).textSelection(.enabled)
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
