import Foundation
import SwiftUI

enum AppTab: String, CaseIterable, Hashable, Codable {
    case home
    case providers
    case settings

    var title: String {
        switch self {
        case .home:
            return L10n.tr("Home")
        case .providers:
            return L10n.tr("Providers")
        case .settings:
            return L10n.tr("Settings")
        }
    }

    /// The linear tab bar icon (template vector on a 24 grid, stroke 1.8, round caps and joins):
    /// a speech bubble with three dots / two four-point stars, one large and one small / three sliders
    var tabBarIconAsset: String {
        switch self {
        case .home:
            return "TabIconHome"
        case .providers:
            return "TabIconProviders"
        case .settings:
            return "TabIconSettings"
        }
    }

    /// The selected-state twin of the icon: the stroke is baked into the tab's gradient (rendered as original,
    /// one asset per colour scheme)
    var tabBarSelectedIconAsset: String {
        tabBarIconAsset + "Selected"
    }
}

enum ThemeOption: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return L10n.tr("Follow System")
        case .light:
            return L10n.tr("Light")
        case .dark:
            return L10n.tr("Dark")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum LanguageOption: String, CaseIterable, Identifiable, Codable {
    case system
    case english
    case chineseSimplified
    case chineseTraditional
    case japanese
    case korean
    case spanish
    case french
    case german
    case portuguese
    case arabic
    case hindi
    case indonesian
    case vietnamese
    case thai
    case turkish
    case russian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return L10n.tr("Follow System")
        case .english:
            return "English"
        case .chineseSimplified:
            return "简体中文"
        case .chineseTraditional:
            return "繁體中文"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        case .spanish:
            return "Español"
        case .french:
            return "Français"
        case .german:
            return "Deutsch"
        case .portuguese:
            return "Português"
        case .arabic:
            return "العربية"
        case .hindi:
            return "हिन्दी"
        case .indonesian:
            return "Bahasa Indonesia"
        case .vietnamese:
            return "Tiếng Việt"
        case .thai:
            return "ไทย"
        case .turkish:
            return "Türkçe"
        case .russian:
            return "Русский"
        }
    }

    var effectiveLanguage: AppLanguage {
        switch self {
        case .system:
            return .systemPreferred
        case .english:
            return .english
        case .chineseSimplified:
            return .chineseSimplified
        case .chineseTraditional:
            return .chineseTraditional
        case .japanese:
            return .japanese
        case .korean:
            return .korean
        case .spanish:
            return .spanish
        case .french:
            return .french
        case .german:
            return .german
        case .portuguese:
            return .portuguese
        case .arabic:
            return .arabic
        case .hindi:
            return .hindi
        case .indonesian:
            return .indonesian
        case .vietnamese:
            return .vietnamese
        case .thai:
            return .thai
        case .turkish:
            return .turkish
        case .russian:
            return .russian
        }
    }

    var locale: Locale {
        effectiveLanguage.locale
    }
}

extension LanguageOption {
    init(appLanguage: AppLanguage) {
        switch appLanguage {
        case .english: self = .english
        case .chineseSimplified: self = .chineseSimplified
        case .chineseTraditional: self = .chineseTraditional
        case .japanese: self = .japanese
        case .korean: self = .korean
        case .spanish: self = .spanish
        case .french: self = .french
        case .german: self = .german
        case .portuguese: self = .portuguese
        case .arabic: self = .arabic
        case .hindi: self = .hindi
        case .indonesian: self = .indonesian
        case .vietnamese: self = .vietnamese
        case .thai: self = .thai
        case .turkish: self = .turkish
        case .russian: self = .russian
        }
    }

}

struct AppPreference: Hashable {
    var theme: ThemeOption
    var themeSetByUser: Bool = false
    var language: LanguageOption
    var memoryText: String = ""
    var memoryAntiForgetEnabled: Bool = false
    var memoryAntiForgetText: String = ""
    var memoryUpdatedAt: Date? = nil
    var pinnedConversationIDs: [UUID] = []
    var pinnedConversationIDsUpdatedAt: Date? = nil
}
