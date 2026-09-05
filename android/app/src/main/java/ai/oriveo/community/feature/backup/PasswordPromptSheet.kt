package ai.oriveo.community.feature.backup

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.OriveoLabeledField
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoTextButton
import ai.oriveo.community.ui.theme.OriveoTheme


@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PasswordPromptSheet(
    password: String,
    onPasswordChange: (String) -> Unit,
    onUnlock: () -> Unit,
    onSkip: () -> Unit,
    onDismiss: () -> Unit,
    errorMessage: String? = null,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.backgroundBase,
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = layout.screenH)
                .padding(bottom = spacing.xxl),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.align(Alignment.End),
            ) {
                Text(stringResource(R.string.cancel), color = colors.textSecondary)
            }

            Spacer(modifier = Modifier.height(spacing.lg))

            
            Icon(
                imageVector = Icons.Outlined.Lock,
                contentDescription = null,
                modifier = Modifier.size(48.dp),
                tint = colors.primary,
            )

            Spacer(modifier = Modifier.height(layout.sectionGap))

            
            Text(
                text = stringResource(R.string.enter_backup_password),
                style = OriveoTheme.typography.title2,
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
            )

            Spacer(modifier = Modifier.height(spacing.sm))

            
            Text(
                text = stringResource(R.string.password_prompt_description),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = spacing.lg),
            )

            Spacer(modifier = Modifier.height(layout.sectionGap))

            
            OriveoLabeledField(
                label = stringResource(R.string.password),
                value = password,
                onValueChange = onPasswordChange,
                placeholder = stringResource(R.string.enter_backup_password_placeholder),
                isSecure = true,
            )

            
            if (errorMessage != null) {
                Spacer(modifier = Modifier.height(spacing.sm))
                Text(
                    text = errorMessage,
                    style = OriveoTheme.typography.caption,
                    color = colors.danger,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(modifier = Modifier.height(layout.sectionGap))

            
            OriveoPrimaryButton(
                text = stringResource(R.string.unlock_and_import),
                onClick = onUnlock,
                enabled = password.isNotEmpty(),
            )

            Spacer(modifier = Modifier.height(spacing.md))

            
            OriveoTextButton(
                text = stringResource(R.string.skip_api_keys),
                onClick = onSkip,
            )
        }
    }
}
