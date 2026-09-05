package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.ui.component.rememberAttachmentThumbnailBitmap
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity


@Composable
internal fun ComposerAttachmentThumbnail(
    attachment: Attachment,
    onRemove: () -> Unit,
    onTapKnowledgeCTA: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val imageFrameShape = RoundedCornerShape(18.dp)
    val imageShape = RoundedCornerShape(15.dp)
    val fileShape = RoundedCornerShape(16.dp)
    val showCta = onTapKnowledgeCTA != null && attachment.extractedTruncated == true

    Box {
        if (attachment.kind == AttachmentKind.Image) {
            val bitmap = rememberAttachmentThumbnailBitmap(attachment)

            Box(
                modifier = Modifier
                    .size(68.dp)
                    .shadow(
                        elevation = 8.dp,
                        shape = imageFrameShape,
                        ambientColor = colors.shadow.opacity(0.045f),
                        spotColor = colors.shadow.opacity(0.045f),
                    )
                    .clip(imageFrameShape)
                    .background(
                        brush = Brush.linearGradient(
                            colors = listOf(colors.surfaceChrome, colors.surfaceElevated),
                            start = Offset.Zero,
                            end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                        ),
                        shape = imageFrameShape,
                    )
                    .border(
                        width = 1.dp,
                        brush = Brush.linearGradient(
                            colors = listOf(colors.cardHighlight.opacity(0.26f), Color.Transparent),
                            start = Offset.Zero,
                            end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                        ),
                        shape = imageFrameShape,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap,
                        contentDescription = attachment.fileName,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(60.dp)
                            .clip(imageShape),
                    )
                } else {
                    Box(
                        modifier = Modifier
                            .size(60.dp)
                            .clip(imageShape)
                            .background(colors.surfaceInset),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Image,
                            contentDescription = null,
                            modifier = Modifier.size(20.dp),
                            tint = colors.textSecondary,
                        )
                    }
                }

                Box(
                    modifier = Modifier
                        .size(60.dp)
                        .clip(imageShape)
                        .background(
                            brush = Brush.verticalGradient(
                                colors = listOf(Color.Transparent, colors.overlay.opacity(0.13f)),
                            ),
                        ),
                )
            }
        } else {
            
            val chipHeight = if (showCta) 102.dp else 68.dp
            Column(
                modifier = Modifier
                    .size(width = 82.dp, height = chipHeight)
                    .shadow(
                        elevation = 8.dp,
                        shape = fileShape,
                        ambientColor = colors.shadow.opacity(0.04f),
                        spotColor = colors.shadow.opacity(0.04f),
                    )
                    .clip(fileShape)
                    .background(
                        brush = Brush.linearGradient(
                            colors = listOf(colors.surfaceChrome, colors.surfaceElevated),
                            start = Offset.Zero,
                            end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                        ),
                        shape = fileShape,
                    )
                    .border(
                        width = 1.dp,
                        brush = Brush.linearGradient(
                            colors = listOf(colors.cardHighlight.opacity(0.24f), Color.Transparent),
                            start = Offset.Zero,
                            end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                        ),
                        shape = fileShape,
                    )
                    .padding(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.Start,
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(
                                brush = Brush.linearGradient(
                                    colors = listOf(colors.primarySoft, colors.surfaceElevated),
                                    start = Offset.Zero,
                                    end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                                ),
                                shape = RoundedCornerShape(10.dp),
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Description,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                            tint = colors.primary,
                        )
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    composerFileExtensionLabel(attachment.fileName)?.let { extensionLabel ->
                        Box(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(colors.surfaceInset, CircleShape)
                                .padding(horizontal = 6.dp)
                                .height(18.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = extensionLabel,
                                style = OriveoTheme.typography.footnote.copy(fontSize = 9.sp),
                                color = colors.textSecondary,
                                maxLines = 1,
                            )
                        }
                    }
                }

                Spacer(modifier = Modifier.weight(1f))

                Text(
                    text = composerDisplayFileName(attachment.fileName),
                    style = OriveoTheme.typography.footnote.copy(fontSize = 10.5.sp),
                    color = colors.textPrimary,
                    maxLines = if (showCta) 1 else 2,
                    overflow = TextOverflow.Ellipsis,
                )

                
                if (showCta) {
                    Text(
                        text = stringResource(R.string.file_extraction_truncated_cta_knowledge),
                        style = OriveoTheme.typography.footnote.copy(fontSize = 8.5.sp),
                        color = colors.primary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clickable(onClick = onTapKnowledgeCTA!!),
                    )
                }
            }
        }

        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .offset(x = 5.dp, y = (-5).dp)
                .size(19.dp)
                .shadow(
                    elevation = 5.dp,
                    shape = CircleShape,
                    ambientColor = colors.shadow.opacity(0.10f),
                    spotColor = colors.shadow.opacity(0.10f),
                )
                .clip(CircleShape)
                .background(colors.surfaceElevated.copy(alpha = if (OriveoTheme.isDark) 0.9f else 0.96f), CircleShape)
                .clickable(onClick = onRemove),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = stringResource(R.string.remove_attachment),
                modifier = Modifier.size(8.5.dp),
                tint = colors.textPrimary,
            )
        }
    }
}
