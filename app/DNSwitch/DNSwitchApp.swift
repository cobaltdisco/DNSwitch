import SwiftUI

@main
struct DNSwitchApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var service = ServiceManager()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(service)
        } label: {
            // Key = encryption; locked/on vs slashed/off. Must agree with the
            // toggle, so it asks the same question: is anything encrypting?
            Image(systemName: encryptionActive(model, service) ? "key.fill" : "key.slash")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(service)
        }
    }
}
