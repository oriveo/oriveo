package ai.oriveo.community.feature.chat.components

import android.content.ClipData
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Reading sheet opened by "Show full message" on a folded long user message (see
 * [UserMessageFold]).
 *
 * The text goes into a LazyColumn in [UserMessageFold.readingChunks] pieces. An unchunked Text lays
 * out the whole message at once, which takes hundreds of milliseconds for 200,000 characters of
 * Arabic; chunked, only the few visible pieces are composed and laid out. Selection works per
 * chunk, and copying the whole message goes through the toolbar's Copy.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun UserMessageFullTextSheet(
    text: String,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val chunks = remember(text) { UserMessageFold.readingChunks(text) }
    val clipboard = LocalClipboard.current
    val copyScope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }

    // The sheet has its own layout root: drop the message-level selection registrar first, then give
    // each text chunk its own SelectionContainer (as CodeBlockViewerSheet does; registering across
    // layout trees crashes on long press).
    DisableSelection {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = sheetState,
            containerColor = colors.background,
            dragHandle = null,
        ) {
            Column(modifier = Modifier.fillMaxSize().testTag("user_message_full_text_sheet")) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = OriveoTheme.spacing.md, vertical = OriveoTheme.spacing.sm),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    TextButton(
                        onClick = {
                            copyScope.launch {
                                clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("text", text)))
                            }
                            copied = true
                        },
                    ) {
                        Text(
                            text = stringResource(if (copied) R.string.copied else R.string.copy),
                            color = colors.primary,
                        )
                    }
                    TextButton(onClick = onDismiss) {
                        Text(text = stringResource(R.string.done), color = colors.primary)
                    }
                }
                LazyColumn(
                    modifier = Modifier.fillMaxSize().testTag("user_message_full_text_list"),
                    contentPadding = PaddingValues(
                        start = OriveoTheme.spacing.xl,
                        end = OriveoTheme.spacing.xl,
                        bottom = OriveoTheme.spacing.xl,
                    ),
                ) {
                    itemsIndexed(chunks, key = { index, _ -> index }) { _, chunk ->
                        SelectionContainer {
                            Text(
                                text = chunk,
                                style = OriveoTheme.typography.chatBody,
                                color = colors.textPrimary,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            }
        }
    }
}
