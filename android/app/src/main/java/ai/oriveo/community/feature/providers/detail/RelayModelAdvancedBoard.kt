package ai.oriveo.community.feature.providers.detail

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.LocalEngineChannels
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.relay.RelayCapabilityTest
import ai.oriveo.community.core.provider.relay.RelayFirstSendTransport
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.relay.RelayProbeCandidates
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import ai.oriveo.community.feature.providers.relay.relayTransportMenuValueRes

/** Page section order: five sections for Relay; for local engines the first section is the read-only channel and there is no thinking section. */
enum class RelayAdvancedSection { Protocol, Key, Channel, Capabilities, Thinking, Legend, Footer }

/** One key in the Key section: name or mask + mask. */
data class RelayAdvancedKeyOption(val keyId: String, val title: String, val maskedSecret: String)

/**
 * "Key" section (shown only with 2 or more keys): current binding + the "Auto" menu entry and every key. Auto = the key recomputed by the §4 rule after removing this model from the enabled ones
 * ([RelayKeyBinding.bind]); when the current binding equals it, the menu shows Auto. The read-only advanced page takes the rule result and is not operable.
 */
data class RelayAdvancedKeySection(
    val current: RelayAdvancedKeyOption,
    val followsAuto: Boolean,
    val keys: List<RelayAdvancedKeyOption>,
    val autoKeyId: String,
    val interactive: Boolean,
    @StringRes val hintRes: Int = R.string.relay_advanced_key_auto_hint,
) {
    /** The key to rebind to after the menu selects [keyId] (null = Auto); null (no write) when it is the current key or not operable. */
    fun rebindTarget(keyId: String?): String? {
        if (!interactive) return null
        return (keyId ?: autoKeyId).takeIf { it != current.keyId }
    }
}

/** Protocol segments: four generation protocols after Auto; the names are protocol names and are not translated. */
enum class RelayAdvancedProtocol(val transport: RelayTransport?) {
    Auto(null),
    Chat(RelayTransport.OpenAIChatCompletions),
    Responses(RelayTransport.OpenAIResponses),
    Messages(RelayTransport.AnthropicMessages),
    Gemini(RelayTransport.GeminiGenerateContent),
    ;

    companion object {
        fun of(transport: RelayTransport): RelayAdvancedProtocol =
            entries.firstOrNull { it.transport == transport } ?: Chat
    }
}

/** Status words for the protocol description row: reuses the status words of rows 2-3, plus in-progress / not-connected for single-protocol probing. */
enum class RelayAdvancedProtocolStatus(@StringRes val textRes: Int) {
    Verified(R.string.relay_catalog_status_verified),
    Reachable(R.string.relay_catalog_status_reachable),
    SetByYou(R.string.relay_catalog_status_set_by_you),
    UnknownUntilSent(R.string.model_options_vision_unknown),
    Testing(R.string.relay_edit_status_testing),
    NotReachable(R.string.relay_model_advanced_not_reachable),
}

/** Single-protocol probe held in this page's memory: shown only when it belongs to the currently hand-picked protocol; not stored when undeterminable. */
data class RelayAdvancedProbe(val transport: RelayTransport, val state: State) {
    enum class State { Running, Passed, Failed }
}

data class RelayAdvancedProtocolRow(
    val segments: List<RelayAdvancedProtocol>,
    val selected: RelayAdvancedProtocol,
    /** Description row 1, non-null only when Auto is selected: the first-send protocol ([RelayFirstSendTransport], read the same as chat first send). */
    val autoEquals: RelayBoardProtocol?,
    /** Connection protocol chosen and the model has none of its own: row 1 shows the "follows this connection's default protocol" line. */
    val autoFollowsConnection: Boolean = false,
    val status: RelayAdvancedProtocolStatus,
    /** Path of effectiveAPIRoot; shows "/" when empty. */
    val apiRootPath: String,
)

/** Local channels: always read-only; the footnote appears only with more than one engine channel. */
data class RelayAdvancedChannelRow(@StringRes val valueRes: Int, val showsHint: Boolean)

enum class RelayAdvancedCapability(val key: String, @StringRes val titleRes: Int, val negativeKind: RelayNegativeCache.Kind?) {
    Image("image", R.string.capability_image, RelayNegativeCache.Kind.Image),
    File("file", R.string.capability_file, RelayNegativeCache.Kind.File),
    ImageGeneration("imageGeneration", R.string.relay_model_advanced_image_generation, null),
    ToolCall("toolCall", R.string.relay_model_advanced_tool_calls, RelayNegativeCache.Kind.ToolCall),
    /** Web search: status and source come from the probe record under the first-send protocol's effective fragment; there is no negative-cache tier. */
    Web("web", R.string.relay_cap_test_item_web, null),
}

/** Source badges (in the contract's order); Gateway / Server facts are not drawn in this unit. */
enum class RelayAdvancedSource(@StringRes val labelRes: Int) {
    Catalog(R.string.relay_model_advanced_source_catalog),
    Detected(R.string.relay_model_advanced_source_detected),
    Tested(R.string.relay_model_advanced_source_tested),
    Engine(R.string.relay_model_advanced_source_engine),
    User(R.string.relay_catalog_status_set_by_you),
}

enum class RelayAdvancedControl { Auto, On, Off }

data class RelayAdvancedCapabilityRow(
    val capability: RelayAdvancedCapability,
    val state: RelayCatalogCapabilityState,
    val source: RelayAdvancedSource?,
    val control: RelayAdvancedControl,
    /** The record status of the web row (fixture presentationCases advanced.statusId); null = local engine / protocol undecided (shown as unknown) or not the web row. */
    val webStatus: ai.oriveo.community.core.provider.relay.RelayWebChat.Status? = null,
) {
    @get:StringRes
    val statusRes: Int
        get() = if (capability == RelayAdvancedCapability.Web) {
            webStatus?.let(ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsRender::relayWebStatusRes)
                ?: R.string.relay_model_advanced_unknown
        } else when (state) {
            RelayCatalogCapabilityState.Supported -> R.string.relay_capability_test_supported
            RelayCatalogCapabilityState.Unsupported -> R.string.relay_capability_test_unsupported
            // Image generation has no remember-after-send mechanism, so it does not say "remembered after send".
            RelayCatalogCapabilityState.Unknown -> if (capability == RelayAdvancedCapability.ImageGeneration) {
                R.string.relay_model_advanced_unknown
            } else {
                R.string.model_options_vision_unknown
            }
        }
}

data class RelayAdvancedThinkingCell(val mode: ReasoningMode, val available: Boolean, val selected: Boolean)

sealed interface RelayAdvancedThinking {
    data class Levels(val cells: List<RelayAdvancedThinkingCell>) : RelayAdvancedThinking
}

enum class RelayEnabledRowMenuItem { SetDefault, Remove }

/** The ⋯ menu of an official enabled row (set as default / remove); menus of relay / local board rows come from [RelayCatalogRow.menu]. */
data class RelayEnabledRowActions(val menu: List<RelayEnabledRowMenuItem>)

/** Structure of the "Model > Advanced" page: the page only renders it. Produced only for enabled models of the Relay form (including local engines). */
data class RelayModelAdvancedBoard(
    val modelName: String,
    val host: String,
    val sections: List<RelayAdvancedSection>,
    val restoreAllEnabled: Boolean,
    val protocol: RelayAdvancedProtocolRow?,
    val channel: RelayAdvancedChannelRow?,
    val capabilities: List<RelayAdvancedCapabilityRow>,
    /** null = no thinking section (local engine, or no selectable tiers). */
    val thinking: RelayAdvancedThinking?,
    val legend: List<RelayAdvancedSource>,
    /** "Test capabilities" entry (decision logic unchanged); not shown on the read-only advanced page. */
    val offersCapabilityTest: Boolean,
    /** The footer appears only in the writable state. */
    @StringRes val footnoteRes: Int = R.string.relay_model_advanced_changes_apply,
    /** Present only with 2 or more keys. */
    val keySection: RelayAdvancedKeySection? = null,
    /** Read-only advanced page entered from a catalog row: all controls inoperable, no capability test, opening sends no request. */
    val readOnly: Boolean = false,
    @StringRes val readOnlyNoteRes: Int? = null,
) {
    companion object {
        private val RELAY_LEGEND = listOf(
            RelayAdvancedSource.Catalog,
            RelayAdvancedSource.Detected,
            RelayAdvancedSource.Tested,
            RelayAdvancedSource.User,
        )
        private val LOCAL_LEGEND = listOf(RelayAdvancedSource.Engine, RelayAdvancedSource.User)

        fun build(
            provider: Provider,
            model: AIModel,
            nowSeconds: Long,
            probe: RelayAdvancedProbe?,
            facts: RelayCatalogCapabilitySource,
            negativeCache: RelayNegativeCache,
            toolMemory: Boolean?,
            automaticReasoning: List<ReasoningMode>,
            readOnly: Boolean = false,
            family: (String) -> String? = RelayKeyBinding::cachedFamily,
            webFragments: ai.oriveo.community.core.provider.relay.RelayWebFragmentStore =
                ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.shared,
            webRecords: ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore =
                ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.shared,
        ): RelayModelAdvancedBoard {
            val local = RelayDetailBoardModel.isLocal(provider)
            val keySection = if (local) null else keySection(provider, model.id, readOnly, family)
            val automaticStates = facts.states(provider, model, nowSeconds)
            fun automatic(capability: RelayCatalogCapability) = automaticStates[capability.ordinal]
            val overrides = model.relayCapabilityOverrides
            val capabilities = RelayAdvancedCapability.entries.map { capability ->
                if (capability == RelayAdvancedCapability.Web) return@map webRow(provider, model, webFragments, webRecords)
                val override = overrides.valueOf(capability)
                val state = when (override) {
                    true -> RelayCatalogCapabilityState.Supported
                    false -> RelayCatalogCapabilityState.Unsupported
                    null -> when (capability) {
                        RelayAdvancedCapability.Image -> automatic(RelayCatalogCapability.Image)
                        RelayAdvancedCapability.File -> automatic(RelayCatalogCapability.File)
                        RelayAdvancedCapability.ToolCall -> automatic(RelayCatalogCapability.Tool)
                        RelayAdvancedCapability.ImageGeneration ->
                            if (ModelCapability.ImageGen in model.capabilities) {
                                RelayCatalogCapabilityState.Supported
                            } else {
                                RelayCatalogCapabilityState.Unknown
                            }
                        RelayAdvancedCapability.Web -> RelayCatalogCapabilityState.Unknown
                    }
                }
                RelayAdvancedCapabilityRow(
                    capability = capability,
                    state = state,
                    source = source(provider, model, capability, local, nowSeconds, negativeCache, toolMemory),
                    control = when (override) {
                        true -> RelayAdvancedControl.On
                        false -> RelayAdvancedControl.Off
                        null -> RelayAdvancedControl.Auto
                    },
                )
            }
            val userTransport = model.relayTransport != null && model.relayTransport != RelayTransport.Auto &&
                model.relayTransportSource == RelayTransportSource.User
            val thinking = if (local) null else thinking(automaticReasoning, overrides?.reasoningLevels)
            return RelayModelAdvancedBoard(
                modelName = model.name,
                host = host(provider.baseUrlText.orEmpty()),
                sections = if (local) {
                    listOfNotNull(
                        RelayAdvancedSection.Channel,
                        RelayAdvancedSection.Capabilities,
                        RelayAdvancedSection.Legend,
                        RelayAdvancedSection.Footer.takeUnless { readOnly },
                    )
                } else {
                    listOfNotNull(
                        RelayAdvancedSection.Protocol,
                        RelayAdvancedSection.Key.takeIf { keySection != null },
                        RelayAdvancedSection.Capabilities,
                        RelayAdvancedSection.Thinking.takeIf { thinking != null },
                        RelayAdvancedSection.Legend,
                        RelayAdvancedSection.Footer.takeUnless { readOnly },
                    )
                },
                restoreAllEnabled = !readOnly && (overrides?.isEmpty == false || userTransport),
                protocol = if (local) null else protocolRow(provider, model, userTransport, probe),
                channel = if (local) channelRow(provider, model) else null,
                capabilities = capabilities,
                thinking = thinking,
                legend = if (local) LOCAL_LEGEND else RELAY_LEGEND,
                offersCapabilityTest = !readOnly && RelayCapabilityTest.offersTest(provider, model),
                keySection = keySection,
                readOnly = readOnly,
                readOnlyNoteRes = if (readOnly) R.string.relay_advanced_read_only_note else null,
            )
        }

        /** The Auto key: recomputed by the §4 rule after removing [modelID] from the enabled ones; null with fewer than two keys. */
        fun autoKeyID(provider: Provider, modelID: String, family: (String) -> String? = RelayKeyBinding::cachedFamily): String? =
            RelayKeyBinding.bind(
                RelayKeyBinding.keyIDs(provider),
                provider.catalogModels,
                provider.models.filter { it.id != modelID },
                modelID,
                family,
            )

        private fun keySection(
            provider: Provider,
            modelID: String,
            readOnly: Boolean,
            family: (String) -> String?,
        ): RelayAdvancedKeySection? {
            if (!RelayKeyBinding.showsKeyUI(provider)) return null
            val auto = autoKeyID(provider, modelID, family) ?: return null
            val options = RelayKeyBinding.rows(provider).map { row ->
                RelayAdvancedKeyOption(row.id, row.name?.takeIf(String::isNotBlank) ?: row.maskedSecret, row.maskedSecret)
            }
            // Read-only (model not enabled yet) shows the rule result; enabled shows the effective binding.
            val bound = if (readOnly) auto else RelayKeyBinding.modelState(provider, modelID).boundKeyID
            val current = options.firstOrNull { it.keyId == bound } ?: return null
            return RelayAdvancedKeySection(
                current = current,
                followsAuto = bound == auto,
                keys = options,
                autoKeyId = auto,
                interactive = !readOnly,
            )
        }

        /**
         * Automatic set of thinking tiers: the same function the model-options panel's thinking card reads (no overrides layered), and `off` is not a tier.
         * Empty when the Relay has no Server recipe.
         */
        fun automaticReasoning(
            provider: Provider,
            model: AIModel,
            metadata: MetadataClient = MetadataClient.instance,
        ): List<ReasoningMode> {
            val intents = CapabilityControlResolution.resolveAutomatic(provider, model, "reasoning", metadata).intents
            val modes = intents.mapNotNull(CapabilityControlResolution::reasoningModeOf).toSet()
            // "Auto" is not an overridable tier (it was placed into the relay automatic set).
            return ReasoningMode.entries.filter { it in modes && it != ReasoningMode.Automatic }
        }

        fun enabledRowActions(canSetDefault: Boolean, canRemove: Boolean) = RelayEnabledRowActions(
            menu = listOfNotNull(
                RelayEnabledRowMenuItem.SetDefault.takeIf { canSetDefault },
                RelayEnabledRowMenuItem.Remove.takeIf { canRemove },
            ),
        )

        private fun protocolRow(
            provider: Provider,
            model: AIModel,
            userTransport: Boolean,
            probe: RelayAdvancedProbe?,
        ): RelayAdvancedProtocolRow {
            val effective = RelayEndpointResolver.effectiveTransport(provider, model)
            val selected = if (userTransport) RelayAdvancedProtocol.of(effective) else RelayAdvancedProtocol.Auto
            val ownTransport = model.relayTransport != null && model.relayTransport != RelayTransport.Auto
            // Following the chosen connection (the model has no protocol of its own): row 1 shows the connection line and the state is Set by you.
            val followsConnection = !ownTransport && RelayProbeCandidates.connectionIsExplicit(provider.relayRequested)
            // The probe result belongs only to the currently hand-picked protocol; switching protocol invalidates it.
            val probeState = probe?.takeIf { userTransport && it.transport == model.relayTransport }?.state
            val status = when (probeState) {
                RelayAdvancedProbe.State.Running -> RelayAdvancedProtocolStatus.Testing
                RelayAdvancedProbe.State.Passed -> RelayAdvancedProtocolStatus.Reachable
                RelayAdvancedProbe.State.Failed -> RelayAdvancedProtocolStatus.NotReachable
                null -> when (model.relayTransportSource.takeIf { model.relayTransport != null && model.relayTransport != RelayTransport.Auto }) {
                    RelayTransportSource.Observed -> RelayAdvancedProtocolStatus.Verified
                    RelayTransportSource.Reachable -> RelayAdvancedProtocolStatus.Reachable
                    RelayTransportSource.User -> RelayAdvancedProtocolStatus.SetByYou
                    null -> if (followsConnection) RelayAdvancedProtocolStatus.SetByYou else RelayAdvancedProtocolStatus.UnknownUntilSent
                }
            }
            return RelayAdvancedProtocolRow(
                segments = RelayAdvancedProtocol.entries.toList(),
                selected = selected,
                autoEquals = if (selected == RelayAdvancedProtocol.Auto) {
                    RelayBoardProtocol.of(RelayFirstSendTransport.resolve(provider, model))
                } else {
                    null
                },
                autoFollowsConnection = selected == RelayAdvancedProtocol.Auto && followsConnection,
                status = status,
                apiRootPath = apiRootPath(RelayEndpointResolver.effectiveAPIRoot(provider, model)),
            )
        }

        private fun channelRow(provider: Provider, model: AIModel): RelayAdvancedChannelRow {
            val channel = RelayEndpointResolver.effectiveTransport(provider, model)
            return RelayAdvancedChannelRow(
                valueRes = relayTransportMenuValueRes(channel),
                showsHint = LocalEngineChannels.showsSelector(provider.relayRequested?.engineProfile),
            )
        }

        private fun thinking(automatic: List<ReasoningMode>, override: List<String>?): RelayAdvancedThinking? {
            if (automatic.isEmpty()) return null
            return RelayAdvancedThinking.Levels(
                ReasoningMode.entries.map { mode ->
                    val available = mode in automatic
                    RelayAdvancedThinkingCell(
                        mode = mode,
                        available = available,
                        selected = available && (override == null || mode.rawValue in override),
                    )
                },
            )
        }

        /**
         * The web row (fixture presentationCases advanced): status = the current record under the effective fragment (overrides are not consulted),
         * source = user (user override) / tested (record searched / rejected) / none; the status color follows the truth (user override > record).
         * The control follows the other capability rows: an override value (user / tested) true -> On, false -> Off, no value -> Auto (choosing Auto clears the override).
         * Local engine / protocol undecided -> unknown, no source.
         */
        private fun webRow(
            provider: Provider,
            model: AIModel,
            fragments: ai.oriveo.community.core.provider.relay.RelayWebFragmentStore,
            records: ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore,
        ): RelayAdvancedCapabilityRow {
            val chat = ai.oriveo.community.core.provider.relay.RelayWebChat.of(provider, model, fragments, records)
                ?.takeUnless { ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput.protocolUndecided(provider, model) }
            val advanced = chat?.advanced
            return RelayAdvancedCapabilityRow(
                capability = RelayAdvancedCapability.Web,
                state = when (chat?.truth) {
                    "supported" -> RelayCatalogCapabilityState.Supported
                    "unsupported" -> RelayCatalogCapabilityState.Unsupported
                    else -> RelayCatalogCapabilityState.Unknown
                },
                source = when (advanced?.source) {
                    RelayCapabilityOverrides.SOURCE_USER -> RelayAdvancedSource.User
                    RelayCapabilityOverrides.SOURCE_TESTED -> RelayAdvancedSource.Tested
                    else -> null
                },
                // The same convention as the other capability rows in the card: an override value (user or tested) true -> On, false -> Off, no value -> Auto.
                control = when (model.relayCapabilityOverrides?.web) {
                    true -> RelayAdvancedControl.On
                    false -> RelayAdvancedControl.Off
                    null -> RelayAdvancedControl.Auto
                },
                webStatus = advanced?.status,
            )
        }

        /** Takes the first hit in the fixed order: user > tested > engine declaration > negative cache / tool memory > official catalog > none (local engines stop at the engine declaration). */
        private fun source(
            provider: Provider,
            model: AIModel,
            capability: RelayAdvancedCapability,
            local: Boolean,
            nowSeconds: Long,
            negativeCache: RelayNegativeCache,
            toolMemory: Boolean?,
        ): RelayAdvancedSource? {
            val overrides = model.relayCapabilityOverrides
            if (overrides.valueOf(capability) != null) {
                return if (overrides!!.sourceOf(capability.key) == RelayCapabilityOverrides.SOURCE_TESTED) {
                    RelayAdvancedSource.Tested
                } else {
                    RelayAdvancedSource.User
                }
            }
            val declaration = model.engineDeclaration.takeIf { local }
            val engineDeclared = when (capability) {
                RelayAdvancedCapability.Image -> declaration?.image
                RelayAdvancedCapability.ToolCall -> declaration?.toolCall
                RelayAdvancedCapability.File, RelayAdvancedCapability.ImageGeneration, RelayAdvancedCapability.Web -> null
            }
            if (engineDeclared != null) return RelayAdvancedSource.Engine
            // Local connections draw only Set by you / Tested / Engine declared (same scope as the local legend).
            if (local) return null
            val rejected = capability.negativeKind?.let { kind ->
                RelayNegativeCache.keyFor(provider, model)?.let { negativeCache.isRejected(it, kind, nowSeconds) }
            } == true
            if (rejected || (capability == RelayAdvancedCapability.ToolCall && toolMemory == true)) {
                return RelayAdvancedSource.Detected
            }
            val catalog = when (capability) {
                RelayAdvancedCapability.Image -> ModelCapability.Image in model.capabilities
                RelayAdvancedCapability.File -> model.nativeFileMimes.isNotEmpty()
                RelayAdvancedCapability.ImageGeneration -> ModelCapability.ImageGen in model.capabilities
                RelayAdvancedCapability.ToolCall -> model.toolCall != null
                RelayAdvancedCapability.Web -> false
            }
            return if (catalog) RelayAdvancedSource.Catalog else null
        }

        private fun host(baseUrlText: String): String {
            val trimmed = baseUrlText.trim()
            val candidate = if (trimmed.contains("://")) trimmed else "https://$trimmed"
            return runCatching { java.net.URI(candidate).host }.getOrNull()?.takeIf(String::isNotBlank) ?: trimmed
        }

        private fun apiRootPath(root: String?): String {
            val path = root?.let { runCatching { java.net.URI(it).path }.getOrNull() }
            return path?.takeIf(String::isNotEmpty) ?: "/"
        }
    }
}

internal fun RelayCapabilityOverrides?.valueOf(capability: RelayAdvancedCapability): Boolean? = when (capability) {
    RelayAdvancedCapability.Image -> this?.image
    RelayAdvancedCapability.File -> this?.file
    RelayAdvancedCapability.ImageGeneration -> this?.imageGeneration
    RelayAdvancedCapability.ToolCall -> this?.toolCall
    RelayAdvancedCapability.Web -> this?.web
}

/**
 * Write transforms of the "Model > Advanced" page: the model with the same id in the enabled list and the catalog is written together, and persistence is done by ProviderRepository.
 */
object RelayModelAdvancedEdits {
    /** Choosing a protocol writes user; null (choosing Auto) clears the model-level protocol and source. */
    fun settingTransport(provider: Provider, modelID: String, transport: RelayTransport?): Provider =
        provider.mapModel(modelID) {
            it.copy(relayTransport = transport, relayTransportSource = transport?.let { RelayTransportSource.User })
        }

    /**
     * On / Off writes that key as `{value, source: user}` and clears the same-tier negative cache of the model's current effective protocol (image generation has no tiers);
     * null (Auto) deletes the key, whether user or tested.
     */
    fun settingCapabilityOverride(
        provider: Provider,
        modelID: String,
        capability: RelayAdvancedCapability,
        value: Boolean?,
        negativeCache: RelayNegativeCache = RelayNegativeCache.shared,
    ): Provider {
        if (value != null) {
            val kind = capability.negativeKind
            val model = (provider.models + provider.catalogModels).firstOrNull { it.id == modelID }
            if (kind != null && model != null) {
                RelayNegativeCache.keyFor(provider, model)?.let { negativeCache.clear(it, listOf(kind)) }
            }
        }
        return provider.mapModel(modelID) { model ->
            val current = model.relayCapabilityOverrides ?: RelayCapabilityOverrides()
            val next = when (capability) {
                RelayAdvancedCapability.Image -> current.copy(image = value)
                RelayAdvancedCapability.File -> current.copy(file = value)
                RelayAdvancedCapability.ImageGeneration -> current.copy(imageGeneration = value)
                RelayAdvancedCapability.ToolCall -> current.copy(toolCall = value)
                RelayAdvancedCapability.Web -> current.copy(web = value)
            }.let { it.copy(testedKeys = it.testedKeys - capability.key) }
            model.copy(relayCapabilityOverrides = next.takeUnless { it.isEmpty })
        }
    }

    /** Writes the thinking-tier override (raw contract value); null deletes the key. The caller first narrows and normalizes via [toggledReasoningLevels]. */
    fun settingReasoningLevels(provider: Provider, modelID: String, levels: List<String>?): Provider {
        return provider.mapModel(modelID) { model ->
            val current = model.relayCapabilityOverrides ?: RelayCapabilityOverrides()
            val next = current.copy(reasoningLevels = levels, testedKeys = current.testedKeys - "reasoningLevels")
            model.copy(relayCapabilityOverrides = next.takeUnless { it.isEmpty })
        }
    }

    /** After a tier override is saved: old tier-rejection records no longer represent the user's choice; only those of the current effective protocol are cleared. */
    fun clearingReasoningTierRecords(provider: Provider, modelID: String, negativeCache: RelayNegativeCache) {
        val model = (provider.models + provider.catalogModels).firstOrNull { it.id == modelID } ?: return
        val key = RelayNegativeCache.keyFor(provider, model) ?: return
        negativeCache.clear(key, RelayNegativeCache.Kind.entries.filter { it.reasoningTier != null })
    }

    /**
     * Override value after tapping a cell: cells outside the automatic set are not tappable and the last selected cell cannot be deselected (both return the original [current]);
     * selecting back to equal the automatic set deletes the override (null). It only narrows and never adds tiers the upstream did not declare.
     */
    fun toggledReasoningLevels(automatic: List<ReasoningMode>, current: List<String>?, mode: ReasoningMode): List<String>? {
        if (mode !in automatic) return current
        val selected = automatic.filter { current == null || it.rawValue in current }.toSet()
        val next = if (mode in selected) {
            if (selected.size == 1) return current
            selected - mode
        } else {
            selected + mode
        }
        val ordered = automatic.filter { it in next }
        return if (ordered == automatic) null else ordered.map { it.rawValue }
    }

    /** Restore everything to automatic: clears all overrides (user + tested) and the user-sourced model-level protocol, but not the negative cache. */
    fun restoringAllAutomatic(provider: Provider, modelID: String): Provider =
        provider.mapModel(modelID) { model ->
            val userTransport = model.relayTransportSource == RelayTransportSource.User
            model.copy(
                relayCapabilityOverrides = null,
                relayTransport = model.relayTransport.takeUnless { userTransport },
                relayTransportSource = model.relayTransportSource.takeUnless { userTransport },
            )
        }

    private fun Provider.mapModel(modelID: String, transform: (AIModel) -> AIModel): Provider {
        fun List<AIModel>.mapped() = map { if (it.id == modelID) transform(it) else it }
        return copy(models = models.mapped(), catalogModels = catalogModels.mapped())
    }
}
