package ai.oriveo.community.feature.chat.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.feature.chat.ChatConversationIssue
import ai.oriveo.community.feature.chat.ChatConversationIssueKind
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun ConversationIssueBanner(
    issue: ChatConversationIssue,
    providerName: String?,
    onPrimaryAction: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val title = when (issue.kind) {
        ChatConversationIssueKind.NoProvidersAvailable -> stringResource(R.string.chat_issue_no_provider_title)
        ChatConversationIssueKind.ProviderMissing -> stringResource(R.string.chat_issue_provider_missing_title)
        ChatConversationIssueKind.ModelMissing,
        ChatConversationIssueKind.ModelUnavailable -> stringResource(R.string.chat_issue_model_missing_title)
    }
    val message = when (issue.kind) {
        ChatConversationIssueKind.NoProvidersAvailable -> stringResource(R.string.chat_issue_no_provider_message)
        ChatConversationIssueKind.ProviderMissing -> stringResource(
            R.string.chat_issue_provider_missing_message,
            providerName ?: stringResource(R.string.providers_title),
        )
        ChatConversationIssueKind.ModelMissing,
        ChatConversationIssueKind.ModelUnavailable -> stringResource(R.string.chat_issue_model_missing_message)
    }
    val actionLabel = if (issue.canRepairFromModelPicker) {
        stringResource(R.string.switch_model)
    } else {
        stringResource(R.string.back)
    }

    OriveoCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Text(
                text = title,
                style = OriveoTheme.typography.title3,
                color = if (issue.isBlocking) colors.warning else colors.textPrimary,
            )
            Text(
                text = message,
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
            OriveoPrimaryButton(
                text = actionLabel,
                onClick = onPrimaryAction,
            )
        }
    }
}
