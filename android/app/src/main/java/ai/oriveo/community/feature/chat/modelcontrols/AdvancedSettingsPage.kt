package ai.oriveo.community.feature.chat.modelcontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.provider.GenerationAccess
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterEmptyState
import ai.oriveo.community.core.provider.GenerationParameterEntryScope
import ai.oriveo.community.core.provider.GenerationParameterPanelPresentation
import ai.oriveo.community.core.provider.GenerationParameterProfileHistory
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.feature.chat.composer.ModelControlHairline
import ai.oriveo.community.feature.chat.composer.ModelControlStatusBadge
import ai.oriveo.community.feature.chat.composer.ModelControlStatusTone
import ai.oriveo.community.feature.chat.composer.modelControlSurface
import ai.oriveo.community.feature.providers.detail.CustomFieldsSupportedModelsPage
import ai.oriveo.community.feature.providers.detail.CustomRequestFieldsPage
import ai.oriveo.community.feature.providers.detail.GenerationParameterSupportedModelsPage
import ai.oriveo.community.feature.providers.detail.customFieldsSupportedCandidates
import ai.oriveo.community.feature.providers.detail.resolveCustomFieldsEntry
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.modelControlTextButtonColors
import org.koin.compose.koinInject

/**
 * Model options > Advanced settings in the chat: only this conversation (the session layer) is changed; model defaults are edited on the provider detail page.
 * The layout follows the Advanced / AdvancedEdit / LocalAdvanced designs; row contents all come from [AdvancedSettingsData].
 */
@Composable
internal fun AdvancedSettingsPage(
    provider: Provider,
    model: AIModel,
    conversationId: String,
    reasoningMode: ReasoningMode,
    /** The whole page is read-only while sending or when the identity is missing (`editability.canPersist`). */
    isReadOnly: Boolean,
    onBack: () -> Unit,
    /** Opening and closing of this page's own subpages; the outer layer uses it to yield the system back action so back steps out one level only. */
    onSubPageVisibleChange: (Boolean) -> Unit = {},
    /** The capability footer of the generation owner, placed under the header; null when there is none. */
    capabilityHeader: (@Composable () -> Unit)? = null,
    /** "Switch to a model that supports custom fields": the same callback as the connection-defaults sheet (switch to that model and close the panel). */
    onSelectCandidateModel: ((AIModel) -> Unit)? = null,
    /** When entered from "go to additional request body" in the model options, that page opens directly. */
    initialSubPage: AdvancedSubPage? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val colors = OriveoTheme.colors
    val store = remember(context) { GenerationParameterSettingsStore.from(context) }
    val observationRevision by CapabilityEvidenceObservationBridge.revision.collectAsState()
    var revision by remember { mutableIntStateOf(0) }
    val loaded = rememberAdvancedSettingsLoaded(provider, model, conversationId, reasoningMode, revision)
    var expandedRow by remember { mutableStateOf<String?>(null) }
    var expandedGroup by remember { mutableStateOf<String?>(null) }
    var showResetConfirm by remember { mutableStateOf(false) }
    var subPage by remember { mutableStateOf(initialSubPage) }
    /** Which parameter the "see models that support it" page was opened for. */
    var supportedModelsParameter by remember { mutableStateOf<String?>(null) }
    var showsCustomFieldsUnsupportedAlert by remember { mutableStateOf(false) }
    val notifySubPage by rememberUpdatedState(onSubPageVisibleChange)
    LaunchedEffect(subPage) { notifySubPage(subPage != null) }
    BackHandler(enabled = subPage != null) { subPage = null }
    val customFieldsIdentity = remember(provider, model, observationRevision) {
        ModelControlRuntimeIdentityResolver.resolve(provider, model)
    }
    if (subPage == AdvancedSubPage.AdditionalBody) {
        AdditionalRequestBodyPage(
            provider = provider,
            model = model,
            conversationId = conversationId,
            isReadOnly = isReadOnly,
            onBack = {
                subPage = null
                revision += 1
            },
            modifier = modifier,
        )
        return
    }
    if (subPage == AdvancedSubPage.ParameterSupportedModels && supportedModelsParameter != null) {
        Column(modifier = modifier.fillMaxSize().padding(top = 24.dp)) {
            GenerationParameterSupportedModelsPage(
                provider = provider,
                parameterId = supportedModelsParameter.orEmpty(),
                scope = GenerationParameterEntryScope.Session,
                access = GenerationAccess(true),
                onBack = { subPage = null },
            )
        }
        return
    }
    val customFieldsCandidates = remember(provider, observationRevision) { customFieldsSupportedCandidates(provider) }
    if (subPage == AdvancedSubPage.CustomFieldsSupportedModels) {
        Column(modifier = modifier.fillMaxSize().padding(top = 24.dp)) {
            CustomFieldsSupportedModelsPage(
                provider = provider,
                candidates = customFieldsCandidates,
                onSelect = onSelectCandidateModel,
                onBack = { subPage = null },
            )
        }
        return
    }
    if (subPage == AdvancedSubPage.CustomFields && customFieldsIdentity != null) {
        CustomRequestFieldsPage(
            provider = provider,
            model = model,
            canonicalModelId = customFieldsIdentity.canonicalModelId,
            conversationId = conversationId,
            transportIdentity = customFieldsIdentity.storageIdentity,
            finalTransport = customFieldsIdentity.finalTransport,
            activeProfile = GenerationParameterAvailability.profile(provider, model),
            onBack = { subPage = null },
            modifier = modifier,
        )
        return
    }
    val canEdit = !isReadOnly
    val fingerprint = loaded?.profileFingerprint

    fun session(): GenerationParameterOverrides =
        store.sessionOverrides(provider.id, model.id, conversationId, fingerprint) ?: GenerationParameterOverrides()

    fun persist(next: GenerationParameterOverrides) {
        store.setSessionOverrides(next, provider.id, model.id, conversationId, fingerprint)
        revision += 1
    }

    fun actions(id: String): AdvancedRowActions {
        val parameters = loaded?.profile?.parameters.orEmpty()
        val parameter = parameters.firstOrNull { it.id == id }
        return AdvancedRowActions(
            setValue = { value ->
                // Same rule as the connection-defaults sheet: setting one item clears the items that conflict with it, so two never apply together.
                val next = session().values.toMutableMap()
                parameter?.conflictsWith?.forEach(next::remove)
                parameters.filter { id in it.conflictsWith }.mapNotNull { it.id }.forEach(next::remove)
                next[id] = GenerationParameterOverride(GenerationOverrideState.Value, value)
                persist(GenerationParameterOverrides(next))
            },
            useModelDefault = { persist(GenerationParameterOverrides(session().values - id)) },
            omit = { persist(GenerationParameterOverrides(session().values + (id to GenerationParameterOverride(GenerationOverrideState.Omit)))) },
        )
    }

    if (showsCustomFieldsUnsupportedAlert) {
        val noModelWouldHelp = customFieldsCandidates.isEmpty()
        val base = stringResource(R.string.generation_parameter_custom_fields_requires_schema)
        val noCandidates = stringResource(R.string.model_control_no_supported_models)
        AlertDialog(
            onDismissRequest = { showsCustomFieldsUnsupportedAlert = false },
            title = { Text(stringResource(R.string.model_control_custom_request_fields)) },
            text = { Text(if (noModelWouldHelp) "$base\n\n$noCandidates" else base) },
            confirmButton = {
                if (noModelWouldHelp) {
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = { showsCustomFieldsUnsupportedAlert = false },
                    ) { Text(stringResource(R.string.ok)) }
                } else {
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = {
                            showsCustomFieldsUnsupportedAlert = false
                            subPage = AdvancedSubPage.CustomFieldsSupportedModels
                        },
                    ) { Text(stringResource(R.string.model_control_view_supported_models)) }
                }
            },
            dismissButton = if (noModelWouldHelp) {
                null
            } else {
                {
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = { showsCustomFieldsUnsupportedAlert = false },
                    ) { Text(stringResource(R.string.ok)) }
                }
            },
        )
    }

    val resetPlan = AdvancedReset.plan(store, provider.id, model.id, conversationId, fingerprint)
    if (showResetConfirm) {
        AlertDialog(
            onDismissRequest = { showResetConfirm = false },
            title = { Text(stringResource(resetPlan.titleRes)) },
            text = { Text(stringResource(resetPlan.bodyRes)) },
            confirmButton = {
                TextButton(
                    colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                    onClick = {
                        resetPlan.execute()
                        revision += 1
                        expandedRow = null
                        showResetConfirm = false
                    },
                ) { Text(stringResource(resetPlan.confirmRes)) }
            },
            dismissButton = {
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = { showResetConfirm = false },
                ) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    val page = loaded?.page
    val rows = page?.rows.orEmpty().associateBy { it.id }
    val hasSessionChanges = page?.rows.orEmpty().any { it.source == GenerationParameterRowModel.Source.Session }
    Column(modifier = modifier.fillMaxSize()) {
        AdvancedSettingsHeader(
            title = stringResource(R.string.generation_model_behavior),
            subtitle = "${model.name.ifBlank { model.id }} · ${stringResource(R.string.advanced_this_conversation_only)}",
            unverifiedBaseline = page?.baseline == GenerationParameterRowModel.Verification.Unverified,
            resetEnabled = canEdit && hasSessionChanges,
            onBack = onBack,
            onReset = { showResetConfirm = true },
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(top = 6.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            capabilityHeader?.invoke()
            if (loaded == null || page == null || page.rows.isEmpty()) {
                // The empty state uses the same shared function as the connection-defaults sheet and says why there are no parameters.
                AdvancedEmptyState(provider, model)
            }
            if (loaded == null || page == null) return@Column
            val layout = AdvancedSettingsLayout.layout(page, loaded.profile)
            val parameterOf = loaded.profile.parameters.associateBy { it.id }
            val sourcedRaw = remember(revision, loaded) {
                store.resolveWithSources(null, provider.id, model.id, conversationId, fingerprint, reasoningMode)
                    .mapValues { it.value.override.value }
            }

            val valueSchemas = loaded.profile.parameters.mapNotNull { p -> p.id?.let { it to p.valueSchema } }.toMap()

            @Composable
            fun RowFor(id: String, note: Int? = AdvancedSubgroups.rowNoteRes(id)) {
                val row = rows[id] ?: return
                val parameter = parameterOf[id] ?: return
                AdvancedParameterRow(
                    row = row,
                    parameter = parameter,
                    expanded = expandedRow == id,
                    canEdit = canEdit,
                    rawValue = sourcedRaw[id],
                    onToggle = { expandedRow = if (expandedRow == id) null else id },
                    actions = actions(id),
                    supportedModelsActionRes = loaded.supportedModelsActions[id],
                    onShowSupportedModels = {
                        supportedModelsParameter = id
                        subPage = AdvancedSubPage.ParameterSupportedModels
                    },
                    note = note?.let { stringResource(it) },
                )
            }

            if (layout.common.isNotEmpty()) {
                AdvancedSectionLabel(stringResource(R.string.generation_basic_settings))
                AdvancedCard {
                    layout.common.forEachIndexed { index, id ->
                        if (index > 0) ModelControlHairline()
                        RowFor(id)
                    }
                }
                TakenOverLegend(AdvancedSubgroups.takenOverNote(layout.common.mapNotNull(rows::get)))
            }
            if (layout.more.isNotEmpty()) {
                AdvancedSectionLabel(stringResource(R.string.advanced_more))
                AdvancedCard {
                    layout.more.forEachIndexed { index, group ->
                        if (index > 0) ModelControlHairline()
                        val groupNote = AdvancedSubgroups.groupNoteRes(group.key)
                        // A group with a single parameter shows that row directly without another level; the subgroup's note travels with that row.
                        if (group.rowIds.size == 1) {
                            val id = group.rowIds.single()
                            RowFor(id, groupNote ?: AdvancedSubgroups.rowNoteRes(id))
                        } else {
                            AdvancedGroupRow(
                                title = stringResource(AdvancedSettingsLayout.groupTitleRes(group.key)),
                                subtitle = groupNote?.let { stringResource(it) }
                                    ?: stringResource(R.string.advanced_also_covers, memberList(group.rowIds)),
                                summary = groupSummary(AdvancedSubgroups.summary(group, rows, sourcedRaw, valueSchemas)),
                                expanded = expandedGroup == group.key,
                                onClick = { expandedGroup = if (expandedGroup == group.key) null else group.key },
                            )
                            if (expandedGroup == group.key) {
                                group.rowIds.forEach { id ->
                                    ModelControlHairline()
                                    RowFor(id)
                                }
                                TakenOverLegend(AdvancedSubgroups.takenOverNote(group.rowIds.mapNotNull(rows::get)), inset = true)
                            }
                        }
                    }
                }
            }
            AdvancedSectionLabel(stringResource(R.string.advanced_write_your_own))
            AdvancedCard {
                                val fragments = remember(context) { LocalCapabilityCustomFragmentStore.from(context) }
                val body = remember(revision) { AdditionalBodyEditor.load(fragments, provider, model, conversationId) }
                val entry = AdditionalBodyEditor.entryRow(
                    body.sendWithRequest,
                    AdditionalBodyEditor.fieldCount(body.rawJSON),
                )
                AdvancedNavigationRow(
                    title = stringResource(R.string.additional_body_title),
                    subtitle = stringResource(R.string.advanced_additional_body_subtitle),
                    trailing = entry.fieldCount?.let { stringResource(entry.trailingRes, it) } ?: stringResource(entry.trailingRes),
                    enabled = entry.enterable,
                    onClick = { subPage = AdvancedSubPage.AdditionalBody },
                )
                ModelControlHairline()
                // The custom fields of the web-search and thinking sections still live in the older editor; when the current model does not support them the row stays tappable and offers a way out.
                val customFieldsStore = remember(context) { LocalCapabilityCustomFragmentStore.from(context) }
                val customFieldsEntry = remember(revision, customFieldsIdentity) {
                    resolveCustomFieldsEntry(
                        store = customFieldsStore,
                        provider = provider,
                        model = model,
                        identity = customFieldsIdentity,
                        conversationId = conversationId,
                        activeProfile = GenerationParameterAvailability.profile(provider, model),
                    )
                }
                AdvancedNavigationRow(
                    title = stringResource(R.string.model_options_web_and_thinking_fields),
                    subtitle = null,
                    trailing = stringResource(customFieldsEntry.statusTextRes),
                    enabled = true,
                    onClick = {
                        when (AdvancedSettingsOutlets.customFieldsTap(customFieldsEntry, customFieldsCandidates)) {
                            AdvancedSettingsOutlets.CustomFieldsTap.Open -> subPage = AdvancedSubPage.CustomFields
                            AdvancedSettingsOutlets.CustomFieldsTap.OfferSupportedModels,
                            AdvancedSettingsOutlets.CustomFieldsTap.NoModelWouldHelp,
                            -> showsCustomFieldsUnsupportedAlert = true
                        }
                    },
                )
            }
            AdvancedLegend(
                showGreyDefaults = page.rows.any {
                    (it.display as? GenerationParameterRowModel.DisplayValue.Fallback)?.kind ==
                        GenerationParameterRowModel.FallbackKind.ModelDefaultValue
                },
                engineName = provider.displayName,
            )
        }
    }
}

@Composable
private fun groupSummary(summary: AdvancedSubgroups.Summary): String = when (summary) {
    AdvancedSubgroups.Summary.NotAdjusted -> stringResource(R.string.advanced_not_adjusted)
    is AdvancedSubgroups.Summary.Count -> stringResource(R.string.model_control_behavior_adjusted, summary.count)
    is AdvancedSubgroups.Summary.Single -> {
        val value = when (val v = summary.value) {
            is AdvancedSubgroups.SingleValue.Text -> v.text
            is AdvancedSubgroups.SingleValue.Entries -> stringResource(R.string.advanced_entries_count, v.count)
            AdvancedSubgroups.SingleValue.On -> stringResource(R.string.advanced_state_on)
            AdvancedSubgroups.SingleValue.Set -> stringResource(R.string.advanced_state_set)
            AdvancedSubgroups.SingleValue.Omitted -> stringResource(R.string.generation_parameter_omitted_value)
        }
        "${stringResource(AdvancedSettingsLayout.rowTitleRes(summary.id))} $value".trim()
    }
}

/** Member titles of a subgroup are joined in the current locale's list format (the separator is decided by ICU). */
@Composable
private fun memberList(ids: List<String>): String {
    val titles = ids.map { stringResource(AdvancedSettingsLayout.rowTitleRes(it)) }
    val locale = androidx.compose.ui.platform.LocalConfiguration.current.locales[0]
    return android.icu.text.ListFormatter.getInstance(locale).format(titles)
}

/** Self-drawn header: back, title and subtitle, reset. 24dp of top padding (a sheet without a navigation bar needs room for the grabber). */
@Composable
private fun AdvancedSettingsHeader(
    title: String,
    subtitle: String,
    unverifiedBaseline: Boolean,
    resetEnabled: Boolean,
    onBack: () -> Unit,
    onReset: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 24.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(
            colors = modelControlTextButtonColors(),
            onClick = onBack,
        ) { Text(stringResource(R.string.back)) }
        Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 1,
                )
                // When "unverified" is the tone of the whole page it is said once here and rows only mark the exceptions.
                if (unverifiedBaseline) {
                    Spacer(Modifier.width(6.dp))
                    ModelControlStatusBadge(ModelControlStatusTone.Manual, stringResource(R.string.generation_parameter_unverified_badge))
                }
            }
            Text(
                text = subtitle,
                fontSize = 12.5.sp,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        TextButton(
            colors = modelControlTextButtonColors(),
            enabled = resetEnabled,
            onClick = onReset,
        ) { Text(stringResource(R.string.advanced_reset)) }
    }
}

@Composable
internal fun AdvancedSectionLabel(text: String) {
    Text(
        text = text,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.06.em,
        color = OriveoTheme.colors.textSecondary,
        modifier = Modifier.padding(start = 16.dp, top = 6.dp),
    )
}

@Composable
internal fun AdvancedCard(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .modelControlSurface()
            .clip(RoundedCornerShape(20.dp)),
    ) { content() }
}

internal enum class AdvancedSubPage { AdditionalBody, CustomFields, ParameterSupportedModels, CustomFieldsSupportedModels }

@Composable
private fun AdvancedNavigationRow(
    title: String,
    subtitle: String?,
    trailing: String?,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 54.dp)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 16.sp, color = colors.textPrimary, maxLines = 1)
            subtitle?.let { Text(it, fontSize = 12.5.sp, color = colors.textSecondary, maxLines = 2) }
        }
        trailing?.let { Text(it, fontSize = 14.sp, color = colors.textSecondary, maxLines = 1) }
        if (enabled) {
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.padding(start = 4.dp).size(16.dp),
            )
        }
    }
}

@Composable
private fun AdvancedGroupRow(title: String, subtitle: String?, summary: String, expanded: Boolean, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 54.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f).padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 16.sp, color = colors.textPrimary, maxLines = 1)
            subtitle?.let { Text(it, fontSize = 12.5.sp, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        Spacer(Modifier.width(8.dp))
        Text(summary, fontSize = 14.sp, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.padding(start = 4.dp).size(16.dp),
        )
    }
}

/** The takeover reason is stated once at the end of the group: one struck item reads "taken over by X", several read "the struck items are taken over by X". */
@Composable
private fun TakenOverLegend(note: AdvancedSubgroups.TakenOverNote?, inset: Boolean = false) {
    note ?: return
    val locale = androidx.compose.ui.platform.LocalConfiguration.current.locales[0]
    val takers = android.icu.text.ListFormatter.getInstance(locale)
        .format(note.takers.map { stringResource(AdvancedSettingsLayout.rowTitleRes(it)) })
    Text(
        text = stringResource(if (note.crossedCount == 1) R.string.advanced_taken_over else R.string.advanced_crossed_out_legend, takers),
        fontSize = 12.5.sp,
        color = OriveoTheme.colors.textSecondary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = if (inset) 8.dp else 0.dp),
    )
}

/** Legend: purple means changed in this conversation, grey means using the model default; a local engine's grey numbers get an extra line. */
@Composable
private fun AdvancedLegend(showGreyDefaults: Boolean, engineName: String) {
    val colors = OriveoTheme.colors
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (showGreyDefaults) {
            Text(stringResource(R.string.advanced_grey_defaults_legend, engineName), fontSize = 12.5.sp, color = colors.textSecondary)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            LegendDot(colors.primarySoft)
            Text(stringResource(R.string.advanced_changed_in_conversation), fontSize = 12.5.sp, color = colors.textSecondary)
            Spacer(Modifier.width(14.dp))
            LegendDot(colors.textSecondary.copy(alpha = 0.12f))
            Text(stringResource(R.string.advanced_using_your_default), fontSize = 12.5.sp, color = colors.textSecondary)
        }
    }
}

@Composable
private fun LegendDot(color: androidx.compose.ui.graphics.Color) {
    Box(modifier = Modifier.padding(end = 6.dp).size(10.dp).clip(CircleShape).background(color))
}

/** Empty state when there are no adjustable parameters; all four states come from the shared [GenerationParameterPanelPresentation.emptyState]. */
@Composable
private fun AdvancedEmptyState(
    provider: Provider,
    model: AIModel,
) {
    val context = LocalContext.current
    val history = remember(context) { GenerationParameterProfileHistory.from(context) }
    val state = remember(provider, model) {
        GenerationParameterPanelPresentation.emptyState(
            provider = provider,
            model = model,
            scope = GenerationParameterEntryScope.Session,
            access = GenerationAccess(true),
            hasSeenNonEmptyProfile = history.hasSeenNonEmptyProfile(provider.id, model.id),
        ) ?: GenerationParameterEmptyState.NotVerified
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(horizontal = 4.dp)) {
        Text(stringResource(state.titleRes), fontSize = 15.sp, color = OriveoTheme.colors.textPrimary)
        state.detailRes?.let { Text(stringResource(it), fontSize = 12.5.sp, color = OriveoTheme.colors.textSecondary) }
    }
}

/**
 * The advanced settings data (layered evaluation, outbound gate, drop preview), shared by the page and the parameter card of the model options.
 * A relay's UI projection needs the local identity; until it arrives the result fails closed (not editable).
 */
@Composable
internal fun rememberAdvancedSettingsLoaded(
    provider: Provider,
    model: AIModel,
    conversationId: String,
    reasoningMode: ReasoningMode,
    revision: Int,
): AdvancedSettingsData.Loaded? {
    val context = LocalContext.current
    val store = remember(context) { GenerationParameterSettingsStore.from(context) }
    val providerRepository = koinInject<ProviderRepository>()
    val observationRevision by CapabilityEvidenceObservationBridge.revision.collectAsState()
    val partition = providerRepository.currentCapabilityPartitionId()
    var localIdentity by remember(provider.id, model.id, partition, observationRevision) {
        mutableStateOf<CapabilityEvidenceIdentity?>(null)
    }
    LaunchedEffect(provider.id, model.id, partition, observationRevision) {
        if (provider.kind == ProviderKind.Relay) {
            localIdentity = providerRepository.capabilityEvidenceIdentity(provider, model.id, partition)
        }
    }
    return remember(provider, model, conversationId, reasoningMode, localIdentity, revision) {
        AdvancedSettingsData.load(
            provider = provider,
            model = model,
            conversationId = conversationId,
            store = store,
            localIdentity = localIdentity,
            reasoningMode = reasoningMode,
            access = GenerationAccess(true),
        )
    }
}
