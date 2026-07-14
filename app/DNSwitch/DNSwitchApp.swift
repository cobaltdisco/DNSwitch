import SwiftUI
import AppKit

/// Everything the app needs running before the user has ever opened the panel:
/// polling (so the menu-bar icon is honest at login) and the service self-heal.
/// SwiftUI only builds MenuBarExtra's content on first open, so its onAppear is
/// far too late for this.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            ServiceManager.shared.refresh()
            ServiceManager.shared.healIfNeeded()
            AppModel.shared.start(watching: ServiceManager.shared)
        }
    }
}

@main
struct DNSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var service = ServiceManager.shared

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
