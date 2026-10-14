package ai.oriveo.community.feature.providers.relay

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.feature.providers.detail.RelayDetailIconTone

/*
 * Pure-function board model for the add relay "Manual setup" (ManualSetup board).
 * Same shell as quick setup step 1, sharing the address and all keys; the protocol row / collapsible group rows / failure card / reveal function reuse those of edit connection.
 * The view only renders the output of [RelayManualSetupBoardModel.make]; the tappability criterion lives only here.
 */

internal enum class RelayManualBlock { RequestUrl, ApiKeys, Model, ConnectionName, ProtocolCard, Advanced, Failure }

/** Right of the collapsible group title: current auth method value and filled count (0 = "Not set"). */
internal data class RelayManualSummary(@StringRes val authRes: Int, val filledCount: Int)

internal data class RelayManualPrimary(@StringRes val titleRes: Int, val enabled: Boolean, val loading: Boolean)

/** One failure card: a localized reason + redacted technical details. Any input change dismisses the whole card via the flow. */
internal data class RelayManualFailure(
    val message: String,
    val presentation: RelayEditFailurePresentation?,
    /** Persisting itself failed (not a verification failure): no "Save anyway (unverified)", and the primary button stays "Verify again". */
    val persistFailed: Boolean = false,
    /** The error obtained from the same exception via ErrorMapper: failure card title and severity (same source as on iOS). */
    val error: ai.oriveo.community.core.model.OriveoError? = null,
)

internal data class RelayManualSetupInput(
    val endpoint: String,
    val keys: List<RelaySetupKeyRow>,
    val model: String,
    val connectionName: String,
    val transport: RelayTransport,
    val authMode: RelayAuthMode,
    val userAgent: String,
    val headers: List<RelayKeyValue>,
    val queryParams: List<RelayKeyValue>,
    /** All results of the shared validation (including silent required-field ones). */
    val issues: List<RelayFormValidation.FieldIssue>,
    val advancedExpanded: Boolean,
    val isValidating: Boolean,
    val failure: RelayManualFailure?,
    /** Already persisted, waiting to leave the page (completion latch). */
    val completed: Boolean,
    val modelPlaceholder: String,
)

internal data class RelayManualSetupBoard(
    val blocks: List<RelayManualBlock>,
    @StringRes val heroLabelRes: Int,
    @StringRes val heroTitleRes: Int,
    @StringRes val heroSubtitleRes: Int,
    @StringRes val heroTagRes: Int,
    /** Top-left text button "Use quick setup instead"; this page has no back button. */
    @StringRes val leadingActionRes: Int,
    @StringRes val requestUrlTitleRes: Int,
    @DrawableRes val requestUrlIcon: Int,
    val willRequest: String?,
    val keys: List<RelaySetupKeyRow>,
    /** Address / key notices, shown below the key block. */
    val keyIssues: List<RelayFormValidation.FieldIssue>,
    @StringRes val modelTitleRes: Int,
    @DrawableRes val modelIcon: Int,
    val modelPlaceholder: String,
    @StringRes val modelFootnoteRes: Int,
    @StringRes val connectionNameTitleRes: Int,
    @DrawableRes val connectionNameIcon: Int,
    @StringRes val connectionNameSlotLabelRes: Int,
    val connectionNamePlaceholder: String?,
    @StringRes val connectionNameFootnoteRes: Int,
    val protocolGroup: RelayEditGroup,
    val advancedGroup: RelayEditGroup,
    val advancedSummary: RelayManualSummary,
    val status: RelayEditStatus?,
    @StringRes val failureNoteRes: Int,
    val primary: RelayManualPrimary,
)

internal object RelayManualSetupBoardModel {

    /** Candidates for the default protocol = the same set as edit connection. */
    val protocolOptions: List<RelayTransport> = RelayTransport.entries

    fun make(input: RelayManualSetupInput): RelayManualSetupBoard {
        val displayable = RelayFormValidation.displayableIssues(input.issues)
        val kvFields = setOf(RelayFormValidation.Field.Headers, RelayFormValidation.Field.QueryParams)
        val kvIssues = displayable.filter { it.field in kvFields }
        val filled = (if (input.userAgent.isBlank()) 0 else 1) +
            input.headers.count { it.key.isNotBlank() } +
            input.queryParams.count { it.key.isNotBlank() }
        val authRow = RelayEditRow(
            id = RelayEditRowId.Authentication,
            titleRes = R.string.relay_advanced_auth_mode,
            icon = R.drawable.ph_key_duotone,
            tone = RelayDetailIconTone.Orange,
            valueRes = relayAuthModeMenuValueRes(input.authMode),
            // The connection does not exist yet: no "keys are managed on the detail page" footnote.
            hasMenu = true,
        )
        val failure = input.failure
        return RelayManualSetupBoard(
            blocks = buildList {
                add(RelayManualBlock.RequestUrl)
                add(RelayManualBlock.ApiKeys)
                add(RelayManualBlock.Model)
                add(RelayManualBlock.ConnectionName)
                add(RelayManualBlock.ProtocolCard)
                add(RelayManualBlock.Advanced)
                if (failure != null) add(RelayManualBlock.Failure)
            },
            heroLabelRes = R.string.relay_setup_hero_label,
            heroTitleRes = R.string.relay_setup_hero_title,
            heroSubtitleRes = R.string.relay_manual_hero_subtitle,
            heroTagRes = R.string.relay_manual_setup,
            leadingActionRes = R.string.relay_manual_use_quick_setup,
            requestUrlTitleRes = R.string.relay_field_endpoint,
            requestUrlIcon = R.drawable.ph_link,
            willRequest = RelayEditBoardModel.willRequest(input.endpoint, RelayConnectionSecurityMode.RemoteHttps),
            keys = input.keys,
            keyIssues = displayable - kvIssues.toSet(),
            modelTitleRes = R.string.relay_default_model_label,
            modelIcon = R.drawable.ph_squares_four,
            modelPlaceholder = input.modelPlaceholder,
            modelFootnoteRes = R.string.relay_manual_model_footnote,
            connectionNameTitleRes = R.string.relay_manual_connection_name,
            connectionNameIcon = R.drawable.ph_pencil_simple,
            connectionNameSlotLabelRes = R.string.relay_setup_key_name,
            connectionNamePlaceholder = ProviderRepository.relayDomainNameFromEndpoint(input.endpoint),
            connectionNameFootnoteRes = R.string.relay_manual_connection_name_footnote,
            protocolGroup = RelayEditGroup(
                id = RelayEditGroupId.ProtocolAuth,
                titleRes = R.string.relay_advanced_transport,
                collapsible = false,
                expanded = true,
                rows = listOf(RelayEditBoardModel.defaultProtocolRow(input.transport)),
            ),
            advancedGroup = RelayEditGroup(
                id = RelayEditGroupId.Headers,
                titleRes = R.string.relay_manual_group_auth_headers,
                collapsible = true,
                expanded = input.advancedExpanded || kvIssues.isNotEmpty(),
                filledCount = filled,
                rows = listOf(authRow) + RelayEditBoardModel.keyValueRows(input.headers, input.queryParams, kvIssues),
            ),
            advancedSummary = RelayManualSummary(relayAuthModeMenuValueRes(input.authMode), filled),
            status = failure?.let { RelayEditStatus.Failed(it.message, it.presentation, canSaveUnverified = !input.completed && !it.persistFailed, error = it.error) },
            failureNoteRes = R.string.relay_manual_not_saved_yet,
            primary = RelayManualPrimary(
                titleRes = if (failure != null) R.string.relay_manual_validate_again else R.string.relay_validate_and_save,
                // Tap acceptance uses the same criterion as tappability (BOARD-MANUAL-11): the flow only trusts this value.
                enabled = !input.isValidating && !input.completed && input.issues.isEmpty() && input.model.isNotBlank(),
                loading = input.isValidating,
            ),
        )
    }

    /** Effective protocol: the selected one if chosen; for auto with a protocol path in the address (e.g. /v1/messages), the one derived from the address; otherwise still auto. */
    fun effectiveTransport(transport: RelayTransport, endpoint: String): RelayTransport {
        if (transport != RelayTransport.Auto) return transport
        return runCatching { RelayEndpointResolver.describe(endpoint).explicitTransport }.getOrNull() ?: RelayTransport.Auto
    }

    /** The analytics relay_kind uses the same derivation as the persisted relayKind (reported as auto when the address cannot form a request). */
    fun telemetryKind(transport: RelayTransport, endpoint: String): RelayKind =
        RelayKindDefaults.inferKind(RelayRequestedConfig(transport = effectiveTransport(transport, endpoint)))

    /**
     * Persisted configuration: the same shape as quick setup "add manually after connection failure"; protocol / auth come from the user's choice, `stream = true`,
     * Responses carries do-not-store and the Codex identity, auto carries do-not-store; headers / query parameters / UA come from the collapsible group; the connection-level modelID is empty.
     */
    fun requested(
        transport: RelayTransport,
        authMode: RelayAuthMode,
        userAgent: String,
        headers: List<RelayKeyValue>,
        queryParams: List<RelayKeyValue>,
    ): RelayRequestedConfig = RelayRequestedConfig(
        transport = transport,
        authMode = authMode,
        securityMode = RelayConnectionSecurityMode.RemoteHttps,
        modelID = null,
        stream = true,
        disableResponseStorage = true.takeIf { transport == RelayTransport.Auto || transport == RelayTransport.OpenAIResponses },
        codexCompatIdentity = true.takeIf { transport == RelayTransport.OpenAIResponses },
        headers = headers.cleanRelayAdvancedPairs(),
        queryParams = queryParams.cleanRelayAdvancedPairs(),
        customUserAgent = userAgent.trim().takeIf { it.isNotEmpty() },
    )
}

/**
 * Placeholder of the model input slot: the OpenAI flagship default model delivered by online metadata (backend authoritative), falling back to a built-in constant when not ready
 * (do not use prompts such as "Enter model ID"). Shared by manual setup and the "Add model manually" page.
 */
internal object RelayFlagshipModel {
    const val FALLBACK = "gpt-5.6-sol"

    fun current(): String =
        runCatching { MetadataClient.defaultModelId(ProviderKind.OpenAI) }.getOrNull()?.takeIf { it.isNotBlank() } ?: FALLBACK
}

/** Font size ratio of the shrink tiers of "Use quick setup instead". */
internal const val RELAY_QUICK_SETUP_REDUCED_SCALE = 0.85f

/** The three tiers of "Use quick setup instead": no tier truncates or uses an ellipsis. */
enum class RelayQuickSetupButtonTier(val scale: Float, val maxLines: Int) {
    FullSizeOneLine(1f, 1),
    ReducedOneLine(RELAY_QUICK_SETUP_REDUCED_SCALE, 1),
    // Tier 3 has no line limit: wraps as needed and never truncates.
    ReducedWrapping(RELAY_QUICK_SETUP_REDUCED_SCALE, Int.MAX_VALUE),
}

/** Tier selection (BOARD-MANUAL-15): the input available width and the one-line text width at 100% font size (same unit). */
fun relayQuickSetupButtonTier(availableWidth: Float, fullSizeLineWidth: Float): RelayQuickSetupButtonTier = when {
    fullSizeLineWidth <= availableWidth -> RelayQuickSetupButtonTier.FullSizeOneLine
    fullSizeLineWidth * RELAY_QUICK_SETUP_REDUCED_SCALE <= availableWidth -> RelayQuickSetupButtonTier.ReducedOneLine
    else -> RelayQuickSetupButtonTier.ReducedWrapping
}
