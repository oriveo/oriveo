package ai.oriveo.community.feature.home.folders

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.FolderColor

/**
 * Folder colour picker: the ten palette entries in a wrapping row inside an AlertDialog, matching
 * the iOS colour picker's layout and order.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FolderColorPickerDialog(
    currentTag: String?,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.change_color)) },
        text = {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                FolderColor.entries.forEach { fc ->
                    val isSelected = fc.tag == (currentTag ?: FolderColor.BLUE.tag)
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .shadow(3.dp, CircleShape, ambientColor = fc.toColor().copy(alpha = 0.3f))
                            .clip(CircleShape)
                            .background(fc.gradientBrush())
                            .clickable {
                                onSelect(fc.tag)
                                onDismiss()
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (isSelected) {
                            Icon(
                                Icons.Filled.Check,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),

                                tint = Color.White,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}
