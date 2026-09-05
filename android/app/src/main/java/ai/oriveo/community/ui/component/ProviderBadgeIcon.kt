package ai.oriveo.community.ui.component

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Provider brand badge. Vendor marks are drawn on their own transparent background with no tray,
 * no outline and no cropping, so every provider keeps the logo exactly as it ships it.
 *
 * Relay shows the logo of whichever wire protocol the user picked (OpenAI / Anthropic / Gemini);
 * a Custom protocol, or none chosen yet, falls back to the Relay quad-petal bloom mark.
 */
@Composable
fun ProviderBadgeIcon(
    kind: ProviderKind,
    modifier: Modifier = Modifier,
    size: Dp = 44.dp,
    relayKind: RelayKind? = null,
    /**
     * Render the logo as if the appearance were dark, whatever the system theme says.
     * Brand hero cards paint their own dark background, so they need the dark-variant asset
     * even while the rest of the app is in light mode.
     */
    forceDarkAppearance: Boolean = false,
    /**
     * Overrides how much of the badge canvas the brand logo fills. The vendor assets are
     * normalised to 1.0 and already carry their own visual safe area, so this only exists for
     * callers that deliberately want the mark inset or bleeding to the edge.
     */
    contentScaleOverride: Float? = null,
) {
    // The vendor artwork ships with a uniform visual safe area baked into its canvas, so the badge
    // can draw it edge to edge without adding padding of its own.
    val contentScale = contentScaleOverride ?: ProviderBadgeLogoMetrics.BrandContentScale
    val brandInset = size * ((1f - contentScale) / 2f)
    val useDarkAsset = forceDarkAppearance || OriveoTheme.isDark

    if (kind == ProviderKind.Relay) {
        val brandLogoKind = relayKindToBrandProvider(relayKind)
        if (brandLogoKind != null) {
            Image(
                painter = rememberBrandPainter(providerLogoRes(brandLogoKind, useDarkAsset), size),
                contentDescription = brandLogoKind.displayName,
                modifier = modifier
                    .size(size)
                    .padding(brandInset),
                contentScale = ContentScale.Fit,
            )
        } else {
            Box(
                modifier = modifier.size(size),
                contentAlignment = Alignment.Center,
            ) {
                Image(
                    painter = rememberBrandPainter(
                        R.drawable.ic_provider_relay,
                        size * ProviderBadgeLogoMetrics.RelayFallbackContentScale,
                    ),
                    contentDescription = "Relay",
                    modifier = Modifier.size(size * ProviderBadgeLogoMetrics.RelayFallbackContentScale),
                    contentScale = ContentScale.Fit,
                )
            }
        }
    } else {
        Image(
            painter = rememberBrandPainter(providerLogoRes(kind, useDarkAsset), size),
            contentDescription = kind.displayName,
            modifier = modifier
                .size(size)
                // brandInset already folds in contentScaleOverride: a hero card passing 1f gets an
                // inset of 0 so the mark runs flush to the leading rail, while the default null path
                // resolves to ProviderBadgeLogoMetrics.brandInset(size) and leaves every other call
                // site pixel-identical.
                .padding(brandInset),
            contentScale = ContentScale.Fit,
        )
    }
}

internal object ProviderBadgeLogoMetrics {
    // LobeHub provider assets already include a consistent visual safe area in their 640px canvas.
    const val BrandContentScale: Float = 1f
    const val RelayFallbackContentScale: Float = 0.92f

    fun brandInset(size: Dp): Dp = size * ((1f - BrandContentScale) / 2f)

    fun brandInset(size: Float): Float = size * ((1f - BrandContentScale) / 2f)
}

/**
 * Relay protocol to vendor logo. The wire protocol the user selected decides which mark is shown,
 * not the endpoint host; Custom or unset returns null so the Relay mark is used instead.
 */
private fun relayKindToBrandProvider(relayKind: RelayKind?): ProviderKind? = when (relayKind) {
    RelayKind.OpenAICompatible, RelayKind.CodexStyle -> ProviderKind.OpenAI
    RelayKind.AnthropicCompatible -> ProviderKind.Anthropic
    RelayKind.GeminiCompatible -> ProviderKind.Gemini
    RelayKind.Custom, null -> null
}

/**
 * Symbol for the brand watermark stamp.
 *
 * Null means the provider ships a full-colour logo on a transparent background, which can be
 * masked straight into a silhouette stamp - the strongest identity cue available, so it wins
 * whenever it is possible.
 *
 * A non-null vector means there is no vendor mark suitable for a silhouette. Relay points at an
 * endpoint the user supplies rather than at one vendor, so its stamp falls back to the motif symbol.
 */
internal fun ProviderKind.brandWatermarkIcon(): ImageVector? = when (this) {
    ProviderKind.Relay -> Icons.Outlined.AutoAwesome
    else -> null
}

/**
 * Provider logo drawable. Hero surfaces paint their own dark background and can therefore ask for
 * the dark-appearance asset independently of the system theme.
 */
internal fun providerLogoRes(kind: ProviderKind, darkAppearance: Boolean = false): Int = when (kind) {
    ProviderKind.OpenAI -> if (darkAppearance) R.drawable.ic_provider_openai_dark else R.drawable.ic_provider_openai
    ProviderKind.Anthropic -> if (darkAppearance) R.drawable.ic_provider_anthropic_dark else R.drawable.ic_provider_anthropic
    ProviderKind.Gemini -> if (darkAppearance) R.drawable.ic_provider_gemini_dark else R.drawable.ic_provider_gemini
    ProviderKind.DeepSeek -> if (darkAppearance) R.drawable.ic_provider_deepseek_dark else R.drawable.ic_provider_deepseek
    ProviderKind.Grok -> if (darkAppearance) R.drawable.ic_provider_grok_dark else R.drawable.ic_provider_grok
    ProviderKind.OpenRouter -> if (darkAppearance) R.drawable.ic_provider_openrouter_dark else R.drawable.ic_provider_openrouter
    ProviderKind.Groq -> if (darkAppearance) R.drawable.ic_provider_groq_dark else R.drawable.ic_provider_groq
    ProviderKind.Together -> if (darkAppearance) R.drawable.ic_provider_together_dark else R.drawable.ic_provider_together
    ProviderKind.Fireworks -> if (darkAppearance) R.drawable.ic_provider_fireworks_dark else R.drawable.ic_provider_fireworks
    ProviderKind.MiniMax -> if (darkAppearance) R.drawable.ic_provider_minimax_dark else R.drawable.ic_provider_minimax
    ProviderKind.Zhipu -> if (darkAppearance) R.drawable.ic_provider_zhipu_dark else R.drawable.ic_provider_zhipu
    ProviderKind.Qwen -> if (darkAppearance) R.drawable.ic_provider_qwen_dark else R.drawable.ic_provider_qwen
    ProviderKind.Moonshot -> if (darkAppearance) R.drawable.ic_provider_kimi_dark else R.drawable.ic_provider_kimi
    // Mistral's mark is multi-colour (same situation as Together): one asset reads correctly in both
    // appearances, so there is no inverted _dark variant to pick.
    ProviderKind.Mistral -> R.drawable.ic_provider_mistral
    ProviderKind.SiliconFlow -> if (darkAppearance) R.drawable.ic_provider_siliconflow_dark else R.drawable.ic_provider_siliconflow
    ProviderKind.Relay -> R.drawable.ic_provider_relay
}
