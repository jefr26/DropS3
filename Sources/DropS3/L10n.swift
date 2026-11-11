import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, es, en
    var id: String { rawValue }
}

/// The app ships in Spanish and English. Strings are written inline as `t("español", "English")`.
enum L10n {
    private static let defaultsKey = "language"

    static var setting: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            spanish = resolve()
        }
    }

    static var spanish = resolve()

    /// Explicit choice, or the first of the user's preferred languages that is Spanish or English.
    private static func resolve() -> Bool {
        switch setting {
        case .es: return true
        case .en: return false
        case .system:
            for language in Locale.preferredLanguages {
                if language.hasPrefix("es") { return true }
                if language.hasPrefix("en") { return false }
            }
            return false
        }
    }
}

func t(_ es: @autoclosure () -> String, _ en: @autoclosure () -> String) -> String {
    L10n.spanish ? es() : en()
}
