package ai.oriveo.community.feature.storage

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.oriveo.community.R
import ai.oriveo.community.core.data.database.DatabaseBlockedReason
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
fun DatabaseBlockedDialog(
    reason: DatabaseBlockedReason,
    isChecking: Boolean,
    onRetry: () -> Unit,
    onFreeUpSpace: () -> Unit,
    onContactSupport: () -> Unit,
) {
    val isStorageFull = reason == DatabaseBlockedReason.StorageFull
    val title = stringResource(
        if (isStorageFull) R.string.storage_blocked_title else R.string.database_unavailable_title,
    )
    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        
        BackHandler(enabled = true) {}
        val colors = OriveoTheme.colors
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(colors.background)
                .safeDrawingPadding()
                .semantics { paneTitle = title },
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier = Modifier
                    .widthIn(max = 420.dp)
                    .padding(horizontal = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Storage,
                    contentDescription = null,
                    tint = colors.danger,
                    modifier = Modifier.size(50.dp),
                )
                Text(
                    text = title,
                    color = colors.textPrimary,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                )
                Text(
                    text = stringResource(
                        if (isStorageFull) {
                            R.string.storage_blocked_message
                        } else {
                            R.string.database_unavailable_message
                        },
                    ),
                    color = colors.textSecondary,
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center,
                )

                if (isStorageFull) {
                    OriveoPrimaryButton(
                        text = stringResource(R.string.storage_blocked_action_free_space),
                        onClick = onFreeUpSpace,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                    RetryButton(isChecking = isChecking, onRetry = onRetry)
                } else {
                    OriveoPrimaryButton(
                        text = stringResource(R.string.retry),
                        onClick = onRetry,
                        modifier = Modifier.padding(top = 8.dp),
                        enabled = !isChecking,
                        loading = isChecking,
                    )
                    OutlinedButton(
                        onClick = onContactSupport,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(stringResource(R.string.contact_support))
                    }
                }
            }
        }
    }
}

@Composable
private fun RetryButton(isChecking: Boolean, onRetry: () -> Unit) {
    OutlinedButton(
        onClick = onRetry,
        enabled = !isChecking,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (isChecking) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                )
            }
            Text(stringResource(R.string.retry))
        }
    }
}
