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
            // Key = encryption; locked/on vs slashed/off.
            Image(systemName: model.state?.enabled == true ? "key.fill" : "key.slash")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(service)
        }
    }
}
