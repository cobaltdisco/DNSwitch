import SwiftUI
import AppKit

/// One status read at launch, so the menu-bar icon is right before the panel has
/// ever been opened — SwiftUI doesn't build a MenuBarExtra's content until its
/// first open, so its onAppear is far too late for that. A single socket
/// roundtrip, no timer: polling only runs while the panel is open (AppModel).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            ServiceManager.shared.refresh()
            ServiceManager.shared.healIfNeeded()
            AppModel.shared.refresh()
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
            // Witch hat = encryption; solid+stars when on, line-art when off. Must
            // agree with the toggle, so it asks the same question: is anything
            // encrypting? The imagesets are template-rendered, so the menu bar owns
            // the colour (auto-inverts on a dark bar).
            // A named asset carries no VoiceOver description (unlike the old SF key),
            // so label it explicitly and reflect on/off in the value (Fable NIT-3).
            Image(encryptionActive(model, service) ? "MenuWitchOn" : "MenuWitchOff")
                .accessibilityLabel(Text("menu.title"))
                .accessibilityValue(Text(encryptionActive(model, service)
                    ? "status.encrypted" : "status.off"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(service)
        }
    }
}
