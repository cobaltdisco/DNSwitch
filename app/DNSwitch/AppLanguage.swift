import Foundation
import AppKit

/// App display language. Default follows the system; the user can override it in
/// Settings. Overriding writes `AppleLanguages` and relaunches so the choice
/// takes effect (macOS resolves the bundle's localization at launch).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "settings.language.system")
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }

    /// Value written to `AppleLanguages`, or nil to clear the override (system).
    var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .zhHans: return ["zh-Hans"]
        case .en:     return ["en"]
        }
    }
}

enum LanguageManager {
    static let key = "appLanguage"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Persist the choice, apply it to `AppleLanguages`, and relaunch the app.
    static func apply(_ lang: AppLanguage) {
        let d = UserDefaults.standard
        d.set(lang.rawValue, forKey: key)
        if let langs = lang.appleLanguages {
            d.set(langs, forKey: "AppleLanguages")
        } else {
            d.removeObject(forKey: "AppleLanguages")
        }
        relaunch()
    }

    private static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
