package ai.oriveo.community.feature.providers.relay

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.outlined.Language
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.ui.theme.OriveoTheme


@Immutable
data class RelayKindMeta(
    @StringRes val titleRes: Int,
    @StringRes val subtitleRes: Int,
    
    val endpointPath: String? = null,
    
    @DrawableRes val logoRes: Int? = null,
    
    val systemIcon: ImageVector,
    
    val tint: Color,
    
    val tintDeep: Color,
) {
    
    @get:DrawableRes
    val watermarkRes: Int
        get() = logoRes ?: R.drawable.ic_provider_relay
}


@Composable
fun relayKindMeta(kind: RelayKind): RelayKindMeta {
    val dark = OriveoTheme.isDark
    return when (kind) {
        RelayKind.OpenAICompatible -> RelayKindMeta(
            titleRes = R.string.relay_kind_openai_compatible,
            subtitleRes = R.string.relay_kind_openai_compatible_subtitle,
            endpointPath = "/v1/chat/completions",
            logoRes = R.drawable.ic_provider_openai,
            systemIcon = Icons.Filled.CheckCircle,
            tint = if (dark) Color(0xFF22C55E) else Color(0xFF16A34A),
            tintDeep = if (dark) Color(0xFF15803D) else Color(0xFF0E8F5B),
        )
        RelayKind.CodexStyle -> RelayKindMeta(
            titleRes = R.string.relay_kind_codex_style,
            subtitleRes = R.string.relay_kind_codex_style_subtitle,
            endpointPath = "/v1/responses",
            logoRes = R.drawable.ic_provider_openai,
            systemIcon = Icons.Filled.Bolt,
            tint = if (dark) Color(0xFF60A5FA) else Color(0xFF2563EB),
            tintDeep = if (dark) Color(0xFF3B82F6) else Color(0xFF1D4ED8),
        )
        RelayKind.AnthropicCompatible -> RelayKindMeta(
            titleRes = R.string.relay_kind_anthropic_compatible,
            subtitleRes = R.string.relay_kind_anthropic_compatible_subtitle,
            logoRes = R.drawable.ic_provider_anthropic,
            systemIcon = Icons.Filled.VerifiedUser,
            tint = if (dark) Color(0xFFFB923C) else Color(0xFFC2410C),
            tintDeep = if (dark) Color(0xFFF97316) else Color(0xFF9A3412),
        )
        RelayKind.GeminiCompatible -> RelayKindMeta(
            titleRes = R.string.relay_kind_gemini_compatible,
            subtitleRes = R.string.relay_kind_gemini_compatible_subtitle,
            logoRes = R.drawable.ic_provider_gemini,
            systemIcon = Icons.Outlined.Language,
            tint = if (dark) Color(0xFF818CF8) else Color(0xFF4F46E5),
            tintDeep = if (dark) Color(0xFFA78BFA) else Color(0xFF7C3AED),
        )
        RelayKind.Custom -> RelayKindMeta(
            titleRes = R.string.relay_kind_custom,
            subtitleRes = R.string.relay_kind_custom_subtitle,
            
            systemIcon = Icons.Filled.Tune,
            tint = if (dark) Color(0xFF94A3B8) else Color(0xFF64748B),
            tintDeep = if (dark) Color(0xFF64748B) else Color(0xFF475569),
        )
    }
}
