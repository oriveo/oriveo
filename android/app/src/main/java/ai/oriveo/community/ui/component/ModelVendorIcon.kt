package ai.oriveo.community.ui.component

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun ModelVendorIcon(
    groupKey: String?,
    groupName: String?,
    modifier: Modifier = Modifier,
    size: Dp = 38.dp,
) {

    val isDark = OriveoTheme.isDark
    val normalizedGroupKey = remember(groupKey) { normalizeModelVendorKey(groupKey) }
    val assetRes = remember(normalizedGroupKey, isDark) { vendorLogoRes(normalizedGroupKey, isDark) }
    val usesNativeColors = remember(normalizedGroupKey) { usesUnifiedProviderLogo(normalizedGroupKey) }
    val style = remember(normalizedGroupKey, isDark, assetRes) {
        vendorStyle(normalizedGroupKey, isDark, hasLogo = assetRes != null)
    }
    val shape = remember(size) { RoundedCornerShape(size * 0.28f) }

    if (assetRes != null) {
        Box(
            modifier = modifier.size(size),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                painter = rememberBrandPainter(assetRes, size),
                contentDescription = null,
                modifier = Modifier.size(size),
                colorFilter = if (isDark && !usesNativeColors) ColorFilter.tint(style.foreground) else null,
            )
        }
    } else {
        Box(
            modifier = modifier
                .size(size)
                .clip(shape)
                .background(style.background)
                .padding(size * 0.18f),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = vendorMonogram(groupName ?: groupKey ?: "AI"),
                style = OriveoTheme.typography.footnote,
                color = style.foreground,
            )
        }
    }
}

private data class VendorIconStyle(
    val background: Color,
    val border: Color,
    val foreground: Color,
)

internal fun normalizeModelVendorKey(groupKey: String?): String = when (groupKey?.lowercase() ?: "other") {
    "google-gemini", "gemini" -> "google"
    "xai-grok" -> "x-ai"
    "kimi" -> "moonshotai"
    "zhipu-glm", "zhipu" -> "zai"
    else -> groupKey?.lowercase() ?: "other"
}

internal fun usesUnifiedProviderLogo(groupKey: String): Boolean = when (normalizeModelVendorKey(groupKey)) {
    "openai", "anthropic", "google", "openrouter", "deepseek", "deepseek-ai", "qwen",
    "moonshot", "moonshotai", "kimi", "minimax", "minimaxai", "minimax-ai", "minimaxi",
    "together", "fireworksai", "x-ai", "zai", "z-ai", "zai-org", "thudm" -> true
    else -> false
}

internal fun vendorLogoRes(groupKey: String, darkAppearance: Boolean = false): Int? = when (normalizeModelVendorKey(groupKey)) {
    "openai" -> providerLogoRes(ProviderKind.OpenAI, darkAppearance)
    "anthropic" -> providerLogoRes(ProviderKind.Anthropic, darkAppearance)
    "google" -> providerLogoRes(ProviderKind.Gemini, darkAppearance)
    "openrouter" -> providerLogoRes(ProviderKind.OpenRouter, darkAppearance)
    "deepseek", "deepseek-ai" -> providerLogoRes(ProviderKind.DeepSeek, darkAppearance)
    "meta", "meta-llama" -> R.drawable.ic_vendor_meta
    "mistralai" -> R.drawable.ic_vendor_mistral
    "perplexity" -> R.drawable.ic_vendor_perplexity
    "qwen" -> providerLogoRes(ProviderKind.Qwen, darkAppearance)
    "moonshot", "moonshotai", "kimi" -> providerLogoRes(ProviderKind.Moonshot, darkAppearance)
    "microsoft" -> R.drawable.ic_vendor_microsoft
    "nvidia" -> R.drawable.ic_vendor_nvidia
    "bytedance-seed", "bytedance" -> R.drawable.ic_vendor_bytedance
    "minimax", "minimaxai", "minimax-ai", "minimaxi" -> providerLogoRes(ProviderKind.MiniMax, darkAppearance)
    "stepfun" -> R.drawable.ic_vendor_stepfun
    "upstage" -> R.drawable.ic_vendor_upstage
    "aion-labs" -> R.drawable.ic_vendor_aionlabs
    "baidu" -> R.drawable.ic_vendor_baidu
    "allenai" -> R.drawable.ic_vendor_ai2
    "arcee-ai" -> R.drawable.ic_vendor_arcee
    "cohere" -> R.drawable.ic_vendor_cohere
    "together" -> providerLogoRes(ProviderKind.Together, darkAppearance)
    "fireworksai" -> providerLogoRes(ProviderKind.Fireworks, darkAppearance)
    "cerebras" -> R.drawable.ic_vendor_cerebras
    "sambanova" -> R.drawable.ic_vendor_sambanova
    "huggingface" -> R.drawable.ic_vendor_huggingface
    "alibaba" -> R.drawable.ic_vendor_alibaba
    "deepcogito" -> R.drawable.ic_vendor_deepcogito
    "essentialai" -> R.drawable.ic_vendor_essentialai
    "kwaipilot" -> R.drawable.ic_vendor_kwaipilot
    "morph" -> R.drawable.ic_vendor_morph
    "tencent" -> R.drawable.ic_vendor_tencent
    "amazon" -> R.drawable.ic_vendor_aws
    "x-ai" -> providerLogoRes(ProviderKind.Grok, darkAppearance)
    "inception" -> R.drawable.ic_vendor_inception
    "ai21" -> R.drawable.ic_vendor_ai21
    "nousresearch" -> R.drawable.ic_vendor_nousresearch
    "inflection" -> R.drawable.ic_vendor_inflection
    "xiaomi" -> R.drawable.ic_vendor_xiaomi
    "liquid" -> R.drawable.ic_vendor_liquid
    "manus" -> R.drawable.ic_vendor_manus
    "relace" -> R.drawable.ic_vendor_relace
    "ibm-granite" -> R.drawable.ic_vendor_ibm
    "zai", "z-ai", "zai-org", "thudm" -> providerLogoRes(ProviderKind.Zhipu, darkAppearance)
    else -> null
}

private fun vendorStyle(groupKey: String, isDark: Boolean, hasLogo: Boolean = false): VendorIconStyle = when (groupKey) {
    "openai" -> if (isDark) {
        VendorIconStyle(Color(0xFF1A2420), Color(0xFF2D3D33), Color(0xFFF8FAFF))
    } else {
        VendorIconStyle(Color(0xFFF4F7F5), Color(0xFFD7E3DD), Color(0xFF111827))
    }

    "anthropic" -> if (isDark) {
        VendorIconStyle(Color(0xFF2A2520), Color(0xFF4A3F33), Color(0xFFF7E7C1))
    } else {
        VendorIconStyle(Color(0xFFF4EFE6), Color(0xFFE7DDCD), Color(0xFF7C5B2A))
    }

    "google" -> if (isDark) {
        VendorIconStyle(Color(0xFF1A2030), Color(0xFF2A3550), Color(0xFF8AB4F8))
    } else {
        VendorIconStyle(Color(0xFFEEF4FF), Color(0xFFD9E6FF), Color(0xFF2563EB))
    }

    "deepseek" -> if (isDark) {
        VendorIconStyle(Color(0xFF1A2230), Color(0xFF2A3850), Color(0xFF60A5FA))
    } else {
        VendorIconStyle(Color(0xFFEEF6FF), Color(0xFFD7E8FF), Color(0xFF2563EB))
    }

    "meta", "meta-llama" -> if (isDark) {
        VendorIconStyle(Color(0xFF1C1E30), Color(0xFF2E3050), Color(0xFFA5B4FC))
    } else {
        VendorIconStyle(Color(0xFFEEF2FF), Color(0xFFDBE4FF), Color(0xFF4F46E5))
    }

    "perplexity" -> if (isDark) {
        VendorIconStyle(Color(0xFF1A2828), Color(0xFF1E3838), Color(0xFF5EEAD4))
    } else {
        VendorIconStyle(Color(0xFFECFEFF), Color(0xFFCFFAFE), Color(0xFF0F766E))
    }

    "qwen" -> if (isDark) {
        VendorIconStyle(Color(0xFF2A2018), Color(0xFF4A3520), Color(0xFFFB923C))
    } else {
        VendorIconStyle(Color(0xFFFFF7ED), Color(0xFFFED7AA), Color(0xFFC2410C))
    }

    else -> if (hasLogo) {

        if (isDark) {
            VendorIconStyle(Color(0xFF1E2433), Color(0xFF333D50), Color(0xFFF8FAFF))
        } else {
            VendorIconStyle(Color(0xFFF8FAFC), Color(0xFFE5E7EB), Color(0xFF111827))
        }
    } else {

        val hue = stableHue(groupKey)
        VendorIconStyle(
            background = if (isDark) hslColor(hue, 0.22f, 0.18f) else hslColor(hue, 0.36f, 0.95f),
            border = if (isDark) hslColor(hue, 0.25f, 0.28f) else hslColor(hue, 0.26f, 0.82f),
            foreground = if (isDark) hslColor(hue, 0.58f, 0.76f) else hslColor(hue, 0.52f, 0.34f),
        )
    }
}

private fun vendorMonogram(value: String): String {
    val parts = value
        .split(Regex("[^A-Za-z0-9]+"))
        .filter { it.isNotBlank() }

    return when {
        parts.size >= 2 -> parts.take(2).joinToString("") { it.take(1) }.uppercase()
        parts.isNotEmpty() -> parts.first().take(2).uppercase()
        else -> "AI"
    }
}

private fun stableHue(value: String): Float {
    var hash = 5381
    value.forEach { character ->
        hash = ((hash shl 5) + hash) + character.code
    }
    return (kotlin.math.abs(hash) % 360).toFloat()
}

private fun hslColor(hue: Float, saturation: Float, lightness: Float): Color {
    val c = (1f - kotlin.math.abs((2f * lightness) - 1f)) * saturation
    val x = c * (1f - kotlin.math.abs(((hue / 60f) % 2f) - 1f))
    val m = lightness - (c / 2f)

    val (rPrime, gPrime, bPrime) = when {
        hue < 60f -> Triple(c, x, 0f)
        hue < 120f -> Triple(x, c, 0f)
        hue < 180f -> Triple(0f, c, x)
        hue < 240f -> Triple(0f, x, c)
        hue < 300f -> Triple(x, 0f, c)
        else -> Triple(c, 0f, x)
    }

    return Color(
        red = rPrime + m,
        green = gPrime + m,
        blue = bPrime + m,
        alpha = 1f,
    )
}
