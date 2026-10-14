package ai.oriveo.community.core.model

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.ProviderBadgeLogoMetrics
import ai.oriveo.community.ui.component.providerLogoRes
import ai.oriveo.community.ui.component.rememberBrandPainter
import ai.oriveo.community.ui.theme.CapabilityPalette
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.DetailRowPalette
import ai.oriveo.community.ui.theme.LocalIsDarkTheme
import ai.oriveo.community.ui.theme.LocalOriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.Locale

/** Resolution result of a relay avatar. */
sealed interface RelayAvatarResult {
    /** Aggregator brand: draw the existing official brand asset (no backing plate). */
    data class Brand(val id: String, val kind: ProviderKind) : RelayAvatarResult

    /** Initial letter: neutral secondary text color, no round / square backing or stroke. */
    data class Initial(val text: String) : RelayAvatarResult

    /** Nothing could be resolved: the existing relay icon. */
    data object Generic : RelayAvatarResult

    /** Phosphor duotone icon (the default icon or a choice saved on this device): tinted by [RelayAvatarIcon.palette], no backing plate or stroke. */
    data class Icon(val icon: RelayAvatarIcon) : RelayAvatarResult
}

/**
 * The ten duotone icons for relay avatars; the order is both the modulo order of default assignment and the order of the picker cells.
 * Sourced from `icons` in `shared/test-fixtures/relay/relay-avatar-icon.v1.json` (pinned entry by entry by tests).
 */
enum class RelayAvatarIcon(
    val id: String,
    val phosphor: String,
    @param:DrawableRes val drawable: Int,
    /** Color token: `detailRow.*` reads [DetailRowPalette], `capability.*` reads [CapabilityPalette]. */
    val palette: String,
    @param:StringRes val labelRes: Int,
) {
    Planet("planet", "planet", R.drawable.ph_planet_duotone, "detailRow.indigo", R.string.relay_avatar_icon_planet),
    Compass("compass", "compass", R.drawable.ph_compass_duotone, "detailRow.teal", R.string.relay_avatar_icon_compass),
    Sailboat("sailboat", "sailboat", R.drawable.ph_sailboat_duotone, "detailRow.cyan", R.string.relay_avatar_icon_sailboat),
    Lighthouse("lighthouse", "lighthouse", R.drawable.ph_lighthouse_duotone, "capability.attachment", R.string.relay_avatar_icon_lighthouse),
    Mountains("mountains", "mountains", R.drawable.ph_mountains_duotone, "capability.webSearch", R.string.relay_avatar_icon_mountains),
    SunHorizon("sun-horizon", "sun-horizon", R.drawable.ph_sun_horizon_duotone, "detailRow.orange", R.string.relay_avatar_icon_sun_horizon),
    Flame("flame", "flame", R.drawable.ph_flame_duotone, "detailRow.rose", R.string.relay_avatar_icon_flame),
    TreeEvergreen("tree-evergreen", "tree-evergreen", R.drawable.ph_tree_evergreen_duotone, "capability.vision", R.string.relay_avatar_icon_tree_evergreen),
    MoonStars("moon-stars", "moon-stars", R.drawable.ph_moon_stars_duotone, "capability.reasoning", R.string.relay_avatar_icon_moon_stars),
    Butterfly("butterfly", "butterfly", R.drawable.ph_butterfly_duotone, "capability.tools", R.string.relay_avatar_icon_butterfly),
    ;

    /** The color under the current theme (dark 400 / light 600); color values live only in the palette file. */
    val tint: Color
        @Composable get() = when (palette) {
            "detailRow.indigo" -> DetailRowPalette.indigo
            "detailRow.teal" -> DetailRowPalette.teal
            "detailRow.cyan" -> DetailRowPalette.cyan
            "detailRow.orange" -> DetailRowPalette.orange
            "detailRow.rose" -> DetailRowPalette.rose
            "capability.attachment" -> CapabilityPalette.attachment
            "capability.webSearch" -> CapabilityPalette.webSearch
            "capability.vision" -> CapabilityPalette.vision
            "capability.reasoning" -> CapabilityPalette.reasoning
            else -> CapabilityPalette.tools
        }

    companion object {
        fun fromId(id: String?): RelayAvatarIcon? = id?.let { value -> entries.firstOrNull { it.id == value } }
    }
}

/** One cell of the "Change icon" picker; [choice] is the value written to on-device storage when it is tapped (null = remove the saved choice). */
sealed interface RelayAvatarPickerCell {
    val choice: String?
    val preview: RelayAvatarResult

    /** Same shape as fixture `pickerCases.cells`: `brand:<id>` / icon id / `letter:<text>`. */
    val token: String

    data class Brand(val brand: RelayAvatarResult.Brand) : RelayAvatarPickerCell {
        override val choice: String? get() = null
        override val preview: RelayAvatarResult get() = brand
        override val token: String get() = "brand:${brand.id}"
    }

    data class Icon(val icon: RelayAvatarIcon) : RelayAvatarPickerCell {
        override val choice: String get() = icon.id
        override val preview: RelayAvatarResult get() = RelayAvatarResult.Icon(icon)
        override val token: String get() = icon.id
    }

    data class Letter(val text: String) : RelayAvatarPickerCell {
        override val choice: String get() = RelayAvatarChoiceStore.LETTER
        override val preview: RelayAvatarResult get() = RelayAvatarResult.Initial(text)
        override val token: String get() = "letter:$text"
    }
}

/**
 * The single resolver of relay avatars: the model-picker group header, chat top bar, message header, detail header and provider list all take their result from it.
 * Rules are sourced from `shared/test-fixtures/relay/relay-avatar.v1.json` (the brand table matches it entry by entry, pinned by tests);
 * model id and relayKind never participate (the old inference would draw ordinary relays as OpenAI / Anthropic). Local connections do not use this function.
 */
object RelayAvatarResolver {
    data class BrandRule(val id: String, val kind: ProviderKind, val keywords: List<String>)

    val BRANDS: List<BrandRule> = listOf(
        BrandRule("openrouter", ProviderKind.OpenRouter, listOf("openrouter")),
        BrandRule("siliconflow", ProviderKind.SiliconFlow, listOf("siliconflow")),
        BrandRule("together", ProviderKind.Together, listOf("together.ai", "together.xyz", "togetherai")),
        BrandRule("fireworks", ProviderKind.Fireworks, listOf("fireworks")),
        BrandRule("groq", ProviderKind.Groq, listOf("groq")),
    )

    /** The app's own name cannot tell who the upstream is: a hit skips brand matching. */
    val EXCLUDE_KEYWORDS: List<String> = listOf("oriveo")

    /** Only relay connections use the avatar; official providers and local connections (non-null engineProfile) keep the existing logo. */
    fun appliesTo(provider: Provider): Boolean =
        provider.kind == ProviderKind.Relay && provider.relayRequested?.engineProfile.isNullOrBlank()

    /**
     * The final avatar of a connection: takes the name the user gave rather than the "Relay (host)" display-name fallback; when the name is empty the rules fall back to the host.
     * [choice] defaults to the on-device choice store; a Composable passes the value it subscribed to so a changed choice recomputes immediately.
     */
    fun resolve(provider: Provider, choice: String? = RelayAvatarChoiceStore.choice(provider.id)): RelayAvatarResult =
        resolve(provider.id, provider.customName.orEmpty(), provider.baseUrlText.orEmpty(), choice)

    /**
     * Icon layer (`relay-avatar-icon.v1.json`): 1. the on-device choice (icon id -> icon; "letter" -> initial, falling to 3 when none);
     * 2. the base-layer brand; 3. one of the ten icons, assigned stably by connection id. An empty connection id returns the base layer unchanged.
     */
    fun resolve(providerId: String, name: String, url: String, choice: String?): RelayAvatarResult {
        val base = resolve(name, url)
        val key = choiceKey(providerId)
        if (key.isEmpty()) return base
        RelayAvatarIcon.fromId(choice)?.let { return RelayAvatarResult.Icon(it) }
        if (choice == RelayAvatarChoiceStore.LETTER) {
            return initialOf(name, url)?.let(RelayAvatarResult::Initial) ?: RelayAvatarResult.Icon(defaultIcon(key))
        }
        if (base is RelayAvatarResult.Brand) return base
        return RelayAvatarResult.Icon(defaultIcon(key))
    }

    /** Picker cells: brand (only when the base layer matches) -> the ten icons -> initial (only when the base initial rule yields one). */
    fun pickerCells(name: String, url: String): List<RelayAvatarPickerCell> = buildList {
        (resolve(name, url) as? RelayAvatarResult.Brand)?.let { add(RelayAvatarPickerCell.Brand(it)) }
        RelayAvatarIcon.entries.forEach { add(RelayAvatarPickerCell.Icon(it)) }
        initialOf(name, url)?.let { add(RelayAvatarPickerCell.Letter(it)) }
    }

    /** Key of the choice store and input of the hash: trims leading / trailing ASCII whitespace and lowercases only ASCII A-Z, leaving other bytes alone. */
    fun choiceKey(providerId: String): String =
        providerId.trim { it in ASCII_WHITESPACE }.map { if (it in 'A'..'Z') it + 32 else it }.joinToString("")

    /** 32-bit FNV-1a over the UTF-8 bytes; read the return value as unsigned. */
    fun fnv1a32(key: String): Int {
        var hash = 0x811c9dc5.toInt()
        key.toByteArray(Charsets.UTF_8).forEach { byte ->
            hash = hash xor (byte.toInt() and 0xff)
            hash *= 0x01000193
        }
        return hash
    }

    private fun defaultIcon(key: String): RelayAvatarIcon {
        val entries = RelayAvatarIcon.entries
        return entries[((fnv1a32(key).toLong() and 0xffffffffL) % entries.size).toInt()]
    }

    private const val ASCII_WHITESPACE = " \t\n\u000B\u000C\r"

    /** The base layer's initial rule (no brand matching). */
    private fun initialOf(name: String, url: String): String? {
        val trimmedName = name.trim()
        return initial(trimmedName.ifEmpty { host(url)?.removePrefix("api.")?.removePrefix("www.").orEmpty() })
    }

    /** Base layer (`relay-avatar.v1.json`): brand -> initial -> generic; ignores the connection id and the on-device choice. */
    fun resolve(name: String, url: String): RelayAvatarResult {
        val trimmedName = name.trim()
        val host = host(url)
        val haystacks = listOfNotNull(trimmedName.lowercase(Locale.ROOT), host?.lowercase(Locale.ROOT))
        val excluded = EXCLUDE_KEYWORDS.any { keyword -> haystacks.any { it.contains(keyword) } }
        if (!excluded) {
            BRANDS.firstOrNull { rule -> rule.keywords.any { keyword -> haystacks.any { it.contains(keyword) } } }
                ?.let { return RelayAvatarResult.Brand(it.id, it.kind) }
        }
        val source = trimmedName.ifEmpty { host?.removePrefix("api.")?.removePrefix("www.").orEmpty() }
        return initial(source)?.let(RelayAvatarResult::Initial) ?: RelayAvatarResult.Generic
    }

    private fun host(url: String): String? {
        val trimmed = url.trim()
        if (trimmed.isEmpty()) return null
        val candidate = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        return runCatching { java.net.URI(candidate).host }.getOrNull()?.takeIf(String::isNotBlank)
    }

    /** The first Unicode letter or digit; Latin letters are uppercased, other scripts are kept as is. */
    private fun initial(text: String): String? {
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            if (Character.isLetterOrDigit(codePoint)) {
                val shown = if (Character.UnicodeScript.of(codePoint) == Character.UnicodeScript.LATIN) {
                    Character.toUpperCase(codePoint)
                } else {
                    codePoint
                }
                return String(Character.toChars(shown))
            }
            index += Character.charCount(codePoint)
        }
        return null
    }
}

/** The relay avatar shared by all five places; the caller first uses [RelayAvatarResolver.appliesTo] to decide whether to use it. Subscribes to the on-device choice and redraws as soon as it changes. */
@Composable
fun RelayAvatar(provider: Provider, size: Dp, modifier: Modifier = Modifier) {
    val choice = rememberRelayAvatarChoice(provider.id)
    val result = remember(provider.id, provider.customName, provider.baseUrlText, choice) {
        RelayAvatarResolver.resolve(provider, choice)
    }
    RelayAvatar(result = result, size = size, modifier = modifier)
}

/** The on-device avatar choice of a connection; a store change triggers recomposition. */
@Composable
fun rememberRelayAvatarChoice(providerId: String?): String? {
    val choices by RelayAvatarChoiceStore.choices.collectAsState()
    return providerId?.let { choices[RelayAvatarResolver.choiceKey(it)] }
}

/** Draws a resolution result directly; used only where there is no connection object, such as "relay message cannot find its connection -> Generic". */
@Composable
fun RelayAvatar(result: RelayAvatarResult, size: Dp, modifier: Modifier = Modifier) {
    when (result) {
        is RelayAvatarResult.Brand -> Image(
            painter = rememberBrandPainter(providerLogoRes(result.kind, OriveoTheme.isDark), size),
            contentDescription = result.kind.displayName,
            modifier = modifier.size(size),
            contentScale = ContentScale.Fit,
        )
        is RelayAvatarResult.Initial -> Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
            Text(
                text = result.text,
                // Font size follows the avatar size; weight is at the same level as the name (SemiBold).
                fontSize = (size.value * 0.56f).sp,
                fontWeight = FontWeight.SemiBold,
                color = OriveoTheme.colors.textSecondary,
                textAlign = TextAlign.Center,
                maxLines = 1,
            )
        }
        is RelayAvatarResult.Icon -> Icon(
            painter = painterResource(result.icon.drawable),
            contentDescription = stringResource(result.icon.labelRes),
            tint = result.icon.tint,
            // The icon fills the avatar frame, with no backing plate or stroke.
            modifier = modifier.size(size),
        )
        RelayAvatarResult.Generic -> Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
            val glyph = size * ProviderBadgeLogoMetrics.RelayFallbackContentScale
            Image(
                painter = rememberBrandPainter(R.drawable.ic_provider_relay, glyph),
                contentDescription = "Relay",
                modifier = Modifier.size(glyph),
                contentScale = ContentScale.Fit,
            )
        }
    }
}

/**
 * What avatar a connection draws: relay connections use [RelayAvatar]; when the connection no longer exists but the message / conversation recorded a relay it draws generic,
 * local engines and official providers use [ProviderBadgeIcon] (local keeps using [resolveProviderLogoKind]). It no longer draws a protocol logo by relayKind.
 */
sealed interface ConnectionAvatarSpec {
    data class Relay(val result: RelayAvatarResult) : ConnectionAvatarSpec
    data class Badge(val kind: ProviderKind) : ConnectionAvatarSpec

    companion object {
        fun of(
            provider: Provider?,
            fallbackKind: ProviderKind,
            choice: String? = provider?.let { RelayAvatarChoiceStore.choice(it.id) },
        ): ConnectionAvatarSpec = when {
            provider == null ->
                if (fallbackKind == ProviderKind.Relay) Relay(RelayAvatarResult.Generic) else Badge(fallbackKind)
            RelayAvatarResolver.appliesTo(provider) -> Relay(RelayAvatarResolver.resolve(provider, choice))
            else -> Badge(resolveProviderLogoKind(provider))
        }
    }
}

/**
 * Use this wherever a connection object is available; [fallbackKind] is used only when the connection does not exist (the kind recorded on the message / conversation).
 * [forceDarkAppearance] is for dark-backed brand cards: the badge picks the dark asset, and the relay avatar picks asset and text color for the dark appearance.
 */
@Composable
fun ConnectionAvatar(
    provider: Provider?,
    fallbackKind: ProviderKind,
    size: Dp,
    modifier: Modifier = Modifier,
    forceDarkAppearance: Boolean = false,
    contentScaleOverride: Float? = null,
) {
    // Use only the fields the resolution actually reads as the key: changes to high-frequency fields such as status / lastCheckedAt do not recompute; the on-device avatar choice is a key too.
    val choice = rememberRelayAvatarChoice(provider?.id)
    val spec = remember(
        provider?.id,
        choice,
        provider?.kind,
        provider?.customName,
        provider?.displayName,
        provider?.baseUrlText,
        provider?.relayKind,
        provider?.relayRequested?.engineProfile,
        provider?.models,
        fallbackKind,
    ) { ConnectionAvatarSpec.of(provider, fallbackKind, choice) }
    when (spec) {
        is ConnectionAvatarSpec.Badge -> ProviderBadgeIcon(
            kind = spec.kind,
            modifier = modifier,
            size = size,
            forceDarkAppearance = forceDarkAppearance,
            contentScaleOverride = contentScaleOverride,
        )
        is ConnectionAvatarSpec.Relay -> if (forceDarkAppearance) {
            CompositionLocalProvider(LocalIsDarkTheme provides true, LocalOriveoColors provides DarkOriveoColors) {
                RelayAvatar(result = spec.result, size = size, modifier = modifier)
            }
        } else {
            RelayAvatar(result = spec.result, size = size, modifier = modifier)
        }
    }
}
