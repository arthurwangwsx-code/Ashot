import Foundation
import SwiftUI

extension Notification.Name {
    static let ashotLanguageChanged = Notification.Name("ashotLanguageChanged")
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    nonisolated static func resolvedCode(
        for rawValue: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        guard rawValue == AppLanguage.system.rawValue else {
            return rawValue == AppLanguage.simplifiedChinese.rawValue ? "zh-Hans" : "en"
        }

        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    nonisolated static func locale(for rawValue: String) -> Locale {
        Locale(identifier: resolvedCode(for: rawValue))
    }
}

/// Localizes AppKit strings using the same in-app language preference as SwiftUI.
enum L10n {
    nonisolated static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let preference = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        let languageCode = AppLanguage.resolvedCode(for: preference)
        let localizedBundle: Bundle

        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            localizedBundle = bundle
        } else {
            localizedBundle = .main
        }

        let format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: AppLanguage.locale(for: preference), arguments: arguments)
    }
}

/// Applies the selected language to SwiftUI views hosted from AppKit windows.
struct LocalizedRoot<Content: View>: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.locale, AppLanguage.locale(for: appLanguage))
    }
}
