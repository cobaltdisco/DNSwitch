import SwiftUI

/// The ⌘, settings window: per-provider config (moved out of the menu) plus the
/// app language. Binds to the shared AppModel so edits persist and re-apply live.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingLanguage = LanguageManager.current
    @State private var showRelaunch = false

    var body: some View {
        Form {
            Section("settings.nextdns.header") {
                TextField("settings.nextdns.profileID", text: $model.nextdnsID, prompt: Text(verbatim: "abc123"))
                    .onSubmit { model.configChanged(for: "nextdns") }
                TextField("settings.nextdns.device", text: $model.nextdnsDevice, prompt: Text("settings.nextdns.devicePrompt"))
                    .onSubmit { model.configChanged(for: "nextdns") }
                    .disabled(model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(nextdnsHint).font(.caption).foregroundStyle(.secondary)
            }

            Section("settings.alidns.header") {
                TextField("settings.alidns.acct", text: $model.alidnsAcct,
                          prompt: Text(verbatim: "779231-xxxxxxxx"))
                    .onSubmit { model.configChanged(for: "alidns") }
                Text("settings.alidns.hint").font(.caption).foregroundStyle(.secondary)
            }

            Section("settings.language.header") {
                Picker("settings.language.header", selection: $pendingLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .onChange(of: pendingLanguage) { newValue in
                    if newValue != LanguageManager.current { showRelaunch = true }
                }
                Text("settings.language.relaunchNote").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .alert("settings.language.relaunchTitle", isPresented: $showRelaunch) {
            Button("common.cancel", role: .cancel) { pendingLanguage = LanguageManager.current }
            Button("settings.language.relaunchNow") { LanguageManager.apply(pendingLanguage) }
        } message: {
            Text("settings.language.relaunchNote")
        }
    }

    private var nextdnsHint: LocalizedStringKey {
        model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty
            ? "settings.nextdns.emptyHint"
            : "settings.nextdns.setHint"
    }
}
