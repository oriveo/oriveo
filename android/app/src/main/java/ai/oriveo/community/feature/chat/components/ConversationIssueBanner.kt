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
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.ModelRetirement
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
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

/** Banner content for a deleted conversation connection: title + "<stored model> is no longer available" + "Choose model". */
internal data class ProviderMissingBannerContent(
    @StringRes val titleRes: Int,
    @StringRes val messageRes: Int,
    val modelName: String,
    @StringRes val actionRes: Int,
)

internal fun providerMissingBannerContent(issue: ChatConversationIssue): ProviderMissingBannerContent? =
    issue.missingProviderModelName
        ?.takeIf { issue.kind == ChatConversationIssueKind.ProviderMissing }
        ?.let { modelName ->
            ProviderMissingBannerContent(
                titleRes = R.string.chat_issue_provider_missing_title,
                messageRes = R.string.chat_issue_provider_missing_message,
                modelName = modelName,
                actionRes = R.string.chat_model_removed_choose,
            )
        }

/**
 * Banner content for a conversation whose provider model was retired or is missing: "<name> was retired" + a button.
 * When the successor is among the user's enabled models: "Switch to X" carrying [switchTarget]; otherwise "Choose model" opens the picker.
 */
internal data class ModelRetiredBannerContent(
    @StringRes val messageRes: Int,
    val modelName: String,
    @StringRes val actionRes: Int,
    /** Button text argument (the successor's name); null for "Choose model". */
    val actionArg: String?,
    /** Non-null: the target of the one-tap switch; null: open the model picker. */
    val switchTarget: SwitchTarget?,
) {
    data class SwitchTarget(val providerId: String, val modelId: String)
}

internal fun modelRetiredBannerContent(
    issue: ChatConversationIssue,
    provider: Provider?,
    lookup: ModelDisplayLookup,
): ModelRetiredBannerContent? {
    val retirement = issue.modelRetirement ?: return null
    val successor = retirement.successorId
        ?.takeIf { retirement.status == ModelRetirement.Status.Retired && provider != null }
        ?.let { successorId ->
            // The successor is often the canonical id while the enabled one is its dated snapshot: match by id or canonical, and switch using the enabled id.
            val enabled = ProviderSelectionSnapshot.enabledModels(provider)
            enabled.firstOrNull { it.id == successorId } ?: enabled.firstOrNull { it.canonicalModelId == successorId }
        }
    if (provider == null || successor == null) {
        return ModelRetiredBannerContent(
            messageRes = R.string.chat_model_retired_banner,
            modelName = retirement.displayName,
            actionRes = R.string.chat_model_removed_choose,
            actionArg = null,
            switchTarget = null,
        )
    }
    val successorName = lookup.modelDisplayName(provider.id, successor.id, fallback = successor.name) ?: successor.id
    return ModelRetiredBannerContent(
        messageRes = R.string.chat_model_retired_banner,
        modelName = retirement.displayName,
        actionRes = R.string.chat_model_retired_switch_to,
        actionArg = successorName,
        switchTarget = ModelRetiredBannerContent.SwitchTarget(provider.id, successor.id),
    )
}

@Composable
internal fun ConversationIssueBanner(
    issue: ChatConversationIssue,
    providerName: String?,
    onPrimaryAction: () -> Unit,
    retiredContent: ModelRetiredBannerContent? = null,
) {
    relayModelRemovedBannerContent(issue)?.let { content ->
        RelayModelRemovedBanner(content, onPrimaryAction)
        return
    }
    providerMissingBannerContent(issue)?.let { content ->
        ProviderMissingBanner(content, onPrimaryAction)
        return
    }
    retiredContent?.let { content ->
        ModelRetiredBanner(content, onPrimaryAction)
        return
    }
    val colors = OriveoTheme.colors
    val title = when (issue.kind) {
        ChatConversationIssueKind.NoProvidersAvailable -> stringResource(R.string.chat_issue_no_provider_title)
        ChatConversationIssueKind.ProviderMissing -> stringResource(R.string.chat_issue_provider_missing_title)
        ChatConversationIssueKind.ModelMissing,
        ChatConversationIssueKind.ModelUnavailable,
        ChatConversationIssueKind.ModelRetired -> stringResource(R.string.chat_issue_model_missing_title)
    }
    val message = when (issue.kind) {
        ChatConversationIssueKind.NoProvidersAvailable -> stringResource(R.string.chat_issue_no_provider_message)
        ChatConversationIssueKind.ProviderMissing -> stringResource(
            R.string.chat_issue_provider_missing_message,
            providerName ?: stringResource(R.string.providers_title),
        )
        ChatConversationIssueKind.ModelMissing,
        ChatConversationIssueKind.ModelUnavailable,
        ChatConversationIssueKind.ModelRetired -> stringResource(R.string.chat_issue_model_missing_message)
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

@Composable
private fun ProviderMissingBanner(
    content: ProviderMissingBannerContent,
    onPrimaryAction: () -> Unit,
) {
    OriveoCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Text(
                text = stringResource(content.titleRes),
                style = OriveoTheme.typography.title3,
                color = OriveoTheme.colors.textPrimary,
            )
            Text(
                text = stringResource(content.messageRes, content.modelName),
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

@Composable
private fun ModelRetiredBanner(
    content: ModelRetiredBannerContent,
    onPrimaryAction: () -> Unit,
) {
    OriveoCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Text(
                text = stringResource(content.messageRes, content.modelName),
                style = OriveoTheme.typography.caption,
                color = OriveoTheme.colors.textSecondary,
            )
            OriveoPrimaryButton(
                text = content.actionArg?.let { stringResource(content.actionRes, it) } ?: stringResource(content.actionRes),
                onClick = onPrimaryAction,
            )
        }
    }
}
