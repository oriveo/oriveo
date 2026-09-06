package ai.oriveo.community.feature.chat.composer

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun ComposerAttachmentEntryButton(
    icon: ImageVector,
    accent: ComposerCapabilityAccent,
    count: Int,
    emphasized: Boolean,
    disabled: Boolean,
    showMenu: Boolean,
    onDismissMenu: () -> Unit,
    onClick: () -> Unit,
    onPickCamera: () -> Unit,
    onPickImage: () -> Unit,
    onPickVideo: () -> Unit,
    onPickFile: () -> Unit,
    showCameraOption: Boolean,
    showImageOption: Boolean,
    showVideoOption: Boolean,
    showFileOption: Boolean,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val buttonScale by animateFloatAsState(if (pressed) 0.975f else 1f, label = "attachmentButtonScale")

    val flatFill = if (isDark) Color.White.copy(alpha = 0.10f) else Color(0xFF8C5FF8).copy(alpha = 0.12f)

    val iconTint = if (emphasized) colors.primary else colors.textPrimary
    val iconSize = if (icon == Icons.Filled.Add) 17.dp else 16.dp

    Box {
        Box(
            modifier = Modifier
                .size(44.dp)
                .graphicsLayer {
                    scaleX = buttonScale
                    scaleY = buttonScale
                    alpha = if (disabled) 0.52f else if (pressed) 0.94f else 1f
                }
                .clickable(
                    enabled = !disabled,
                    interactionSource = interactionSource,
                    indication = null,
                    onClick = onClick,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(flatFill, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    modifier = Modifier.size(iconSize),
                    tint = iconTint,
                )
            }
        }

        if (count > 0) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .offset(x = 4.dp, y = (-1.5).dp)
                    .clip(CircleShape)
                    .background(
                        brush = Brush.linearGradient(
                            colors = listOf(accent.iconStart, accent.iconEnd),
                            start = Offset.Zero,
                            end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                        ),
                        shape = CircleShape,
                    )
                    .padding(horizontal = 4.dp)
                    .height(15.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = count.toString(),
                    style = OriveoTheme.typography.footnote.copy(fontSize = 8.5.sp, fontWeight = FontWeight.SemiBold),
                    color = Color.White,
                    maxLines = 1,
                )
            }
        }

        if ((listOf(showCameraOption, showImageOption, showVideoOption, showFileOption).count { it }) > 1) {
            DropdownMenu(
                expanded = showMenu,
                onDismissRequest = onDismissMenu,
            ) {
                if (showCameraOption) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.take_photo)) },
                        leadingIcon = { Icon(Icons.Outlined.CameraAlt, contentDescription = null) },
                        onClick = onPickCamera,
                    )
                }
                if (showImageOption) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.photo_library)) },
                        leadingIcon = { Icon(Icons.Outlined.Image, contentDescription = null) },
                        onClick = onPickImage,
                    )
                }
                if (showVideoOption) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.video)) },
                        leadingIcon = { Icon(Icons.Outlined.Videocam, contentDescription = null) },
                        onClick = onPickVideo,
                    )
                }
                if (showFileOption) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.file)) },
                        leadingIcon = { Icon(Icons.Outlined.Description, contentDescription = null) },
                        onClick = onPickFile,
                    )
                }
            }
        }
    }
}
