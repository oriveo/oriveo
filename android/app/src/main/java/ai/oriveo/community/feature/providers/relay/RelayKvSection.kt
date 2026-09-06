package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun RelayKvSection(
    title: String,
    rows: List<RelayKeyValue>,
    onRowsChange: (List<RelayKeyValue>) -> Unit,
    keyPlaceholder: String,
    addLabel: String,
) {
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = title,
            style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
            modifier = Modifier.padding(horizontal = 2.dp),
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(OriveoTheme.radius.md))
                .background(colors.surface)
                .border(OriveoBorderWidth.standard, colors.border, RoundedCornerShape(OriveoTheme.radius.md))
                .padding(OriveoTheme.spacing.sm),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            rows.forEachIndexed { index, row ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OutlinedTextField(
                        value = row.key,
                        onValueChange = { value ->
                            onRowsChange(rows.toMutableList().also { it[index] = row.copy(key = value) })
                        },
                        placeholder = { Text(keyPlaceholder, style = OriveoTheme.typography.footnote) },
                        textStyle = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = row.value,
                        onValueChange = { value ->
                            onRowsChange(rows.toMutableList().also { it[index] = row.copy(value = value) })
                        },
                        placeholder = { Text(stringResource(R.string.relay_value_label), style = OriveoTheme.typography.footnote) },
                        textStyle = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { onRowsChange(rows.toMutableList().also { it.removeAt(index) }) }) {
                        Icon(
                            imageVector = Icons.Filled.RemoveCircle,
                            contentDescription = stringResource(R.string.remove),
                            tint = colors.danger,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
            }
            TextButton(onClick = { onRowsChange(rows + RelayKeyValue("", "")) }) {
                Text(
                    text = "+ $addLabel",
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.primary,
                )
            }
        }
    }
}
