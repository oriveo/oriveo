package ai.oriveo.community.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Appearance setting. */
@Serializable
enum class ThemeOption {
    @SerialName("system") System,
    @SerialName("light") Light,
    @SerialName("dark") Dark;

    val displayName: String
        get() = when (this) {
            System -> "Follow System"
            Light -> "Light"
            Dark -> "Dark"
        }
}

/** In-app language, independent of the system language. */
@Serializable
enum class LanguageOption {
    @SerialName("system") System,
    @SerialName("english") English,
    @SerialName("chineseSimplified") ChineseSimplified,
    @SerialName("chineseTraditional") ChineseTraditional,
    @SerialName("japanese") Japanese,
    @SerialName("korean") Korean,
    @SerialName("spanish") Spanish,
    @SerialName("french") French,
    @SerialName("german") German,
    @SerialName("portuguese") Portuguese,
    @SerialName("arabic") Arabic,
    @SerialName("hindi") Hindi,
    @SerialName("indonesian") Indonesian,
    @SerialName("vietnamese") Vietnamese,
    @SerialName("thai") Thai,
    @SerialName("turkish") Turkish,
    @SerialName("russian") Russian;

    /** Always shown in the language itself, never translated. */
    val displayName: String
        get() = when (this) {
            System -> ""
            English -> "English"
            ChineseSimplified -> "简体中文"
            ChineseTraditional -> "繁體中文"
            Japanese -> "日本語"
            Korean -> "한국어"
            Spanish -> "Español"
            French -> "Français"
            German -> "Deutsch"
            Portuguese -> "Português"
            Arabic -> "العربية"
            Hindi -> "हिन्दी"
            Indonesian -> "Bahasa Indonesia"
            Vietnamese -> "Tiếng Việt"
            Thai -> "ไทย"
            Turkish -> "Türkçe"
            Russian -> "Русский"
        }

    /** Android locale tag */
    val localeTag: String?
        get() = when (this) {
            System -> null
            English -> "en"
            ChineseSimplified -> "zh-CN"
            ChineseTraditional -> "zh-TW"
            Japanese -> "ja"
            Korean -> "ko"
            Spanish -> "es"
            French -> "fr"
            German -> "de"
            Portuguese -> "pt-BR"
            Arabic -> "ar"
            Hindi -> "hi"
            Indonesian -> "id"
            Vietnamese -> "vi"
            Thai -> "th"
            Turkish -> "tr"
            Russian -> "ru"
        }
}

/** App-level preferences. The theme defaults to dark when the user has not chosen one. */
data class AppPreference(
    val theme: ThemeOption = ThemeOption.Dark,
    val language: LanguageOption = LanguageOption.System,
    val memoryText: String = "",
    val memoryAntiForgetEnabled: Boolean = false,
    val memoryAntiForgetText: String = "",
    val memoryUpdatedAt: String? = null,
)
