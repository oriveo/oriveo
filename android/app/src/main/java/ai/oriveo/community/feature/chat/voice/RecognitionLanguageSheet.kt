package ai.oriveo.community.feature.chat.voice

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.recognitionLanguageRows
import ai.oriveo.community.ui.component.FlatGroup
import ai.oriveo.community.ui.component.InsetHairline
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.compose.koinInject

/**
 * Recognition language sheet shown over a voice conversation (same rows and keys as the voice settings picker).
 * Picking a row saves it to [settings]; [onDismiss] gets whether the language changed (dismissing = unchanged).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecognitionLanguageSheet(
    onDismiss: (changed: Boolean) -> Unit,
    settings: VoiceEngineSettings = koinInject(),
) {
    OriveoModalBottomSheet(
        onDismissRequest = { onDismiss(false) },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        RecognitionLanguageOptions(settings = settings, onPicked = onDismiss)
    }
}

/** The sheet's content: title and the check rows; [onPicked] gets whether the picked row differs from the saved one. */
@Composable
internal fun RecognitionLanguageOptions(settings: VoiceEngineSettings, onPicked: (changed: Boolean) -> Unit) {
    val current = remember(settings) { settings.recognitionLanguage() }
    val rows = remember(current) { recognitionLanguageRows(current) }
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
    ) {
        Text(
            text = stringResource(R.string.voice_recognition_language),
            style = MaterialTheme.typography.titleMedium,
            color = OriveoTheme.colors.textPrimary,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        FlatGroup {
            rows.forEachIndexed { index, row ->
                if (index > 0) InsetHairline()
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { selected = row.selected }
                        .clickable {
                            val changed = row.tag != current
                            if (changed) settings.setRecognitionLanguage(row.tag)
                            onPicked(changed)
                        }
                        .padding(horizontal = OriveoTheme.spacing.lg, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(
                        text = row.label.resolve(context),
                        style = MaterialTheme.typography.bodyLarge,
                        color = OriveoTheme.colors.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    if (row.selected) {
                        Icon(imageVector = Icons.Filled.Check, contentDescription = null, tint = OriveoTheme.colors.primary)
                    }
                }
            }
        }
    }
}
