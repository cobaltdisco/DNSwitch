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
            Image(systemName: model.state?.enabled == true
                  ? "shield.lefthalf.filled"
                  : "shield.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
