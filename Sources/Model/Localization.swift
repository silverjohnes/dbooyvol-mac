import Foundation

/// Languages offered in Settings. The raw value is the `.lproj` code used for
/// `AppleLanguages`, so the standard macOS localization machinery picks the
/// right `Localizable.strings` at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case spanish = "es"
    case portuguese = "pt"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case turkish = "tr"
    case russian = "ru"
    case ukrainian = "uk"
    case arabic = "ar"
    case hindi = "hi"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case indonesian = "id"
    case vietnamese = "vi"
    case thai = "th"
    case swedish = "sv"
    case czech = "cs"

    var id: String { rawValue }

    /// Shown in the picker in the language itself, like macOS does.
    var nativeName: String {
        switch self {
        case .system: return "Системный"
        case .english: return "English"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .dutch: return "Nederlands"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        case .russian: return "Русский"
        case .ukrainian: return "Українська"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .indonesian: return "Bahasa Indonesia"
        case .vietnamese: return "Tiếng Việt"
        case .thai: return "ไทย"
        case .swedish: return "Svenska"
        case .czech: return "Čeština"
        }
    }

    static let storedKey = "appLanguage"

    static var selected: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: storedKey) ?? ""
        return AppLanguage(rawValue: raw) ?? .system
    }

    /// Persists the choice and the `AppleLanguages` override used by AppKit and
    /// SwiftUI for their standard strings.
    static func store(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: storedKey)
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    /// Called from `main.swift` before the app bundle resolves its language.
    static func applyStoredLanguage() {
        let raw = UserDefaults.standard.string(forKey: storedKey) ?? ""
        guard !raw.isEmpty else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        UserDefaults.standard.set([raw], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }
}

/// Helper for strings created in AppKit code, where SwiftUI's automatic
/// `LocalizedStringKey` lookup does not apply. The Russian text is the key;
/// untranslated strings simply fall back to it.
enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    /// Translation with one string placeholder (`%@`). Used by status
    /// messages; numbers are passed as strings so the placeholder type never
    /// depends on the translation.
    static func fmt(_ key: String, _ value: String) -> String {
        String(format: tr(key), value)
    }

    /// Translation with two string placeholders (`%@`/`%@`).
    static func fmt(_ key: String, _ first: String, _ second: String) -> String {
        String(format: tr(key), first, second)
    }

    /// Translation with three string placeholders.
    static func fmt(_ key: String, _ first: String, _ second: String,
                    _ third: String) -> String {
        String(format: tr(key), first, second, third)
    }
}
