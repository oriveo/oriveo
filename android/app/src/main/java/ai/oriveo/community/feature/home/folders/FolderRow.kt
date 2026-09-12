package ai.oriveo.community.feature.home.folders

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.model.FolderColor
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.homescreen.homeGroupedCardSurface
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * One folder row on the home screen, laid out to match the iOS folder row.
 *
 * Left to right: a 34dp colour icon, the folder name, a capsule with the conversation count, and a
 * chevron that turns as the row expands.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FolderRow(
    folder: Folder,
    count: Int,
    isExpanded: Boolean,
    onToggleExpanded: () -> Unit,
    onViewAll: () -> Unit,
    onRename: () -> Unit,
    onChangeColor: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }
    val colors = OriveoTheme.colors

    Column(modifier = modifier) {
            // Folder header: the same card face as the home conversation groups (radius 20 / dark #221F35 / light pure white); tap to expand or collapse, long press for the menu
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .homeGroupedCardSurface()
                    .combinedClickable(
                        onClick = onToggleExpanded,
                        onLongClick = { showMenu = true },
                    )
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {

                val fc = FolderColor.fromTag(folder.colorTag)
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .shadow(
                            elevation = 4.dp,
                            shape = RoundedCornerShape(10.dp),
                            ambientColor = fc.toColor().copy(alpha = 0.25f),
                            spotColor = fc.toColor().copy(alpha = 0.25f),
                        )
                        .clip(RoundedCornerShape(10.dp))
                        .background(fc.gradientBrush()),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = if (isExpanded) Icons.Outlined.FolderOpen else Icons.Outlined.Folder,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),

                        tint = Color.White,
                    )
                }

                Text(
                    text = folder.name,
                    fontSize = 16.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AuroraTheme.textPrimary(),
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )

                if (count > 0) {
                    Text(
                        text = "$count",
                        fontSize = 12.sp,
                        lineHeight = 15.sp,
                        fontWeight = FontWeight.Medium,
                        color = AuroraTheme.textTertiary(),
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(colors.backgroundSecondary)
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                }

                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    modifier = Modifier
                        .size(16.dp)
                        .rotate(if (isExpanded) 90f else 0f),
                    tint = AuroraTheme.textTertiary(),
                )

                if (showMenu) {
                    DropdownMenu(
                        expanded = true,
                        onDismissRequest = { showMenu = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.view_all)) },
                            onClick = { showMenu = false; onViewAll() },
                            leadingIcon = { Icon(Icons.Outlined.Visibility, contentDescription = null) },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.rename)) },
                            onClick = { showMenu = false; onRename() },
                            leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.change_color)) },
                            onClick = { showMenu = false; onChangeColor() },
                            leadingIcon = { Icon(Icons.Outlined.Palette, contentDescription = null) },
                        )
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.delete_folder), color = colors.danger) },
                            onClick = { showMenu = false; onDelete() },
                            leadingIcon = {
                                Icon(Icons.Outlined.Delete, contentDescription = null, tint = colors.danger)
                            },
                        )
                    }
                }
            }

            // Expanded content sits 8 below the header card and brings its own group card face (decided by the caller's content)
            AnimatedVisibility(
                visible = isExpanded,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                Column(
                    modifier = Modifier.padding(top = 8.dp),
                ) {
                    content()
                }
            }
    }
}
