package ai.oriveo.community.feature.home.homescreen

import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraGreeting
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.HOME_HEADER_ACTION_BUTTON_SIZE_DP
import ai.oriveo.community.feature.home.HOME_HEADER_ACTION_ICON_SIZE_DP
import ai.oriveo.community.feature.home.HOME_HEADER_ACTION_SPACING_DP
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

@Composable
internal fun HomeHeader(
    greetingName: String,
    isSearching: Boolean,
    isEditing: Boolean,
    searchQuery: String,
    hasConversations: Boolean,
    isDark: Boolean,
    onSearchQueryChange: (String) -> Unit,
    onToggleSearch: () -> Unit,
    onExitEdit: () -> Unit,
    onCreateFolder: () -> Unit,
    onGreetingNameClick: () -> Unit = {},
) {
    val colors = OriveoTheme.colors
    val auroraAccent = AuroraTheme.accent()

    val screenH = OriveoTheme.layout.screenH
    Column(
        modifier = Modifier.padding(
            start = screenH,
            end = screenH,
            top = screenH,
        ),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {

        Row(
            modifier = Modifier.fillMaxWidth().heightInMin(28.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val locale = androidx.compose.ui.platform.LocalConfiguration.current.locales[0]
            val isCJK = remember(locale) { isHomeHeaderCJKLocale(locale) }
            val dateText = remember(locale) {
                formatHomeHeaderDate(Date(), locale)
            }
            Text(
                text = if (isCJK) dateText else dateText.uppercase(locale),
                fontSize = if (isCJK) 13.sp else 12.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
                color = AuroraTheme.textTertiary(),
                letterSpacing = if (isCJK) 0.sp else 1.2.sp,
                maxLines = 1,
            )

            Spacer(modifier = Modifier.weight(1f))

            if (hasConversations || isSearching || isEditing) {
                if (isEditing) {
                    TextButton(onClick = onExitEdit) {
                        Text(
                            text = stringResource(R.string.done),
                            fontSize = 15.sp,
                            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                            color = auroraAccent,
                        )
                    }
                } else {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(HOME_HEADER_ACTION_SPACING_DP.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        AuroraHeaderIconButton(
                            imageVector = Icons.Outlined.CreateNewFolder,
                            contentDescription = stringResource(R.string.new_folder),
                            onClick = onCreateFolder,
                        )
                        AuroraHeaderIconButton(
                            imageVector = Icons.Outlined.Search,
                            contentDescription = stringResource(R.string.search),
                            onClick = onToggleSearch,
                        )
                    }
                }
            }
        }

        if (!isSearching) {
            HeroGreeting(
                greetingName = greetingName,
                isDark = isDark,
                onNameClick = onGreetingNameClick,
            )
        }

        if (isSearching) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(42.dp)
                        .clip(RoundedCornerShape(50))
                        .background(AuroraTheme.cardFill(), RoundedCornerShape(50))
                        .border(0.8.dp, AuroraTheme.cardBorder(), RoundedCornerShape(50)),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Search,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                            tint = AuroraTheme.textTertiary(),
                        )
                        Box(modifier = Modifier.weight(1f)) {
                            BasicTextField(
                                value = searchQuery,
                                onValueChange = onSearchQueryChange,
                                singleLine = true,
                                textStyle = OriveoTheme.typography.caption.copy(color = AuroraTheme.textPrimary()),
                                cursorBrush = SolidColor(auroraAccent),
                                modifier = Modifier.fillMaxWidth(),
                                decorationBox = { innerTextField ->
                                    Box(contentAlignment = Alignment.CenterStart) {
                                        if (searchQuery.isEmpty()) {
                                            Text(
                                                text = stringResource(R.string.search_conversation_titles_or_content),
                                                style = OriveoTheme.typography.caption,
                                                color = AuroraTheme.textTertiary(),
                                            )
                                        }
                                        innerTextField()
                                    }
                                },
                            )
                        }
                    }
                }
                TextButton(onClick = onToggleSearch) {
                    Text(
                        text = stringResource(R.string.cancel),
                        fontSize = 15.sp,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
                        color = auroraAccent,
                    )
                }
            }
        }
    }
}

internal fun isHomeHeaderCJKLocale(locale: Locale): Boolean =
    locale.language in setOf("zh", "ja", "ko")

internal fun formatHomeHeaderDate(
    date: Date,
    locale: Locale,
    timeZone: TimeZone = TimeZone.getDefault(),
): String {
    // Chinese/Japanese: 5<month>7<day> <weekday>, using the numeric + unit style both share.
    // Korean:            5월 7일 목요일
    // Everything else:   Thursday, May 7
    val pattern = when (locale.language) {
        "zh", "ja" -> "M\u6708d\u65e5 EEEE"
        "ko" -> "M월 d일 EEEE"
        else -> "EEEE, MMMM d"
    }
    return SimpleDateFormat(pattern, locale).apply {
        this.timeZone = timeZone
    }.format(date)
}

@Composable
private fun HeroGreeting(
    greetingName: String,
    isDark: Boolean,
    onNameClick: () -> Unit = {},
) {
    val resources = androidx.compose.ui.platform.LocalResources.current
    val line = remember(greetingName, resources) {
        if (greetingName.isBlank()) {
            resources.getString(AuroraGreeting.greetingResId())
        } else {
            resources.getString(AuroraGreeting.nameGreetingResId(), greetingName)
        }
    }
    val tagline = remember(resources) { resources.getString(AuroraGreeting.taglineResId()) }
    val gradient = remember(isDark) {
        Brush.linearGradient(
            colors = if (isDark) {
                listOf(AuroraTheme.Colors.heroGradientDarkStart, AuroraTheme.Colors.heroGradientDarkEnd)
            } else {
                listOf(AuroraTheme.Colors.heroGradientLightStart, AuroraTheme.Colors.heroGradientLightEnd)
            },
        )
    }
    val heroStyle = remember(gradient) {
        AuroraTheme.Typography.hero.copy(
            fontSize = 28.sp,
            lineHeight = 32.sp,
            letterSpacing = (-0.4).sp,
            brush = gradient,
        )
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {

        val nameClickModifier = if (greetingName.isBlank()) {
            Modifier
        } else {
            Modifier.clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onNameClick,
            )
        }
        Text(
            text = line,
            style = heroStyle,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = nameClickModifier,
        )
        Text(
            text = tagline,
            fontSize = 16.sp,
            color = AuroraTheme.textSecondary(),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun AuroraHeaderIconButton(
    imageVector: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String?,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(HOME_HEADER_ACTION_BUTTON_SIZE_DP.dp),
        colors = IconButtonDefaults.iconButtonColors(
            contentColor = AuroraTheme.textSecondary(),
        ),
    ) {
        Icon(
            imageVector = imageVector,
            contentDescription = contentDescription,
            modifier = Modifier.size(HOME_HEADER_ACTION_ICON_SIZE_DP.dp),
        )
    }
}

internal fun Modifier.heightInMin(min: androidx.compose.ui.unit.Dp): Modifier =
    this.heightIn(min = min)
