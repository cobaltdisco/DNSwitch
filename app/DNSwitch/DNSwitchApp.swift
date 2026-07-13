import SwiftUI

@main
struct DNSwitchApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.state?.enabled == true
                  ? "shield.lefthalf.filled"
                  : "shield.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
