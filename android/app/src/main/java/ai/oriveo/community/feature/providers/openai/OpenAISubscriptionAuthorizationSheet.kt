package ai.oriveo.community.feature.providers.openai

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.feature.providers.openSubscriptionVerificationPage
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAuthConfig
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionError
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionTokens
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoTextButton
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun OpenAISubscriptionAuthorizationSheet(
    config: OpenAISubscriptionAuthConfig,
    model: OpenAISubscriptionAuthorizationModel,
    onAuthorized: (OpenAISubscriptionTokens) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val context = LocalContext.current

    LaunchedEffect(config) { model.startIfIdle(config) }

    val phase = model.phase
    LaunchedEffect(phase) {

        (phase as? OpenAISubscriptionAuthorizationModel.Phase.Succeeded)?.let { succeeded ->

            model.cancel()
            onAuthorized(succeeded.tokens)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()

            .padding(start = 24.dp, end = 24.dp, top = 24.dp, bottom = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(spacing.md),
    ) {
        Icon(
            imageVector = Icons.Filled.VerifiedUser,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(40.dp),
        )

        Text(
            text = stringResource(R.string.openai_subscription_sheet_title),
            style = OriveoTheme.typography.title2,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )

        Text(
            text = stringResource(R.string.openai_subscription_sheet_subtitle),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )

        when (phase) {
            is OpenAISubscriptionAuthorizationModel.Phase.Idle,
            is OpenAISubscriptionAuthorizationModel.Phase.Requesting,
            is OpenAISubscriptionAuthorizationModel.Phase.Succeeded,
            -> CircularProgressIndicator(
                modifier = Modifier.padding(vertical = spacing.xl).size(28.dp),
                color = colors.primary,
            )

            is OpenAISubscriptionAuthorizationModel.Phase.AwaitingAuthorization -> {

                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(colors.surfaceInset)
                        .padding(vertical = 14.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = stringResource(R.string.openai_subscription_your_code),
                        style = OriveoTheme.typography.caption,
                        color = colors.textSecondary,
                    )
                    Text(
                        text = phase.authorization.userCode,
                        style = OriveoTheme.typography.title2.copy(
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold,
                        ),
                        color = colors.textPrimary,
                    )
                }

                OriveoPrimaryButton(
                    text = if (model.didOpenVerificationPage) {
                        stringResource(R.string.openai_subscription_open_page_again)
                    } else {
                        stringResource(R.string.openai_subscription_open_page)
                    },
                    onClick = {
                        model.markVerificationPageOpened()
                        openSubscriptionVerificationPage(context, phase.authorization.verificationUrl)
                    },
                    modifier = Modifier.fillMaxWidth(),
                )

                if (model.didOpenVerificationPage) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(spacing.sm),
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            strokeWidth = 2.dp,
                            color = colors.primary,
                        )
                        Text(
                            text = stringResource(R.string.openai_subscription_waiting),
                            style = OriveoTheme.typography.footnote,
                            color = colors.textSecondary,
                        )
                    }
                }
            }

            is OpenAISubscriptionAuthorizationModel.Phase.Failed -> {
                Text(
                    text = stringResource(openAISubscriptionErrorMessageRes(phase.error)),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                )

                if (phase.error.allowsRetry) {
                    OriveoPrimaryButton(
                        text = stringResource(R.string.openai_subscription_try_again),
                        onClick = { model.start(config) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }

        OriveoTextButton(
            text = stringResource(R.string.cancel),
            onClick = {
                model.cancel()
                onDismiss()
            },
            color = colors.textSecondary,
            modifier = Modifier.padding(top = spacing.sm),
        )
    }
}

fun openAISubscriptionErrorMessageRes(error: OpenAISubscriptionError): Int = when (error) {
    is OpenAISubscriptionError.ClientVersionRejected,
    is OpenAISubscriptionError.ConfigurationUnavailable,
    -> R.string.openai_subscription_error_unavailable

    is OpenAISubscriptionError.SubscriptionNotEligible -> R.string.openai_subscription_error_not_eligible
    is OpenAISubscriptionError.Unauthorized -> R.string.openai_subscription_error_expired
    is OpenAISubscriptionError.QuotaExhausted -> R.string.openai_subscription_error_quota
    is OpenAISubscriptionError.CodeExpired -> R.string.openai_subscription_error_code_expired
    is OpenAISubscriptionError.AccessDenied -> R.string.openai_subscription_error_denied
    is OpenAISubscriptionError.AuthorizationPending,
    is OpenAISubscriptionError.SlowDown,
    -> R.string.openai_subscription_error_waiting_browser

    is OpenAISubscriptionError.Transport,
    is OpenAISubscriptionError.Upstream,
    -> R.string.openai_subscription_error_unreachable
}
