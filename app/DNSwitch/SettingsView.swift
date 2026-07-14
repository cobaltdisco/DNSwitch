import SwiftUI

/// The ⌘, settings window: per-provider config moved out of the menu. Binds to
/// the shared AppModel; edits persist and auto-apply (debounced) to the live
/// provider. Language is auto-detected from the system (no manual override).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var nextdnsHint: LocalizedStringKey {
        model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty
            ? "settings.nextdns.emptyHint"
            : "settings.nextdns.setHint"
    }
}
