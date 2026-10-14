package ai.oriveo.community.feature.chat.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.annotation.StringRes
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

/** Content of the banner shown when a relay conversation's model has been removed: one sentence plus "Choose model", no title. */
internal data class RelayModelRemovedBannerContent(
    @StringRes val messageRes: Int,
    val connectionName: String,
    @StringRes val actionRes: Int,
)

internal fun relayModelRemovedBannerContent(issue: ChatConversationIssue): RelayModelRemovedBannerContent? =
    issue.removedConnectionName?.let { connectionName ->
        RelayModelRemovedBannerContent(
            messageRes = R.string.chat_model_removed_banner,
            connectionName = connectionName,
            actionRes = R.string.chat_model_removed_choose,
        )
    }

@Composable
internal fun ConversationIssueBanner(
    issue: ChatConversationIssue,
    providerName: String?,
    onPrimaryAction: () -> Unit,
) {
    relayModelRemovedBannerContent(issue)?.let { content ->
        RelayModelRemovedBanner(content, onPrimaryAction)
        return
    }
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

@Composable
private fun RelayModelRemovedBanner(
    content: RelayModelRemovedBannerContent,
    onPrimaryAction: () -> Unit,
) {
    OriveoCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Text(
                text = stringResource(content.messageRes, content.connectionName),
                style = OriveoTheme.typography.caption,
                color = OriveoTheme.colors.textSecondary,
            )
            OriveoPrimaryButton(
                text = stringResource(content.actionRes),
                onClick = onPrimaryAction,
            )
        }
    }
}
