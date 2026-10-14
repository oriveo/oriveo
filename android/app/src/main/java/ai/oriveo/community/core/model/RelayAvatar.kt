package ai.oriveo.community.core.model

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.ProviderBadgeLogoMetrics
import ai.oriveo.community.ui.component.providerLogoRes
import ai.oriveo.community.ui.component.rememberBrandPainter
import ai.oriveo.community.ui.theme.DarkOriveoColors
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

    /** Takes the name the user gave rather than the "Relay (host)" display-name fallback; when the name is empty the rules fall back to the host. */
    fun resolve(provider: Provider): RelayAvatarResult =
        resolve(provider.customName.orEmpty(), provider.baseUrlText.orEmpty())

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

/** The relay avatar shared by all five places; the caller first uses [RelayAvatarResolver.appliesTo] to decide whether to use it. */
@Composable
fun RelayAvatar(provider: Provider, size: Dp, modifier: Modifier = Modifier) {
    val result = remember(provider.customName, provider.baseUrlText) { RelayAvatarResolver.resolve(provider) }
    RelayAvatar(result = result, size = size, modifier = modifier)
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
        fun of(provider: Provider?, fallbackKind: ProviderKind): ConnectionAvatarSpec = when {
            provider == null ->
                if (fallbackKind == ProviderKind.Relay) Relay(RelayAvatarResult.Generic) else Badge(fallbackKind)
            RelayAvatarResolver.appliesTo(provider) -> Relay(RelayAvatarResolver.resolve(provider))
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
    // Use only the fields the resolution actually reads as the key: changes to high-frequency fields such as status / lastCheckedAt do not recompute.
    val spec = remember(
        provider?.kind,
        provider?.customName,
        provider?.displayName,
        provider?.baseUrlText,
        provider?.relayKind,
        provider?.relayRequested?.engineProfile,
        provider?.models,
        fallbackKind,
    ) { ConnectionAvatarSpec.of(provider, fallbackKind) }
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
