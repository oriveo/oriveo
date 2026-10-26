package ai.oriveo.community.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

/** Memory suggestions inbox: pending list or empty state, then the footnote. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryInboxScreen(
    onNavigateBack: () -> Unit = {},
    viewModel: MemoryInboxViewModel = koinViewModel(),
) {
    val colors = OriveoTheme.colors
    val state by viewModel.state.collectAsStateWithLifecycle()
    val editor by viewModel.editor.collectAsStateWithLifecycle()
    val autoSuggest by viewModel.autoSuggest.collectAsStateWithLifecycle()

    // Re-read on every return to the page; the first resume follows the initial read in init.
    LifecycleResumeEffect(viewModel) {
        viewModel.refresh()
        onPauseOrDispose { }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        MemoryAtlasBackground(atlasHeight = 300.dp)
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {},
                    navigationIcon = {
                        OriveoBackButton(onClick = onNavigateBack)
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.TopCenter,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = 600.dp)
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp)
                        .padding(bottom = 64.dp),
                ) {
                    Text(
                        text = stringResource(R.string.memory_inbox_title),
                        style = memoryText(34f, 41f, FontWeight.Bold).copy(letterSpacing = (-0.6).sp),
                        color = colors.textPrimary,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                    Column(modifier = Modifier.padding(top = 18.dp).fillMaxWidth().memoryCard(outlined = true)) {
                        Row(
                            modifier = Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(
                                text = stringResource(R.string.memory_inbox_auto_suggest),
                                style = memoryText(16f, 21f, FontWeight.Medium),
                                color = colors.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Switch(
                                checked = autoSuggest,
                                onCheckedChange = viewModel::setAutoSuggest,
                                colors = SwitchDefaults.colors(
                                    checkedTrackColor = colors.primaryTextSafe,
                                    checkedThumbColor = colors.switchThumb,
                                    checkedBorderColor = Color.Transparent,
                                ),
                                modifier = Modifier,
                            )
                        }
                        Text(
                            text = stringResource(R.string.memory_inbox_auto_suggest_footnote),
                            style = memoryText(13f, 19f),
                            color = colors.textTertiary,
                            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 14.dp),
                        )
                    }
                    when {
                        state.candidates.isNotEmpty() -> {
                            Row(
                                modifier = Modifier.padding(top = 26.dp, start = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Icon(MemoryGlyphs.Inbox, contentDescription = null, tint = colors.primary, modifier = Modifier.size(17.dp))
                                Text(text = state.count.toString(), style = memoryDigits(13f), color = colors.textTertiary)
                            }
                            state.candidates.forEach { candidate ->
                                MemoryInboxCard(
                                    candidate = candidate,
                                    onIgnore = { viewModel.ignore(candidate.id) },
                                    onEdit = { viewModel.edit(candidate.id) },
                                    onSave = { viewModel.save(candidate.id) },
                                )
                            }
                        }
                        state.showsEmptyState -> Text(
                            text = stringResource(R.string.memory_inbox_empty),
                            style = memoryText(15f, 22f),
                            color = colors.textSecondary,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 32.dp),
                        )
                    }
                    MemoryFootnote(
                        icon = MemoryGlyphs.Device,
                        text = stringResource(R.string.memory_inbox_footnote),
                        size = 12.5f,
                        modifier = Modifier.padding(top = 14.dp),
                    )
                }
            }
        }
    }

    editor?.let { editing ->
        MemoryItemEditorSheet(
            state = editing.state,
            onGroupChange = viewModel::updateEditorGroup,
            onTextChange = viewModel::updateEditorText,
            onSave = viewModel::saveEditor,
            onDismiss = viewModel::dismissEditor,
        )
    }
}

/** One suggestion card: group eyebrow, quoted text, ignore / edit / save. */
@Composable
private fun MemoryInboxCard(
    candidate: MemoryCandidate,
    onIgnore: () -> Unit,
    onEdit: () -> Unit,
    onSave: () -> Unit,
) {
    val colors = OriveoTheme.colors
    // the eyebrow follows the proposed layer, not the kind — episodic suggestions sit under "Events & decisions".
    val episodic = candidate.proposedLayer == MemoryLayer.EPISODIC
    val group = candidate.inboxGroup()
    val glyph = if (episodic) MemoryGlyphs.Episodic else group.glyph
    val hue = if (episodic) colors.memoryHueEpisodic else memoryGroupHue(group)
    val title = if (episodic) stringResource(R.string.memory_group_episodic) else memoryItemGroupTitle(group)
    val divider = colors.border
    Column(
        modifier = Modifier
            .padding(top = 12.dp)
            .fillMaxWidth()
            .memoryCard(outlined = true)
            .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(glyph, contentDescription = null, tint = hue, modifier = Modifier.size(14.dp))
            Text(
                text = title,
                style = memoryText(12.5f, 16f, FontWeight.SemiBold),
                color = colors.textSecondary,
            )
        }
        Row(modifier = Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            // Decorative open quote mark in front of the suggestion.
            Text(
                text = "“",
                style = memoryText(24f, 24f, FontWeight.Bold).copy(fontFamily = FontFamily.Serif),
                color = colors.primary,
                modifier = Modifier.clearAndSetSemantics {},
            )
            Text(
                text = candidate.content,
                style = memoryText(17f, 25f, FontWeight.Medium).copy(letterSpacing = (-0.1).sp),
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
        }
        Row(
            modifier = Modifier
                .padding(top = 12.dp)
                .fillMaxWidth()
                .drawBehind { drawLine(divider, Offset(0f, 0.5f), Offset(size.width, 0.5f), 1.dp.toPx()) }
                .padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MemoryInboxAction(stringResource(R.string.memory_suggestion_ignore), "memory_inbox_ignore_button", primary = false, onClick = onIgnore)
            MemoryInboxAction(stringResource(R.string.memory_suggestion_edit), "memory_inbox_edit_button", primary = false, onClick = onEdit)
            MemoryInboxAction(stringResource(R.string.memory_suggestion_save), "memory_inbox_save_button", primary = true, onClick = onSave)
        }
    }
}

@Composable
private fun MemoryInboxAction(label: String, tag: String, primary: Boolean, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .padding(start = if (primary) 4.dp else 0.dp)
            .height(36.dp)
            .clip(CircleShape)
            .then(if (primary) Modifier.background(colors.primaryTextSafe) else Modifier)
            .clickable(onClick = onClick)
            .padding(horizontal = if (primary) 16.dp else 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = memoryText(14.5f, 19f, FontWeight.SemiBold),
            color = if (primary) colors.onPrimary else colors.textSecondary,
            maxLines = 1,
        )
    }
}
