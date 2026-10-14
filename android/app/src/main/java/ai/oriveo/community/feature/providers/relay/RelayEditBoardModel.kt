package ai.oriveo.community.feature.providers.relay

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.isCleartext
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.feature.providers.detail.RelayDetailIconTone
import ai.oriveo.community.feature.providers.detail.RelayEditPlan

/*
 * Row model of the edit-connection board (EditConnection).
 * The view renders only the output of [RelayEditBoardModel.make]; button text, enabled state, groups and rows, and the save shape are all decided here,
 * with no separate criteria written in the Composable.
 */

internal enum class RelayEditGroupId { Connection, ProtocolAuth, Channel, Headers, Compatibility }

internal enum class RelayEditRowId {
    RequestUrl,
    EngineAddress,
    ConnectionSecurity,
    DefaultProtocol,
    Authentication,
    Channel,
    UserAgent,
    Header,
    QueryParam,
    AddEntry,
    Stream,
    ServiceTier,
    DisableResponseStorage,
}

/** A piece of localized text; any [RelayEditText] inside [args] is resolved by the view first and then substituted. */
internal data class RelayEditText(@StringRes val res: Int, val args: List<Any> = emptyList())

internal data class RelayEditRow(
    val id: RelayEditRowId,
    @StringRes val titleRes: Int,
    @DrawableRes val icon: Int? = null,
    val tone: RelayDetailIconTone? = null,
    /** Current value on the right of a menu / read-only row. */
    @StringRes val valueRes: Int? = null,
    val footnote: RelayEditText? = null,
    /** Has options to choose from (shows a menu arrow). */
    val hasMenu: Boolean = false,
    /** Index of a header / query-parameter row in its own list. */
    val index: Int = -1,
    /** Value slot is masked by default with an eye toggle (headers). */
    val masked: Boolean = false,
    /** Validation hint under a row: attached only below the last header / query-parameter row of each list. */
    val issues: List<RelayFormValidation.FieldIssue> = emptyList(),
)

internal data class RelayEditGroup(
    val id: RelayEditGroupId,
    @StringRes val titleRes: Int,
    val collapsible: Boolean,
    val expanded: Boolean,
    /** Number of filled entries to the right of the group title; null = not shown. */
    val filledCount: Int? = null,
    val rows: List<RelayEditRow>,
)

/** One state shared by the status row and the failure card; null = nothing shown. */
internal sealed interface RelayEditStatus {
    data object Reconnecting : RelayEditStatus
    data object Testing : RelayEditStatus
    data object Verified : RelayEditStatus
    data class Failed(
        val message: String,
        val presentation: RelayEditFailurePresentation?,
        /** "Save anyway (unverified)" exists only after a save-verification failure; not after a test failure. */
        val canSaveUnverified: Boolean,
        /** Source of the failure card's title and severity (the underlying error); null = generic title. */
        val error: OriveoError? = null,
    ) : RelayEditStatus

    companion object {
        fun of(
            isReconnecting: Boolean,
            isTesting: Boolean,
            result: RelayConnectionTestResult?,
            canSaveUnverified: Boolean,
        ): RelayEditStatus? = when {
            isReconnecting -> Reconnecting
            isTesting -> Testing
            result == null -> null
            result.isSuccess -> Verified
            else -> Failed(result.message, result.failurePresentation, canSaveUnverified, result.error)
        }
    }
}

internal data class RelayEditActionBar(
    val testEnabled: Boolean,
    @StringRes val primaryTitleRes: Int,
    val primaryEnabled: Boolean,
    /** The primary button sends verification; same answer as [RelayEditPlan.requiresVerification] on the save path. */
    val primaryValidates: Boolean,
)

internal data class RelayEditBoard(
    val isLocal: Boolean,
    @StringRes val titleRes: Int,
    /** Page header subtitle = connection display name. */
    val subtitle: String,
    val groups: List<RelayEditGroup>,
    /** Validation hints kept under the connection card (address, connection security, key; header-type hints too when the page has no header group). */
    val connectionIssues: List<RelayFormValidation.FieldIssue>,
    val status: RelayEditStatus?,
    val actionBar: RelayEditActionBar,
)

/** Edit page draft: the page can change only address, transport, auth, the three compatibility items, UA, and headers / query parameters. */
internal data class RelayEditDraft(
    val endpoint: String,
    val requested: RelayRequestedConfig,
    val headers: List<RelayKeyValue>,
    val queryParams: List<RelayKeyValue>,
) {
    /** The config handed to save / test: blanks cleared, empty tables become null. */
    fun cleanedRequested(): RelayRequestedConfig = requested.copy(
        serviceTier = requested.serviceTier?.trim()?.takeIf { it.isNotEmpty() },
        customUserAgent = requested.customUserAgent?.trim()?.takeIf { it.isNotEmpty() },
        headers = headers.cleanRelayAdvancedPairs(),
        queryParams = queryParams.cleanRelayAdvancedPairs(),
    )

    companion object {
        /** Start a draft from the saved connection; [sampleModelID] is the verification sample and stays in memory only. */
        fun from(provider: Provider, sampleModelID: String?): RelayEditDraft {
            val requested = (provider.relayRequested ?: RelayKindDefaults.makeRequested(
                provider.relayKind ?: RelayKind.OpenAICompatible,
            )).let { it.copy(modelID = sampleModelID ?: it.modelID) }
            return RelayEditDraft(
                endpoint = provider.baseUrlText.orEmpty(),
                requested = requested,
                headers = requested.headers.orEmpty(),
                queryParams = requested.queryParams.orEmpty(),
            )
        }
    }
}

/**
 * Shape of a save: only fields the page can change come from the draft, everything else comes from the connection currently in the store;
 * connection-level reasoning level and modelID are cleared; Codex identity is kept as is; the probed root address is cleared only when the address really changed.
 */
internal object RelayEditSavePolicy {
    fun savedRequested(
        persisted: Provider,
        candidate: RelayRequestedConfig,
        candidateBaseUrl: String?,
    ): RelayRequestedConfig {
        val base = persisted.relayRequested ?: candidate
        val endpointChanged = RelayEditPlan.endpointChanged(persisted, candidateBaseUrl)
        return base.copy(
            transport = candidate.transport,
            authMode = candidate.authMode,
            serviceTier = candidate.serviceTier?.trim()?.takeIf { it.isNotEmpty() },
            stream = candidate.stream,
            disableResponseStorage = candidate.disableResponseStorage,
            headers = candidate.headers?.cleanRelayAdvancedPairs(),
            queryParams = candidate.queryParams?.cleanRelayAdvancedPairs(),
            customUserAgent = candidate.customUserAgent?.trim()?.takeIf { it.isNotEmpty() },
            reasoningEffort = null,
            // A relay has no default model: newly persisted values are always empty, and the verification sample stays only in the in-memory draft.
            modelID = null,
            resolvedAPIBaseURL = if (endpointChanged) null else base.resolvedAPIBaseURL,
            resolvedAPIBaseURLs = if (endpointChanged) null else base.resolvedAPIBaseURLs,
        )
    }

    /** relayKind is no longer a user option: it is derived from the default transport (auto -> custom, the transport is still stored as auto). */
    fun savedRelayKind(requested: RelayRequestedConfig): RelayKind = RelayKindDefaults.inferKind(requested)
}

internal object RelayEditBoardModel {

    fun make(
        provider: Provider,
        draft: RelayEditDraft,
        status: RelayEditStatus?,
        isSaving: Boolean,
        issues: List<RelayFormValidation.FieldIssue>,
        shownCompatRows: Set<RelayEditRowId> = emptySet(),
        headersExpanded: Boolean = false,
        compatibilityExpanded: Boolean = false,
        baseline: Provider = provider,
    ): RelayEditBoard {
        val requested = draft.requested
        val isLocal = !requested.engineProfile.isNullOrBlank()
        val encrypted = !requested.securityMode.isCleartext
        val showsHeaders = !isLocal || encrypted
        val displayable = RelayFormValidation.displayableIssues(issues)
        val kvFields = setOf(RelayFormValidation.Field.Headers, RelayFormValidation.Field.QueryParams)
        val kvIssues = if (showsHeaders) displayable.filter { it.field in kvFields } else emptyList()
        val connectionIssues = displayable - kvIssues.toSet()

        val groups = buildList {
            add(connectionGroup(draft, isLocal))
            if (isLocal) {
                add(channelGroup(provider, requested, encrypted))
            } else {
                add(protocolAuthGroup(provider, requested))
            }
            if (showsHeaders) add(headersGroup(draft, kvIssues, headersExpanded))
            if (!isLocal) add(compatibilityGroup(provider, draft, shownCompatRows, compatibilityExpanded))
        }

        // Same criterion as saving: "Verify and save" appears only for connection fields the user changed that differ from the current connection.
        val plan = RelayEditPlan.classifyEdit(
            live = provider,
            baseline = baseline,
            candidateRequested = draft.cleanedRequested(),
            candidateBaseUrl = draft.endpoint,
        )
        val reconnecting = status is RelayEditStatus.Reconnecting
        val testing = status is RelayEditStatus.Testing
        val busy = reconnecting || isSaving
        return RelayEditBoard(
            isLocal = isLocal,
            titleRes = R.string.relay_detail_edit_connection,
            subtitle = provider.displayName,
            groups = groups,
            connectionIssues = connectionIssues,
            status = status,
            actionBar = RelayEditActionBar(
                testEnabled = !busy && !testing && draft.endpoint.isNotBlank(),
                primaryTitleRes = if (plan.requiresVerification) R.string.relay_validate_and_save else R.string.save,
                // Tappable to see all validation results (including silent required-field ones, e.g. empty address); displayed text and targets use only displayable.
                primaryEnabled = !busy && issues.isEmpty(),
                primaryValidates = plan.requiresVerification,
            ),
        )
    }

    /** The compatibility group is trimmed by the default transport. */
    fun compatRowsFor(transport: RelayTransport): List<RelayEditRowId> = when (transport) {
        RelayTransport.Auto, RelayTransport.OpenAIResponses ->
            listOf(RelayEditRowId.Stream, RelayEditRowId.ServiceTier, RelayEditRowId.DisableResponseStorage)
        RelayTransport.OpenAIChatCompletions -> listOf(RelayEditRowId.Stream, RelayEditRowId.ServiceTier)
        else -> listOf(RelayEditRowId.Stream)
    }

    /** Compatibility items in effect (on / filled in the store or draft): shown even when the transport does not list them. */
    fun activeCompatRows(provider: Provider, draft: RelayEditDraft): Set<RelayEditRowId> = buildSet {
        val persisted = provider.relayRequested
        if (persisted?.disableResponseStorage == true || draft.requested.disableResponseStorage == true) {
            add(RelayEditRowId.DisableResponseStorage)
        }
        if (!persisted?.serviceTier.isNullOrBlank() || !draft.requested.serviceTier.isNullOrBlank()) {
            add(RelayEditRowId.ServiceTier)
        }
    }

    /** Rows the draft has opened during this edit; they stay until the page is left. */
    fun draftTouchedCompatRows(draft: RelayEditDraft): Set<RelayEditRowId> = buildSet {
        if (draft.requested.disableResponseStorage == true) add(RelayEditRowId.DisableResponseStorage)
        if (!draft.requested.serviceTier.isNullOrBlank()) add(RelayEditRowId.ServiceTier)
    }

    /** Count to the right of the header group title; not shown when 0. */
    fun headersFilledCount(draft: RelayEditDraft): Int? {
        val count = (if (draft.requested.customUserAgent.isNullOrBlank()) 0 else 1) +
            draft.headers.count { it.key.isNotBlank() } +
            draft.queryParams.count { it.key.isNotBlank() }
        return count.takeIf { it > 0 }
    }

    /**
     * Tapping a collapsible group header: while held open by a validation hint it counts as expanded, not collapsed; with no hint it toggles normally.
     */
    fun toggledExpansion(current: Boolean, forcedOpen: Boolean): Boolean = if (forcedOpen) true else !current

    /**
     * Whether the status row / failure card should dismiss the keyboard and scroll to it: yes for the one that appears only after a tap;
     * no when the in-flight one is replaced in place by its result, when the result disappears, or when the state is unchanged.
     */
    fun revealsStatus(previous: RelayEditStatus?, next: RelayEditStatus?): Boolean {
        if (next == null) return false
        if (previous != null && previous::class == next::class) return false
        val wasInFlight = previous is RelayEditStatus.Testing || previous is RelayEditStatus.Reconnecting
        val isResult = next is RelayEditStatus.Verified || next is RelayEditStatus.Failed
        return !(wasInFlight && isResult)
    }

    /** "Will request ..." under the address row: same preview function as the add page; hidden when it cannot be computed. */
    fun willRequest(endpoint: String, securityMode: RelayConnectionSecurityMode): String? =
        RelayEndpointResolver.previewAPIRoot(endpoint, securityMode)?.let { "$it/…" }

    private fun connectionGroup(draft: RelayEditDraft, isLocal: Boolean): RelayEditGroup {
        val requested = draft.requested
        val address = if (isLocal) {
            RelayEditRow(
                id = RelayEditRowId.EngineAddress,
                titleRes = R.string.relay_detail_engine_address,
                icon = R.drawable.ph_link_duotone,
                tone = RelayDetailIconTone.Cyan,
            )
        } else {
            RelayEditRow(
                id = RelayEditRowId.RequestUrl,
                titleRes = R.string.relay_field_endpoint,
                icon = R.drawable.ph_link_duotone,
                tone = RelayDetailIconTone.Cyan,
                footnote = willRequest(draft.endpoint, requested.securityMode)
                    ?.let { RelayEditText(R.string.relay_setup_will_request, listOf(it)) },
            )
        }
        return RelayEditGroup(
            id = RelayEditGroupId.Connection,
            titleRes = R.string.relay_section_connection,
            collapsible = false,
            expanded = true,
            rows = listOf(
                address,
                RelayEditRow(
                    id = RelayEditRowId.ConnectionSecurity,
                    titleRes = R.string.relay_security_mode_label,
                    icon = R.drawable.ph_shield_check_duotone,
                    tone = RelayDetailIconTone.Teal,
                    valueRes = relaySecurityModeTitleRes(requested.securityMode),
                    footnote = RelayEditText(R.string.relay_edit_security_footnote),
                ),
            ),
        )
    }

    private fun protocolAuthGroup(provider: Provider, requested: RelayRequestedConfig): RelayEditGroup =
        RelayEditGroup(
            id = RelayEditGroupId.ProtocolAuth,
            titleRes = R.string.relay_edit_section_protocol_auth,
            collapsible = false,
            expanded = true,
            rows = listOf(defaultProtocolRow(requested.transport), authenticationRow(provider, requested)),
        )

    /** Default transport row: shared by edit-connection and the add page's manual setup. */
    fun defaultProtocolRow(transport: RelayTransport): RelayEditRow = RelayEditRow(
        id = RelayEditRowId.DefaultProtocol,
        titleRes = R.string.relay_edit_default_protocol,
        icon = R.drawable.ph_hard_drives_duotone,
        tone = RelayDetailIconTone.Indigo,
        valueRes = relayTransportMenuValueRes(transport),
        footnote = if (transport == RelayTransport.Auto) {
            RelayEditText(R.string.relay_edit_protocol_auto_footnote)
        } else {
            RelayEditText(R.string.relay_edit_protocol_selected_footnote, listOf(RelayEditText(relayTransportLabelRes(transport))))
        },
        hasMenu = true,
    )

    private fun channelGroup(provider: Provider, requested: RelayRequestedConfig, encrypted: Boolean): RelayEditGroup {
        val section = relayEditChannelSection(requested.engineProfile)
        return RelayEditGroup(
            id = RelayEditGroupId.Channel,
            titleRes = R.string.local_setup_tile_channel,
            collapsible = false,
            expanded = true,
            rows = buildList {
                add(
                    RelayEditRow(
                        id = RelayEditRowId.Channel,
                        titleRes = R.string.local_setup_tile_channel,
                        icon = R.drawable.ph_hard_drives_duotone,
                        tone = RelayDetailIconTone.Indigo,
                        valueRes = relayTransportMenuValueRes(requested.transport),
                        hasMenu = section?.editable == true,
                    ),
                )
                // "Encrypted" and "a plaintext connection cannot carry a key" share one criterion.
                if (encrypted) add(authenticationRow(provider, requested))
            },
        )
    }

    private fun authenticationRow(provider: Provider, requested: RelayRequestedConfig): RelayEditRow {
        // %@ takes the detail page key row's own title key: "API Keys" for several keys, "API Key" for a single one.
        val keysRowTitle = if (RelayKeyBinding.showsKeyUI(provider)) R.string.relay_keys_title else R.string.api_key
        return RelayEditRow(
            id = RelayEditRowId.Authentication,
            titleRes = R.string.relay_advanced_auth_mode,
            icon = R.drawable.ph_key_duotone,
            tone = RelayDetailIconTone.Orange,
            valueRes = relayAuthModeMenuValueRes(requested.authMode),
            footnote = RelayEditText(R.string.relay_edit_auth_footnote, listOf(RelayEditText(keysRowTitle))),
            hasMenu = true,
        )
    }

    private fun headersGroup(
        draft: RelayEditDraft,
        kvIssues: List<RelayFormValidation.FieldIssue>,
        userExpanded: Boolean,
    ): RelayEditGroup = RelayEditGroup(
        id = RelayEditGroupId.Headers,
        titleRes = R.string.relay_section_headers_query,
        collapsible = true,
        expanded = userExpanded || kvIssues.isNotEmpty(),
        filledCount = headersFilledCount(draft),
        rows = keyValueRows(draft.headers, draft.queryParams, kvIssues),
    )

    /**
     * UA -> each header -> each query parameter -> "Add"; hints attach only below the last header / query-parameter row of each list.
     * Shared by edit-connection and the add page's manual setup.
     */
    fun keyValueRows(
        headers: List<RelayKeyValue>,
        queryParams: List<RelayKeyValue>,
        kvIssues: List<RelayFormValidation.FieldIssue>,
    ): List<RelayEditRow> {
        val headerIssues = kvIssues.filter { it.field == RelayFormValidation.Field.Headers }
        val queryIssues = kvIssues.filter { it.field == RelayFormValidation.Field.QueryParams }
        val rows = buildList {
            add(RelayEditRow(id = RelayEditRowId.UserAgent, titleRes = R.string.relay_edit_user_agent))
            headers.indices.forEach { index ->
                add(
                    RelayEditRow(
                        id = RelayEditRowId.Header,
                        titleRes = R.string.relay_edit_headers,
                        index = index,
                        masked = true,
                        issues = if (index == headers.lastIndex) headerIssues else emptyList(),
                    ),
                )
            }
            queryParams.indices.forEach { index ->
                add(
                    RelayEditRow(
                        id = RelayEditRowId.QueryParam,
                        titleRes = R.string.relay_edit_query_params,
                        index = index,
                        issues = if (index == queryParams.lastIndex) queryIssues else emptyList(),
                    ),
                )
            }
            add(RelayEditRow(id = RelayEditRowId.AddEntry, titleRes = R.string.add))
        }
        // A hint must not be dropped even when no anchor row is found (in theory impossible: a hint implies its row); fall back to the last row before "Add".
        val attached = rows.flatMap { it.issues }.toSet()
        val orphan = kvIssues.filterNot { it in attached }
        return if (orphan.isEmpty()) rows else rows.mapIndexed { i, row ->
            if (i == rows.lastIndex - 1) row.copy(issues = row.issues + orphan) else row
        }
    }

    private fun compatibilityGroup(
        provider: Provider,
        draft: RelayEditDraft,
        shownCompatRows: Set<RelayEditRowId>,
        userExpanded: Boolean,
    ): RelayEditGroup {
        val visible = compatRowsFor(draft.requested.transport).toSet() +
            activeCompatRows(provider, draft) + shownCompatRows
        val ordered = listOf(RelayEditRowId.Stream, RelayEditRowId.ServiceTier, RelayEditRowId.DisableResponseStorage)
            .filter { it in visible }
        return RelayEditGroup(
            id = RelayEditGroupId.Compatibility,
            titleRes = R.string.relay_section_request_behavior,
            collapsible = true,
            expanded = userExpanded,
            rows = ordered.map { id ->
                when (id) {
                    RelayEditRowId.Stream -> RelayEditRow(id = id, titleRes = R.string.relay_advanced_stream)
                    RelayEditRowId.ServiceTier -> RelayEditRow(id = id, titleRes = R.string.relay_advanced_service_tier)
                    else -> RelayEditRow(
                        id = id,
                        titleRes = R.string.relay_disable_response_storage_short,
                        footnote = RelayEditText(R.string.relay_disable_response_storage_footnote),
                    )
                }
            },
        )
    }
}
