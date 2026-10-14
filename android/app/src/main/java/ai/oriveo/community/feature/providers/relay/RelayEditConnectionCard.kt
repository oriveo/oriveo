package ai.oriveo.community.feature.providers.relay

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

@androidx.compose.runtime.Immutable
internal enum class RelayApiKeyRowState {

    NotRequired,

    Missing,

    Present,
    ;

    companion object {
        fun of(requiresCredential: Boolean, apiKeyPreview: String): RelayApiKeyRowState = when {
            apiKeyPreview.isNotBlank() -> Present
            requiresCredential -> Missing
            else -> NotRequired
        }
    }
}

@Composable
internal fun RelayEditFailureDetails(presentation: RelayEditFailurePresentation) {
    val colors = OriveoTheme.colors
    if (presentation.endpoint.isNotBlank()) {
        Text(
            text = "${stringResource(R.string.relay_field_endpoint)}: ${presentation.endpoint}",
            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
            color = colors.textTertiary,
        )
    }
    presentation.statusCode?.let { code ->
        Text(
            text = "HTTP $code",
            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
            color = colors.textTertiary,
        )
    }
    Text(
        text = stringResource(R.string.relay_quick_automatic_retries, presentation.automaticRetryCount),
        style = OriveoTheme.typography.footnote,
        color = colors.textTertiary,
    )
    // Raw local error text: technical text is not translated and gets no "upstream response" caption.
    presentation.localErrorDetail?.let { detail ->
        Text(
            text = detail,
            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
            color = colors.textSecondary,
            maxLines = 6,
            overflow = TextOverflow.Ellipsis,
        )
    }
    presentation.upstreamJson?.let { body ->
        Text(
            text = stringResource(R.string.relay_upstream_response_redacted),
            style = OriveoTheme.typography.footnote,
            color = colors.textTertiary,
        )
        Text(
            text = body,
            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
            color = colors.textSecondary,
            maxLines = 6,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
