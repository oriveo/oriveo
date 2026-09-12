package ai.oriveo.community.feature.home.folders

import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.FolderOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ModalBottomSheet
import ai.oriveo.community.core.model.FolderColor
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.ui.theme.OriveoTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MoveToFolderSheet(
    folders: List<Folder>,
    hasConversationsInFolder: Boolean,
    onMoveToFolder: (String) -> Unit,
    onRemoveFromFolder: () -> Unit,
    onCreateFolderRequest: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        // Must scroll with many folders, otherwise "new folder / remove from folder" is pushed out of the sheet and unreachable
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(bottom = OriveoTheme.spacing.xl),
        ) {
            Text(
                text = stringResource(R.string.move_to_folder),
                style = OriveoTheme.typography.title3,
                modifier = Modifier.padding(
                    horizontal = OriveoTheme.spacing.lg,
                    vertical = OriveoTheme.spacing.md,
                ),
            )

            folders.forEach { folder ->
                ListItem(
                    headlineContent = { Text(folder.name) },
                    leadingContent = {
                        Icon(Icons.Filled.Folder, null, tint = FolderColor.fromTag(folder.colorTag).toColor())
                    },
                    modifier = Modifier.clickable {
                        onMoveToFolder(folder.id)
                        onDismiss()
                    },
                )
            }

            HorizontalDivider()

            ListItem(
                headlineContent = { Text(stringResource(R.string.new_folder)) },
                leadingContent = {
                    Icon(Icons.Outlined.CreateNewFolder, null, tint = OriveoTheme.colors.primary)
                },
                modifier = Modifier.clickable {
                    onCreateFolderRequest()
                    onDismiss()
                },
            )

            if (hasConversationsInFolder) {
                HorizontalDivider()
                ListItem(
                    headlineContent = {
                        Text(
                            stringResource(R.string.remove_from_folder),
                            color = OriveoTheme.colors.danger,
                        )
                    },
                    leadingContent = {
                        Icon(Icons.Outlined.FolderOff, null, tint = OriveoTheme.colors.danger)
                    },
                    modifier = Modifier.clickable {
                        onRemoveFromFolder()
                        onDismiss()
                    },
                )
            }
        }
    }
}
