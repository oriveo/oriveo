package ai.oriveo.community.feature.chat.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.feature.chat.ExpensiveModelHint
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun ExpensiveModelHintBanner(
    hint: ExpensiveModelHint,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.warning.copy(alpha = 0.08f))
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Icon(
            imageVector = Icons.Outlined.Warning,
            contentDescription = null,
            tint = colors.warning,
            modifier = Modifier.size(14.dp),
        )

        Text(
            text = stringResource(R.string.expensive_model_hint, hint.newModelName, hint.multiplier, hint.oldModelName),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )

        IconButton(
            onClick = onDismiss,
            modifier = Modifier.size(24.dp),
        ) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = stringResource(R.string.close),
                tint = colors.textTertiary,
                modifier = Modifier.size(12.dp),
            )
        }
    }
}
