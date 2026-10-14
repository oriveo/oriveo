package ai.oriveo.community.feature.providers.detail

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayAvatarChoiceStore
import ai.oriveo.community.core.model.RelayAvatarPickerCell
import ai.oriveo.community.core.model.RelayAvatarResolver
import ai.oriveo.community.core.model.RelayAvatarResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ProviderEffectiveStatusKind
import ai.oriveo.community.core.model.effectiveStatusKind
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.provider.RelayModelFallback
import ai.oriveo.community.core.provider.LocalEngineChannels
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.relay.RelayWebFragmentStore
import ai.oriveo.community.core.provider.wireName
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import ai.oriveo.community.feature.providers.relay.relayTransportLabelRes

/**
 * Actions that can be triggered on the detail board; the four single-entry actions (rename / change key / default model / delete) appear only here.
 * Tapping the key row opens the keys page ([OpenKeys]); replacing a key happens on the keys page; [EditKey] is the existing sheet used by the per-key "Replace key" action.
 */
enum class RelayDetailAction {
    Rename, EditConnection, EditKey, OpenKeys, RemoveStoredKey, OpenModelLibrary, OpenWebSearch, OpenParameters, Redetect, Delete,
    /** Recovery card "Re-verify": uses the existing re-sync path and opens no page. */
    Reverify,
    /** Tapping the detail header avatar: opens the "Change icon" picker (relays only). */
    ChangeIcon,
}

enum class RelayDetailRowId { RequestUrl, ApiKey, DefaultProtocol, BasePaths, EngineAddress, Engine, Channel, ModelLibrary, WebSearch, Thinking, Parameters }

/**
 * Color tokens for detail page icons. [Identity] is the connection identity color (one each for relay / local), reserved for the header;
 * the two Capability* tokens reuse the capability palette, and the other five are dedicated to detail rows.
 */
enum class RelayDetailIconTone { Identity, Teal, Cyan, Indigo, Orange, Rose, CapabilityWebSearch, CapabilityReasoning }

/** Color of the large header icon: the identity color, not varied per row. */
val relayDetailHeaderIconTone: RelayDetailIconTone = RelayDetailIconTone.Identity

/** Leading row icons are colored per row; null = the row has no leading icon. */
fun relayDetailRowIconTone(id: RelayDetailRowId): RelayDetailIconTone? = when (id) {
    RelayDetailRowId.ModelLibrary -> RelayDetailIconTone.Teal
    RelayDetailRowId.RequestUrl, RelayDetailRowId.EngineAddress -> RelayDetailIconTone.Cyan
    RelayDetailRowId.DefaultProtocol, RelayDetailRowId.Channel -> RelayDetailIconTone.Indigo
    RelayDetailRowId.ApiKey -> RelayDetailIconTone.Orange
    RelayDetailRowId.Engine, RelayDetailRowId.Parameters -> RelayDetailIconTone.Rose
    RelayDetailRowId.WebSearch -> RelayDetailIconTone.CapabilityWebSearch
    RelayDetailRowId.Thinking -> RelayDetailIconTone.CapabilityReasoning
    RelayDetailRowId.BasePaths -> null
}

/** Leading row icon; the parameters row uses a thermometer, which must not share the shape of the top-right "Edit connection" slider. */
@DrawableRes
fun relayDetailRowIcon(id: RelayDetailRowId): Int? = when (id) {
    RelayDetailRowId.RequestUrl, RelayDetailRowId.EngineAddress -> R.drawable.ph_link_duotone
    RelayDetailRowId.ApiKey -> R.drawable.ph_key_duotone
    RelayDetailRowId.DefaultProtocol, RelayDetailRowId.Channel -> R.drawable.ph_hard_drives_duotone
    RelayDetailRowId.Engine -> R.drawable.ph_plug_duotone
    RelayDetailRowId.ModelLibrary -> R.drawable.ph_database_duotone
    RelayDetailRowId.Thinking -> R.drawable.ph_brain_duotone
    RelayDetailRowId.WebSearch -> R.drawable.ph_globe_duotone
    RelayDetailRowId.Parameters -> R.drawable.ph_thermometer_simple
    RelayDetailRowId.BasePaths -> null
}

/** One action of the recovery card; while [running] the row shows a spinner and is not tappable (re-verification in flight). */
data class RelayRecoveryAction(
    val action: RelayDetailAction,
    @StringRes val titleRes: Int,
    @DrawableRes val iconRes: Int,
    val running: Boolean = false,
    val enabled: Boolean = true,
)

/**
 * Connection-issue recovery card for relay / local: official providers still use [ProviderConnectionIssueRecoveryCard].
 * When [titleAction] is non-null the title row is tappable (missing key); [reason] is the unlocalized lastError and the view localizes it.
 */
data class RelayRecoveryCard(
    @StringRes val titleRes: Int,
    @DrawableRes val titleIconRes: Int,
    val titleAction: RelayDetailAction?,
    val reason: String?,
    val actions: List<RelayRecoveryAction>,
)

/** One item of the root address row: protocol legend name (literal, not translated) + path segment of the root address. */
data class RelayDetailBasePath(val protocol: RelayBoardProtocol, val path: String)

/**
 * One board row. [value] is an untranslated literal (address, mask, model id, engine name); [valueRes] / [valueArgs]
 * are localized values; [trailingRes] is the trailing status; [action] is the tap action, null = not tappable and no arrow.
 */
data class RelayDetailRow(
    val id: RelayDetailRowId,
    @StringRes val titleRes: Int,
    val value: String? = null,
    @StringRes val valueRes: Int? = null,
    val valueArgs: List<Any> = emptyList(),
    @StringRes val trailingRes: Int? = null,
    val action: RelayDetailAction? = null,
    val secondaryAction: RelayDetailAction? = null,
    val basePaths: List<RelayDetailBasePath> = emptyList(),
    /** Title row "API Keys · N keys" when the key row has 2 or more keys; null = single-row form. */
    val keyCount: Int? = null,
    /** The first [RelayKeysBoardModel.INLINE_LIMIT] keys shown inline in the key row. */
    val inlineKeys: List<RelayKeysBoardRow> = emptyList(),
    /** Number of keys beyond the inline limit; when > 0 an "N more" row is added. */
    val moreKeys: Int = 0,
)

data class RelayDetailButton(
    @StringRes val textRes: Int,
    val action: RelayDetailAction,
    val enabled: Boolean = true,
    val loading: Boolean = false,
)

/** Structure of the relay / local detail board (RelayDetail / LocalDetail): the Screen only renders it and no longer assembles criteria itself. */
data class RelayDetailBoard(
    val isLocal: Boolean,
    /** Relay avatar (shared resolver function); null for local, where the header keeps the original icon. */
    val avatar: RelayAvatarResult?,
    /** Rename pencil next to the name; the local header is unchanged. */
    val showsRenamePencil: Boolean,
    /** Header status line model count = enabled ∪ catalog, deduplicated (same on all clients). */
    val modelCount: Int,
    /** Last check time; when null the status line only shows the model count. */
    val lastCheckedAt: Long?,
    val headerActions: List<RelayDetailAction>,
    val connectionRows: List<RelayDetailRow>,
    val modelRows: List<RelayDetailRow>,
    val buttons: List<RelayDetailButton>,
    @StringRes val footnoteRes: Int,
    /** Whether the detail header avatar opens the "Change icon" picker: relays only; the local header is unchanged. */
    val avatarPickable: Boolean = false,
    /** Picker cells (brand? -> ten icons -> letter?); the one cell equal to [avatar] is the selected state. */
    val avatarPickerCells: List<RelayAvatarPickerCell> = emptyList(),
)

object RelayDetailBoardModel {
    /** Scope is limited to the custom LLM family: Relay and local connections (non-null engineProfile); official and subscription connections are unchanged. */
    fun appliesTo(provider: Provider): Boolean = provider.kind == ProviderKind.Relay

    /** The old settings area's "Connection settings" and "Delete" rows: in board form these entries become the header button and the bottom button. */
    fun showsLegacySettingsRows(provider: Provider): Boolean = !appliesTo(provider)

    /** "Set as default" in the model row menu: in board form the default model is changed only in the model card. */
    fun offersSetDefaultInModelMenu(provider: Provider): Boolean = !appliesTo(provider)

    /** Tapping a picker cell: writes the on-device choice (brand cell = remove); avatars subscribed to the store redraw immediately. */
    fun pickAvatar(provider: Provider, cell: RelayAvatarPickerCell) =
        RelayAvatarChoiceStore.select(provider.id, cell.choice)

    fun isLocal(provider: Provider): Boolean = !provider.relayRequested?.engineProfile.isNullOrBlank()

    fun build(
        provider: Provider,
        isRedetecting: Boolean,
        lastUsedModelRef: LastUsedModelRef? = null,
        webFragmentStore: RelayWebFragmentStore = RelayWebFragmentStore.shared,
        avatarChoice: String? = RelayAvatarChoiceStore.choice(provider.id),
    ): RelayDetailBoard {
        val local = isLocal(provider)
        val requested = provider.relayRequested
        val enabledIds = provider.models.map { it.id }.distinct()
        val catalogTotal = (enabledIds + provider.catalogModels.map { it.id }).distinct().size
        val moreToAdd = catalogTotal - enabledIds.size
        val defaultTransport = relayConnectionDefaultTransport(requested) ?: RelayTransport.Auto

        val connectionRows = if (local) {
            listOf(
                RelayDetailRow(
                    RelayDetailRowId.EngineAddress,
                    R.string.relay_detail_engine_address,
                    value = provider.baseUrlText.orEmpty(),
                    action = RelayDetailAction.EditConnection,
                ),
                RelayDetailRow(RelayDetailRowId.Engine, R.string.relay_detail_engine_detected, value = engineDisplayName(requested?.engineProfile.orEmpty())),
                channelRow(requested),
                apiKeyRow(provider),
            )
        } else {
            val basePaths = basePaths(requested)
            listOfNotNull(
                // Tapping the address row opens connection editing, the same destination as the default protocol row (tentatively following iOS).
                RelayDetailRow(
                    RelayDetailRowId.RequestUrl,
                    R.string.request_url_label,
                    value = provider.baseUrlText.orEmpty(),
                    action = RelayDetailAction.EditConnection,
                ),
                apiKeyRow(provider),
                RelayDetailRow(
                    RelayDetailRowId.DefaultProtocol,
                    R.string.relay_detail_default_protocol,
                    valueRes = defaultTransport.let { if (it == RelayTransport.Auto) R.string.relay_detail_protocol_auto_per_model else protocolValueRes(it) },
                    action = RelayDetailAction.EditConnection,
                ),
                basePaths.takeIf { it.isNotEmpty() }?.let {
                    RelayDetailRow(RelayDetailRowId.BasePaths, R.string.relay_detail_base_paths, basePaths = it)
                },
            )
        }

        val modelRows = listOfNotNull(
            RelayDetailRow(
                RelayDetailRowId.ModelLibrary,
                R.string.model_library,
                valueRes = if (local) R.string.relay_detail_library_summary_local else R.string.relay_detail_library_summary,
                valueArgs = listOf(enabledIds.size, moreToAdd),
                action = RelayDetailAction.OpenModelLibrary,
            ),
            // Relays add a "web search" row under the model library (local engines have none): status reads the effective profile, including legacy-field read-time mapping.
            if (local) null else RelayDetailRow(
                RelayDetailRowId.WebSearch,
                R.string.web_search,
                valueRes = R.string.relay_web_row_subtitle,
                trailingRes = if (webFragmentStore.effective(provider).isEmpty()) {
                    R.string.relay_web_status_not_set
                } else {
                    R.string.relay_web_status_set
                },
                action = RelayDetailAction.OpenWebSearch,
            ),
            if (local) {
                RelayDetailRow(
                    RelayDetailRowId.Thinking,
                    R.string.local_setup_tile_thinking,
                    valueRes = thinkingTextRes(provider, lastUsedModelRef),
                    valueArgs = thinkingTextArgs(provider, lastUsedModelRef),
                    trailingRes = R.string.relay_detail_read_only,
                )
            } else {
                null
            },
            // The parameters row merges into the third row of the model card; outside the board there is no Settings section any more.
            RelayDetailRow(RelayDetailRowId.Parameters, R.string.generation_parameters_section, action = RelayDetailAction.OpenParameters),
        )

        return RelayDetailBoard(
            isLocal = local,
            avatar = if (local) null else RelayAvatarResolver.resolve(provider, avatarChoice),
            avatarPickable = !local,
            avatarPickerCells = if (local) {
                emptyList()
            } else {
                RelayAvatarResolver.pickerCells(provider.customName.orEmpty(), provider.baseUrlText.orEmpty())
            },
            showsRenamePencil = !local,
            modelCount = catalogTotal,
            lastCheckedAt = provider.lastCheckedAt,
            headerActions = listOf(RelayDetailAction.Rename, RelayDetailAction.EditConnection),
            connectionRows = connectionRows,
            modelRows = modelRows,
            buttons = listOf(
                RelayDetailButton(
                    textRes = if (isRedetecting) R.string.relay_setup_detecting else R.string.relay_detail_detect_again,
                    action = RelayDetailAction.Redetect,
                    enabled = !isRedetecting,
                    loading = isRedetecting,
                ),
                RelayDetailButton(
                    textRes = if (local) R.string.relay_detail_delete_connection else R.string.relay_detail_delete_relay,
                    action = RelayDetailAction.Delete,
                ),
            ),
            // Only auto detects the protocol per model; a selected protocol and the local channel both only refresh the catalog.
            footnoteRes = if (!local && defaultTransport == RelayTransport.Auto) {
                R.string.relay_detail_detect_footnote
            } else {
                R.string.relay_detail_detect_footnote_catalog
            },
        )
    }

    /**
     * Localized mapping of the reason row on the needs-attention card (same as iOS): the marker string persisted by a save without verification shows "Connection not verified yet";
     * null = go through localizedProviderError as usual (the marker value keeps its provider_connection_unverified mapping elsewhere).
     */
    @androidx.annotation.StringRes
    fun recoveryReasonRes(reason: String): Int? =
        R.string.relay_connection_not_verified.takeIf { reason == ProviderRepository.RELAY_UNVERIFIED_MESSAGE }

    /**
     * Recovery card: shown when the connection status=issue or credentials are required but no key is stored; null for healthy / official providers.
     * [omitsDetail]: omits the reason row when the page already shows the one-time "saved without verification" notice (the same reason sentence).
     */
    fun recoveryCard(provider: Provider, isReverifying: Boolean, omitsDetail: Boolean): RelayRecoveryCard? {
        if (!appliesTo(provider)) return null
        val kind = provider.effectiveStatusKind
        if (!kind.isWarning) return null
        val needsKey = kind == ProviderEffectiveStatusKind.NeedsKey
        val actions = listOfNotNull(
            RelayRecoveryAction(RelayDetailAction.EditConnection, R.string.relay_detail_edit_connection, R.drawable.ph_sliders_horizontal),
            RelayRecoveryAction(RelayDetailAction.OpenKeys, R.string.relay_keys_title, R.drawable.ph_key)
                .takeIf { provider.relayRequested.requiresCredential },
            RelayRecoveryAction(
                RelayDetailAction.Reverify,
                R.string.relay_recovery_verify_again,
                R.drawable.ph_arrow_clockwise,
                running = isReverifying,
                enabled = !isReverifying,
            ),
        )
        return if (needsKey) {
            RelayRecoveryCard(
                titleRes = R.string.provider_api_key_not_saved,
                titleIconRes = R.drawable.ph_key,
                titleAction = RelayDetailAction.OpenKeys,
                reason = null,
                actions = actions,
            )
        } else {
            RelayRecoveryCard(
                titleRes = R.string.relay_recovery_needs_attention,
                titleIconRes = R.drawable.ph_warning,
                titleAction = null,
                reason = provider.lastError?.trim()?.takeIf { it.isNotEmpty() && !omitsDetail },
                actions = actions,
            )
        }
    }

    /** Actions that open a page when tapped (edit connection sheet, keys page, etc.); re-verify / re-detect / delete confirmation do not open pages. */
    fun opensPage(action: RelayDetailAction): Boolean = when (action) {
        RelayDetailAction.EditConnection, RelayDetailAction.OpenKeys, RelayDetailAction.OpenModelLibrary,
        RelayDetailAction.OpenWebSearch, RelayDetailAction.OpenParameters,
        -> true
        else -> false
    }

    /**
     * Three copies of the local thinking row: the criterion comes from the same source as the chat "model options" (write-path table x the default model's engine declaration).
     * Writable -> the writable copy; not writable but the engine declares the default model does not think -> the not-thinking copy; everything else (including the native channel and unknown declarations) -> the model-decides copy.
     */
    @StringRes
    fun thinkingTextRes(provider: Provider, lastUsedModelRef: LastUsedModelRef? = null): Int {
        // Relays have no default model: judged by the fallback model; the unsupported copy fills in the fallback model name.
        val thinking = ModelOptionsPanelInput.localEngineThinking(
            provider,
            RelayModelFallback.fallbackModel(provider, lastUsedModelRef),
        )
        return when {
            thinking?.writable == true -> R.string.relay_detail_thinking_template
            thinking?.declaredThinking == false -> R.string.relay_detail_thinking_unsupported_model
            else -> R.string.relay_detail_thinking_model
        }
    }

    /** Only the unsupported copy takes an argument: the display name of the fallback model (lastUsed -> first enabled). */
    fun thinkingTextArgs(provider: Provider, lastUsedModelRef: LastUsedModelRef? = null): List<Any> {
        if (thinkingTextRes(provider, lastUsedModelRef) != R.string.relay_detail_thinking_unsupported_model) return emptyList()
        val model = RelayModelFallback.fallbackModel(provider, lastUsedModelRef) ?: return emptyList()
        return listOf(model.name.ifBlank { model.id })
    }

    /**
     * Root address row: roots registered per protocol take priority; a legacy single-value root belongs to the connection default protocol (auto means chat);
     * each legend protocol is listed once, in the fixed legend order. When there are no items the caller omits this row.
     */
    fun basePaths(requested: RelayRequestedConfig?): List<RelayDetailBasePath> {
        if (requested == null) return emptyList()
        val roots = linkedMapOf<RelayBoardProtocol, String>()
        requested.resolvedAPIBaseURLs.orEmpty().forEach { (wire, url) ->
            val transport = RelayTransport.entries.firstOrNull { it.value == wire } ?: return@forEach
            if (url.isNotBlank()) roots.putIfAbsent(RelayBoardProtocol.of(transport), url)
        }
        relayConnectionLegacyRoot(requested)?.takeIf(String::isNotBlank)?.let { url ->
            roots.putIfAbsent(RelayBoardProtocol.of(RelayEndpointResolver.effectiveTransport(requested, null)), url)
        }
        return roots.entries
            .sortedBy { it.key.ordinal }
            .map { (protocol, url) -> RelayDetailBasePath(protocol, pathOf(url)) }
    }

    private fun pathOf(url: String): String {
        val path = runCatching { java.net.URI(url.trim()).path }.getOrNull().orEmpty().trimEnd('/')
        return path.ifEmpty { "/" }
    }

    /** auto shows "Auto"; the others use the same display names as the protocol menu. */
    @StringRes
    private fun protocolValueRes(transport: RelayTransport): Int =
        if (transport == RelayTransport.Auto) R.string.relay_profile_auto else relayTransportLabelRes(transport)

    private fun channelRow(requested: RelayRequestedConfig?): RelayDetailRow {
        val channel = relayConnectionDefaultTransport(requested) ?: RelayTransport.OpenAIChatCompletions
        // Only when there is more than one candidate (llama.cpp) does tapping the row open connection editing to change the channel; other engines are read-only with no arrow.
        val editable = (LocalEngineChannels.candidates(requested?.engineProfile)?.size ?: 0) > 1
        return RelayDetailRow(
            RelayDetailRowId.Channel,
            R.string.relay_detail_channel_row,
            valueRes = protocolValueRes(channel),
            action = RelayDetailAction.EditConnection.takeIf { editable },
        )
    }

    /**
     * API key row: with a key shows the mask + an "add more keys" hint at row end; auth required without a key shows "tap to set up"; no auth required without a key shows the "no key required" value.
     * Tappable iff requiresCredential || hasStoredKey (same criterion as canEditApiKey);
     * a connection that needs no auth but holds a key keeps the "Remove stored key" entry.
     */
    private fun apiKeyRow(provider: Provider): RelayDetailRow {
        val hasKey = hasStoredCredential(ProviderCredentialResolver.apiKey(provider, null))
        val requiresCredential = provider.relayRequested.requiresCredential
        if (RelayKeyBinding.showsKeyUI(provider)) {
            // 2 or more keys: title row "API Keys · N keys >" + the first 3 keys inline + "N more".
            val rows = RelayKeysBoardModel.build(provider).rows
            return RelayDetailRow(
                RelayDetailRowId.ApiKey,
                R.string.relay_keys_title,
                action = RelayDetailAction.OpenKeys,
                keyCount = rows.size,
                inlineKeys = rows.take(RelayKeysBoardModel.INLINE_LIMIT),
                moreKeys = (rows.size - RelayKeysBoardModel.INLINE_LIMIT).coerceAtLeast(0),
            )
        }
        return RelayDetailRow(
            RelayDetailRowId.ApiKey,
            R.string.api_key,
            value = if (hasKey) provider.apiKeyPreview.ifEmpty { MASK_FALLBACK } else null,
            valueRes = when {
                hasKey -> null
                // Auth required but no stored key: keeps the existing "tap to set up"; it must not say "no key required".
                requiresCredential -> R.string.tap_to_set
                else -> R.string.relay_detail_no_key
            },
            // Credentials required and only one key stored: the mask already shows it is stored, the row end hints "add more keys" (2 or more keys use the title-row form above).
            // No auth required but a leftover key: no hint at row end - that connection has no use for more keys; the way out is "Remove stored key" below.
            trailingRes = if (hasKey && requiresCredential) R.string.relay_keys_add_more_hint else null,
            // In single-row form a tap opens the keys page (formerly the replace-key dialog); no auth required with no stored key is still not tappable.
            action = RelayDetailAction.OpenKeys.takeIf { requiresCredential || hasKey },
            secondaryAction = RelayDetailAction.RemoveStoredKey.takeIf { !requiresCredential && hasKey },
        )
    }

    /** Engine names are product names and are not translated. */
    private fun engineDisplayName(engineProfile: String): String =
        when (LocalEngineKind.entries.firstOrNull { it.wireName == engineProfile }) {
            LocalEngineKind.LlamaCpp -> "llama.cpp"
            LocalEngineKind.Ollama -> "Ollama"
            LocalEngineKind.LmStudio -> "LM Studio"
            LocalEngineKind.Vllm -> "vLLM"
            LocalEngineKind.OpenWebUI -> "Open WebUI"
            null -> engineProfile
        }

    private const val MASK_FALLBACK = "••••••••"
}
