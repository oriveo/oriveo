package ai.oriveo.community.feature.providers.detail

import androidx.compose.runtime.remember
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity

import androidx.activity.compose.BackHandler
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayWebFragmentStore
import ai.oriveo.community.core.provider.relay.RelayWebFragments
import ai.oriveo.community.core.provider.relay.RelayFirstSendTransport
import ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore
import ai.oriveo.community.core.provider.relay.RelayWebProbeResult
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import ai.oriveo.community.feature.providers.relay.SetupActionBar
import ai.oriveo.community.feature.providers.relay.relayTransportLabelRes
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoBackButtonDefaults
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** Pure logic of the web search settings page: initial values, per-section validation and the save plan. */
object RelayWebSearchPageModel {
    /** The initial value of each section = that section in storage; with no storage but a legacy field mapping, the mapped result is shown. */
    fun initialTexts(provider: Provider, store: RelayWebFragmentStore = RelayWebFragmentStore.shared): Map<RelayTransport, String> {
        val effective = store.effective(provider)
        return RelayWebFragments.TRANSPORTS.associateWith { transport ->
            effective[transport.value]?.let { Json.encodeToString(JsonObject.serializer(), it) }.orEmpty()
        }
    }

    /** The template is inserted as compact single-line JSON (the same string on all three platforms); stored sections are still shown indented. */
    fun templateText(transport: RelayTransport): String =
        RelayWebFragments.template(transport)?.let { Json.encodeToString(JsonObject.serializer(), it) }.orEmpty()

    /** Blank = this section does not exist, which is not an error. */
    fun validate(text: String): RelayWebFragments.Validation? =
        text.takeIf(String::isNotBlank)?.let(RelayWebFragments::validate)

    data class ErrorText(@StringRes val res: Int, val key: String? = null)

    fun errorText(validation: RelayWebFragments.Validation?): ErrorText? {
        val error = validation as? RelayWebFragments.Validation.Error ?: return null
        return when (error.code) {
            "forbidden_key" -> ErrorText(R.string.relay_web_error_forbidden_key, error.key)
            "invalid_tools" -> ErrorText(R.string.relay_web_error_invalid_tools)
            "function_tool" -> ErrorText(R.string.relay_web_error_function_tool)
            "too_large" -> ErrorText(R.string.relay_web_error_too_large)
            else -> ErrorText(R.string.relay_web_error_not_object)
        }
    }

    /** Save plan: returns null if any section is invalid (save is not tappable); otherwise the objects of the non-empty sections, where an empty section = delete that section. */
    fun plan(texts: Map<RelayTransport, String>): Map<RelayTransport, JsonObject>? {
        val result = linkedMapOf<RelayTransport, JsonObject>()
        for (transport in RelayWebFragments.TRANSPORTS) {
            when (val validation = validate(texts[transport].orEmpty())) {
                null -> Unit
                is RelayWebFragments.Validation.Ok -> result[transport] = validation.fragment
                is RelayWebFragments.Validation.Error -> return null
            }
        }
        return result
    }
}

/**
 * Board model of the web search settings page (aligned with iOS): grouping, collapsing, counts,
 * savability, whether anything changed, template confirmation and the back decision. The view renders strictly from it.
 */
object RelayWebSearchBoardModel {
    data class Section(
        val transport: RelayTransport,
        @StringRes val titleRes: Int,
        val text: String,
        val error: RelayWebSearchPageModel.ErrorText?,
        /** The explanation "there is no generic web search field" under the Chat Completions section. */
        @StringRes val noteRes: Int?,
    )

    /** The collapsible group "Other protocols": the header shows the filled count (nothing for 0), and it is forced open when a section in it is filled in wrongly. */
    data class OtherGroup(
        @StringRes val titleRes: Int,
        val sections: List<Section>,
        val setCount: Int,
        val expanded: Boolean,
    )

    /** A row of the rejected section: model name + "Test again"; [running] = being re-tested (the button turns into a spinner). */
    data class RejectedRow(
        val modelId: String,
        val name: String,
        val running: Boolean,
        /** Only one runs at a time: while one row is running the other rows are not tappable. */
        val retestEnabled: Boolean,
    )

    /** "Models that reject these settings" under the groups. */
    data class RejectedGroup(
        @StringRes val titleRes: Int,
        @StringRes val retestRes: Int,
        val rows: List<RejectedRow>,
    )

    data class Board(
        @StringRes val titleRes: Int,
        val subtitle: String,
        @StringRes val introRes: Int,
        val primary: List<Section>,
        /** null = no collapsible group (with auto and no root address, all four sections are expanded). */
        val other: OtherGroup?,
        @StringRes val footerRes: Int,
        /** The probe notice above the save button. */
        @StringRes val disclosureRes: Int,
        /** null = no rejected models, so this section is not shown. */
        val rejected: RejectedGroup?,
        @StringRes val saveRes: Int,
        val hasChanges: Boolean,
        val canSave: Boolean,
        /** The JSON editor is always LTR. */
        val editorLayoutDirection: LayoutDirection = LayoutDirection.Ltr,
    ) {
        /** The main group has no collapsed state. */
        val primaryCollapsible: Boolean get() = false

        /** The header is drawn inside the page (back + title + subtitle), and the fixed bottom action bar has a single primary button. */
        val showsInPageHeader: Boolean get() = true
        val actionBarButtons: List<Int> get() = listOf(saveRes)
    }

    sealed interface TemplateAction {
        data class Fill(val text: String) : TemplateAction
        data object Confirm : TemplateAction
    }

    data class ReplaceConfirm(
        @StringRes val titleRes: Int,
        @StringRes val bodyRes: Int,
        @StringRes val confirmRes: Int,
        @StringRes val cancelRes: Int,
    )

    /** Unsaved-changes prompt: the same copy as the edit connection page. */
    data class DiscardPrompt(
        @StringRes val titleRes: Int,
        @StringRes val bodyRes: Int,
        @StringRes val keepRes: Int,
        @StringRes val discardRes: Int,
    )

    enum class BackAction { Pop, ConfirmDiscard }

    val replaceConfirm = ReplaceConfirm(
        titleRes = R.string.additional_body_paste_replace_title,
        bodyRes = R.string.relay_web_template_replace_body,
        confirmRes = R.string.replace,
        cancelRes = R.string.cancel,
    )

    val discardPrompt = DiscardPrompt(
        titleRes = R.string.relay_discard_changes_title,
        bodyRes = R.string.relay_edit_unsaved_body,
        keepRes = R.string.relay_discard_changes_keep,
        discardRes = R.string.relay_discard_changes_confirm,
    )

    private val compareJson = Json

    fun emptyTexts(): Map<RelayTransport, String> = RelayWebFragments.TRANSPORTS.associateWith { "" }

    /**
     * Expanded group = the protocols listed under "Base paths" on the detail page + the protocol chosen for the connection, in a fixed section order; with the connection on auto and no root address at all, all four sections are expanded.
     */
    fun primaryTransports(provider: Provider): List<RelayTransport> {
        val requested = provider.relayRequested
        val protocols = RelayDetailBoardModel.basePaths(requested).map { it.protocol }.toMutableSet()
        val selected = requested?.transport?.takeIf { it != RelayTransport.Auto }
        selected?.let { protocols += RelayBoardProtocol.of(it) }
        if (protocols.isEmpty()) return RelayWebFragments.TRANSPORTS
        return RelayWebFragments.TRANSPORTS.filter { RelayBoardProtocol.of(it) in protocols }
    }

    fun build(
        provider: Provider,
        baseline: Map<RelayTransport, String>,
        texts: Map<RelayTransport, String>,
        otherExpanded: Boolean,
        rejected: List<AIModel> = emptyList(),
        retestingModelID: String? = null,
    ): Board {
        val primaryTransports = primaryTransports(provider)
        fun section(transport: RelayTransport): Section {
            val text = texts[transport].orEmpty()
            return Section(
                transport = transport,
                titleRes = relayTransportLabelRes(transport),
                text = text,
                error = RelayWebSearchPageModel.errorText(RelayWebSearchPageModel.validate(text)),
                noteRes = R.string.relay_web_chat_note.takeIf { transport == RelayTransport.OpenAIChatCompletions },
            )
        }
        val others = RelayWebFragments.TRANSPORTS.filterNot { it in primaryTransports }.map(::section)
        val changed = hasChanges(baseline, texts)
        return Board(
            titleRes = R.string.web_search,
            subtitle = provider.displayName,
            introRes = R.string.relay_web_page_intro,
            primary = primaryTransports.map(::section),
            other = others.takeIf { it.isNotEmpty() }?.let { sections ->
                OtherGroup(
                    titleRes = R.string.relay_web_other_protocols,
                    sections = sections,
                    setCount = sections.count { it.text.isNotBlank() },
                    expanded = otherExpanded || sections.any { it.error != null },
                )
            },
            footerRes = R.string.relay_model_advanced_local_only,
            disclosureRes = R.string.relay_web_search_probe_disclosure,
            rejected = rejected.takeIf { it.isNotEmpty() }?.let { models ->
                RejectedGroup(
                    titleRes = R.string.relay_web_search_rejected_title,
                    retestRes = R.string.relay_web_search_retest,
                    rows = models.map { model ->
                        RejectedRow(
                            modelId = model.id,
                            name = model.name.ifBlank { model.id },
                            running = model.id == retestingModelID,
                            retestEnabled = retestingModelID == null,
                        )
                    },
                )
            },
            saveRes = R.string.save,
            hasChanges = changed,
            canSave = changed && RelayWebSearchPageModel.plan(texts) != null,
        )
    }

    /** Normalization: whitespace only = empty; JSON that parses is compared by value (a layout-only change does not count); what does not parse is compared with whitespace stripped. */
    private fun normalized(text: String): Any {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return ""
        return runCatching { compareJson.parseToJsonElement(trimmed) }.getOrNull()
            ?: trimmed.filterNot(Char::isWhitespace)
    }

    private fun sameContent(a: String, b: String): Boolean = normalized(a) == normalized(b)

    /** Changed = any section differs from the baseline taken when entering the page after normalization; sections inside a collapsed group count too. */
    fun hasChanges(baseline: Map<RelayTransport, String>, texts: Map<RelayTransport, String>): Boolean =
        RelayWebFragments.TRANSPORTS.any { !sameContent(baseline[it].orEmpty(), texts[it].orEmpty()) }

    private fun otherHasError(provider: Provider, texts: Map<RelayTransport, String>): Boolean {
        val primary = primaryTransports(provider)
        return RelayWebFragments.TRANSPORTS.filterNot { it in primary }.any { transport ->
            RelayWebSearchPageModel.errorText(RelayWebSearchPageModel.validate(texts[transport].orEmpty())) != null
        }
    }

    /** After every edit: if an invalid section appears in the group it is recorded as expanded, and it does not collapse in front of the user once it is fixed. */
    fun otherExpandedAfterEdit(current: Boolean, provider: Provider, texts: Map<RelayTransport, String>): Boolean =
        current || otherHasError(provider, texts)

    /** Tapping the group header: when a section is invalid the group is forced open and this tap records "expanded"; otherwise it toggles. */
    fun tappingOtherHeader(current: Boolean, provider: Provider, texts: Map<RelayTransport, String>): Boolean =
        if (otherHasError(provider, texts)) true else !current

    /** "Use template": empty / whitespace only / already the template of that protocol -> fill in directly; other content -> confirm first. */
    fun templateAction(transport: RelayTransport, current: String): TemplateAction {
        val template = RelayWebSearchPageModel.templateText(transport)
        return if (current.isBlank() || sameContent(current, template)) TemplateAction.Fill(template) else TemplateAction.Confirm
    }

    /**
     * Rejected section: among enabled models, those whose first-shot protocol has a stored fragment and whose current record under that fragment is rejected, in enabling order.
     * Only the stored fragment counts (the re-test uses it too), not the draft; an expired hash = not tested, so it is not listed.
     */
    fun rejectedModels(
        provider: Provider,
        fragments: RelayWebFragmentStore = RelayWebFragmentStore.shared,
        records: RelayWebProbeRecordStore = RelayWebProbeRecordStore.shared,
    ): List<AIModel> {
        val saved = fragments.effective(provider).filterValues { it.isNotEmpty() }
        if (saved.isEmpty()) return emptyList()
        return provider.models.filter { model ->
            val transport = RelayFirstSendTransport.resolve(provider, model).value
            val fragment = saved[transport] ?: return@filter false
            records.currentResult(provider.id, model.id, transport, fragment) == RelayWebProbeResult.Rejected
        }
    }

    fun backAction(board: Board): BackAction = if (board.hasChanges) BackAction.ConfirmDiscard else BackAction.Pop
}

/**
 * Detail > web search settings page (the WebSearch board): the in-page header (back + title + connection name as subtitle) scrolls with the content,
 * with one JSON card per protocol (only the protocols this connection will use are expanded, the rest go into a collapsible group), and the fixed bottom action bar has only "Save".
 * With unsaved changes, both the in-page back and system back show the unsaved-changes prompt first.
 */
@Composable
internal fun RelayWebSearchPage(
    provider: Provider,
    contentPadding: PaddingValues,
    onBack: () -> Unit,
    onSave: (Map<RelayTransport, String>) -> Unit,
    /** Models of the rejected section ([RelayWebSearchBoardModel.rejectedModels], by the stored fragments and the current records). */
    rejectedModels: List<AIModel> = emptyList(),
    /** The model being re-tested; only one runs at a time. */
    retestingModelID: String? = null,
    onRetest: (String) -> Unit = {},
) {
    val colors = OriveoTheme.colors
    // Both the baseline and the draft are restored across rotation / process recreation: relying on remember alone would lose unsaved edits on recreation and replace the baseline with the storage at recreation time.
    val baseline = rememberSaveable(provider.id, saver = WebSearchTextsSaver) { RelayWebSearchPageModel.initialTexts(provider) }
    val texts = rememberSaveable(provider.id, saver = WebSearchDraftSaver) {
        mutableStateMapOf<RelayTransport, String>().apply { putAll(baseline) }
    }
    var otherExpanded by rememberSaveable(provider.id) { mutableStateOf(false) }
    var showDiscard by rememberSaveable(provider.id) { mutableStateOf(false) }
    var confirmTemplateFor by rememberSaveable(provider.id) { mutableStateOf<String?>(null) }
    // The save bar floats at the bottom; the scrolling content leaves the bar height at its end so the notice line is not covered when scrolled to the bottom.
    var actionBarHeightPx by remember { mutableStateOf(0) }
    val density = LocalDensity.current
    val scrollBottomPadding = if (actionBarHeightPx > 0) {
        with(density) { actionBarHeightPx.toDp() } + OriveoTheme.spacing.md
    } else {
        OriveoTheme.spacing.lg
    }
    val board = RelayWebSearchBoardModel.build(provider, baseline, texts.toMap(), otherExpanded, rejectedModels, retestingModelID)

    fun edit(transport: RelayTransport, text: String) {
        texts[transport] = text
        otherExpanded = RelayWebSearchBoardModel.otherExpandedAfterEdit(otherExpanded, provider, texts.toMap())
    }
    fun attemptBack() {
        when (RelayWebSearchBoardModel.backAction(board)) {
            RelayWebSearchBoardModel.BackAction.Pop -> onBack()
            RelayWebSearchBoardModel.BackAction.ConfirmDiscard -> showDiscard = true
        }
    }
    // The detail page's BackHandler pops only one layer; with unsaved changes this one catches system back first (the later registered handler takes priority).
    BackHandler(enabled = board.hasChanges) { showDiscard = true }

    if (showDiscard) {
        val prompt = RelayWebSearchBoardModel.discardPrompt
        AlertDialog(
            onDismissRequest = { showDiscard = false },
            title = { Text(stringResource(prompt.titleRes)) },
            text = { Text(stringResource(prompt.bodyRes)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDiscard = false
                        onBack()
                    },
                ) { Text(stringResource(prompt.discardRes)) }
            },
            dismissButton = {
                TextButton(
                    onClick = { showDiscard = false },
                ) { Text(stringResource(prompt.keepRes)) }
            },
        )
    }

    confirmTemplateFor?.let { wire -> RelayWebFragments.TRANSPORTS.firstOrNull { it.value == wire } }?.let { transport ->
        val confirm = RelayWebSearchBoardModel.replaceConfirm
        AlertDialog(
            onDismissRequest = { confirmTemplateFor = null },
            title = { Text(stringResource(confirm.titleRes)) },
            text = { Text(stringResource(confirm.bodyRes)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmTemplateFor = null
                        edit(transport, RelayWebSearchPageModel.templateText(transport))
                    },
                ) { Text(stringResource(confirm.confirmRes)) }
            },
            dismissButton = {
                TextButton(
                    onClick = { confirmTemplateFor = null },
                ) { Text(stringResource(confirm.cancelRes)) }
            },
        )
    }

    val onTemplate: (RelayTransport) -> Unit = { transport ->
        when (val action = RelayWebSearchBoardModel.templateAction(transport, texts[transport].orEmpty())) {
            is RelayWebSearchBoardModel.TemplateAction.Fill -> edit(transport, action.text)
            RelayWebSearchBoardModel.TemplateAction.Confirm -> confirmTemplateFor = transport.value
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .testTag("relay_web_search_page")
            .padding(contentPadding),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = OriveoTheme.layout.screenH)
                .padding(top = OriveoTheme.spacing.sm, bottom = scrollBottomPadding),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
        ) {
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                OriveoBackButton(
                    onClick = { attemptBack() },
                    modifier = Modifier.offset(x = -OriveoBackButtonDefaults.EdgeInset),
                )
                // iOS page header: the back button and the title are on the same line, and the subtitle is middle-truncated to one line.
                Text(
                    text = stringResource(board.titleRes),
                    modifier = Modifier.weight(1f),
                    style = OriveoTheme.typography.title2,
                    color = colors.textPrimary,
                    maxLines = 1,
                )
            }
            Text(
                text = board.subtitle,
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            Text(text = stringResource(board.introRes), style = OriveoTheme.typography.footnote, color = colors.textSecondary)

            board.primary.forEach { section ->
                WebSearchSection(section, board.editorLayoutDirection, onEdit = ::edit, onTemplate = onTemplate)
            }

            board.other?.let { group ->
                OtherProtocolsHeader(
                    group = group,
                    onToggle = { otherExpanded = RelayWebSearchBoardModel.tappingOtherHeader(otherExpanded, provider, texts.toMap()) },
                )
                if (group.expanded) {
                    group.sections.forEach { section ->
                        WebSearchSection(section, board.editorLayoutDirection, onEdit = ::edit, onTemplate = onTemplate)
                    }
                }
            }

            board.rejected?.let { group -> RejectedModelsSection(group, onRetest) }

            Text(text = stringResource(board.footerRes), style = OriveoTheme.typography.footnote, color = colors.textTertiary)
            // The probe notice above the save button.
            Text(
                text = stringResource(board.disclosureRes),
                modifier = Modifier.testTag("relay_web_search_probe_disclosure"),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }

        SetupActionBar(
            primaryText = stringResource(board.saveRes),
            primaryEnabled = board.canSave,
            primaryLoading = false,
            secondaryText = null,
            onPrimary = { if (board.canSave) onSave(texts.toMap()) },
            onSecondary = {},
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .onSizeChanged { actionBarHeightPx = it.height }
                .testTag("relay_web_search_save"),
        )
    }
}

/** Stored as a string list in a fixed section order (rotation / process recreation). */
private val WebSearchTextsSaver = listSaver<Map<RelayTransport, String>, String>(
    save = { texts -> RelayWebFragments.TRANSPORTS.map { texts[it].orEmpty() } },
    restore = { saved -> RelayWebFragments.TRANSPORTS.zip(saved).toMap() },
)

private val WebSearchDraftSaver = listSaver<SnapshotStateMap<RelayTransport, String>, String>(
    save = { texts -> RelayWebFragments.TRANSPORTS.map { texts[it].orEmpty() } },
    restore = { saved -> mutableStateMapOf<RelayTransport, String>().apply { putAll(RelayWebFragments.TRANSPORTS.zip(saved)) } },
)

@Composable
private fun OtherProtocolsHeader(group: RelayWebSearchBoardModel.OtherGroup, onToggle: () -> Unit) {
    val colors = OriveoTheme.colors
    val expandedLabel = stringResource(if (group.expanded) R.string.mcp_steps_expanded else R.string.mcp_steps_collapsed)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .semantics { stateDescription = expandedLabel },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProviderDetailSectionLabel(
            title = stringResource(group.titleRes),
            trailing = group.setCount.takeIf { it > 0 }?.let {
                pluralStringResource(R.plurals.relay_edit_headers_set_count, it, it)
            },
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.size(8.dp))
        // Collapsed points in the reading direction, expanded points down; the caret_right resource is not mirrored automatically, so flip it manually in RTL.
        val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
        Icon(
            painter = painterResource(if (group.expanded) R.drawable.ph_caret_down else R.drawable.ph_caret_right),
            contentDescription = null,
            tint = colors.textTertiary,
            modifier = Modifier
                .size(14.dp)
                .then(if (rtl && !group.expanded) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
        )
    }
}

/** "Models that reject these settings": each row is a model name + "Test again", and the button turns into a spinner while running. */
@Composable
private fun RejectedModelsSection(group: RelayWebSearchBoardModel.RejectedGroup, onRetest: (String) -> Unit) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier.testTag("relay_web_search_rejected"),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        ProviderDetailSectionLabel(title = stringResource(group.titleRes))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(colors.surfaceElevated),
        ) {
            group.rows.forEachIndexed { index, row ->
                if (index > 0) {
                    Box(
                        modifier = Modifier
                            .padding(horizontal = 16.dp)
                            .fillMaxWidth()
                            .height(0.5.dp)
                            .background(colors.border.opacity(0.72f)),
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(
                        text = row.name,
                        modifier = Modifier.weight(1f),
                        style = OriveoTheme.typography.body,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis,
                    )
                    if (row.running) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp).testTag("relay_web_search_retest_progress_${row.modelId}"),
                            color = colors.primary,
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Text(
                            text = stringResource(group.retestRes),
                            style = OriveoTheme.typography.body,
                            color = if (row.retestEnabled) colors.primary else colors.textTertiary,
                            modifier = Modifier
                                .clickable(enabled = row.retestEnabled) { onRetest(row.modelId) }
                                .testTag("relay_web_search_retest_${row.modelId}"),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun WebSearchSection(
    section: RelayWebSearchBoardModel.Section,
    editorLayoutDirection: LayoutDirection,
    onEdit: (RelayTransport, String) -> Unit,
    onTemplate: (RelayTransport) -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(16.dp)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ProviderDetailSectionLabel(title = stringResource(section.titleRes))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(colors.surfaceElevated),
        ) {
            // JSON is always LTR: even in RTL languages the keys, values and brackets must not be mirrored.
            CompositionLocalProvider(LocalLayoutDirection provides editorLayoutDirection) {
                BasicTextField(
                    value = section.text,
                    onValueChange = { onEdit(section.transport, it) },
                    textStyle = OriveoTheme.typography.footnote.copy(
                        fontFamily = FontFamily.Monospace,
                        fontSize = 13.sp,
                        color = colors.textPrimary,
                        textDirection = TextDirection.Ltr,
                    ),
                    cursorBrush = SolidColor(colors.primary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 110.dp)
                        .padding(14.dp)
                        .testTag("relay_web_search_editor_${section.transport.value}"),
                )
            }
            Box(
                modifier = Modifier
                    .padding(horizontal = 16.dp)
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .background(colors.border.opacity(0.72f)),
            )
            // "Use template · Clear" is a plain text button at the start of the row (iOS), not a Material TextButton.
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = stringResource(R.string.relay_web_use_template),
                    style = OriveoTheme.typography.body,
                    color = colors.primary,
                    modifier = Modifier
                        .clickable { onTemplate(section.transport) },
                )
                Text(
                    text = stringResource(R.string.relay_web_clear),
                    style = OriveoTheme.typography.body,
                    color = colors.textSecondary,
                    modifier = Modifier
                        .clickable { onEdit(section.transport, "") },
                )
            }
        }
        section.error?.let {
            Text(
                text = if (it.key != null) stringResource(it.res, it.key) else stringResource(it.res),
                style = OriveoTheme.typography.footnote,
                color = colors.danger,
            )
        }
        section.noteRes?.let {
            Text(text = stringResource(it), style = OriveoTheme.typography.footnote, color = colors.textTertiary)
        }
    }
}
