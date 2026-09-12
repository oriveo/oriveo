package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraGreeting
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.auroraChromeCapsule
import ai.oriveo.community.ui.component.rememberBrandPainter
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Top bar height (iOS homeTopBarHeight) */
internal val HOME_TOP_BAR_HEIGHT = 40.dp

/** Height of the "search | new folder" capsule; each button is 36×38 visually with a 44 hit height (iOS homeHeaderCapsuleHeight / ActionHit*) */
internal val HOME_HEADER_CAPSULE_HEIGHT = 38.dp
internal val HOME_HEADER_ACTION_HIT_WIDTH = 36.dp
internal val HOME_HEADER_ACTION_HIT_HEIGHT = 44.dp

/** Capsule icon box: Material icons leave about 2 units of margin on the 24 grid, so an 18dp box shows a glyph ≈ a 14pt SF Symbol on iOS */
internal val HOME_HEADER_ACTION_ICON_BOX = 18.dp

/**
 * Aurora home masthead (matches iOS HomeView.header / topBar / heroGreeting / searchBar).
 *
 * - Top bar: equal flexible widths on both sides keep the brand (logo + wordmark) exactly centered; the trailing
 *   "search | new folder" capsule becomes Done in edit mode. The capsule appearing, disappearing or turning into
 *   Done never pushes the brand.
 * - Not searching: centered greeting (date eyebrow / 30sp greeting with the gradient on the name only / tagline).
 * - Searching: a capsule search field replaces the greeting area.
 */
@Composable
internal fun HomeHeader(
    isSearching: Boolean,
    isEditing: Boolean,
    searchQuery: String,
    hasConversations: Boolean,
    isDark: Boolean,
    onSearchQueryChange: (String) -> Unit,
    onToggleSearch: () -> Unit,
    onExitEdit: () -> Unit,
    onCreateFolder: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        HomeTopBar(
            showsActions = hasConversations || isSearching || isEditing,
            isEditing = isEditing,
            isSearching = isSearching,
            isDark = isDark,
            onToggleSearch = onToggleSearch,
            onExitEdit = onExitEdit,
            onCreateFolder = onCreateFolder,
        )

        if (isSearching) {
            HomeSearchBar(
                searchQuery = searchQuery,
                onSearchQueryChange = onSearchQueryChange,
                onCancel = onToggleSearch,
                modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 18.dp),
            )
        } else {
            HeroGreeting(
                nowMillis = rememberHomeHeaderNowMillis(),
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 22.dp),
            )
        }
    }
}

@Composable
private fun HomeTopBar(
    showsActions: Boolean,
    isEditing: Boolean,
    isSearching: Boolean,
    isDark: Boolean,
    onToggleSearch: () -> Unit,
    onExitEdit: () -> Unit,
    onCreateFolder: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(HOME_TOP_BAR_HEIGHT)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Two equal flexible boxes flank the brand so changes on the trailing side never move it
        Box(modifier = Modifier.weight(1f))
        HomeBrandMark()
        Box(
            modifier = Modifier.weight(1f),
            contentAlignment = Alignment.CenterEnd,
        ) {
            if (showsActions) {
                if (isEditing) {
                    Box(
                        modifier = Modifier
                            .heightIn(min = HOME_HEADER_ACTION_HIT_HEIGHT)
                            .widthIn(min = HOME_HEADER_ACTION_HIT_HEIGHT)
                            .clickable(role = Role.Button, onClick = onExitEdit),
                        contentAlignment = Alignment.CenterEnd,
                    ) {
                        Text(
                            text = stringResource(R.string.done),
                            fontSize = 15.sp,
                            lineHeight = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = AuroraTheme.accent(),
                            maxLines = 1,
                        )
                    }
                } else {
                    HomeHeaderActionCapsule(
                        isSearching = isSearching,
                        isDark = isDark,
                        onToggleSearch = onToggleSearch,
                        onCreateFolder = onCreateFolder,
                    )
                }
            }
        }
    }
}

/** Centered brand: the 26 logo + "Oriveo" at 17/bold with -0.3 letter spacing, 8 apart. */
@Composable
private fun HomeBrandMark() {
    Row(
        modifier = Modifier.semantics(mergeDescendants = true) { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Image(
            painter = rememberBrandPainter(R.drawable.ic_oriveo_logo, 26.dp),
            contentDescription = null,
            modifier = Modifier.size(26.dp),
        )
        Text(
            text = stringResource(R.string.app_name),
            fontSize = 17.sp,
            lineHeight = 22.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = (-0.3).sp,
            color = AuroraTheme.textPrimary(),
            maxLines = 1,
        )
    }
}

/**
 * The "search | new folder" capsule: 38 high, 2 of horizontal padding, a 1×16 divider in the middle, secondary
 * icons. Glass look in [auroraChromeCapsule]; each button is 36×38 visually with the hit area extended to 44
 * vertically without changing layout.
 */
@Composable
private fun HomeHeaderActionCapsule(
    isSearching: Boolean,
    isDark: Boolean,
    onToggleSearch: () -> Unit,
    onCreateFolder: () -> Unit,
) {
    Row(
        modifier = Modifier
            .height(HOME_HEADER_CAPSULE_HEIGHT)
            .auroraChromeCapsule(isDark = isDark, shape = CircleShape)
            .padding(horizontal = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The search button is a toggle: tapping it while open collapses and clears the query, so TalkBack needs its selected state
        HomeHeaderCapsuleButton(
            imageVector = Icons.Outlined.Search,
            contentDescription = stringResource(R.string.search),
            isSelected = isSearching,
            onClick = onToggleSearch,
        )
        Box(
            modifier = Modifier
                .size(width = 1.dp, height = 16.dp)
                .background(AuroraTheme.chromeDivider()),
        )
        HomeHeaderCapsuleButton(
            imageVector = Icons.Outlined.CreateNewFolder,
            contentDescription = stringResource(R.string.new_folder),
            onClick = onCreateFolder,
        )
    }
}

@Composable
private fun HomeHeaderCapsuleButton(
    imageVector: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    isSelected: Boolean = false,
) {
    // 36×38 visually; Compose hit testing extends clickable nodes smaller than 48dp to the minimum touch size, so the layout need not grow for the hit area
    Box(
        modifier = Modifier
            .size(width = HOME_HEADER_ACTION_HIT_WIDTH, height = HOME_HEADER_CAPSULE_HEIGHT)
            .semantics {
                this.contentDescription = contentDescription
                this.role = Role.Button
                if (isSelected) this.selected = true
            }
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = 20.dp),
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = imageVector,
            contentDescription = null,
            modifier = Modifier.size(HOME_HEADER_ACTION_ICON_BOX),
            tint = AuroraTheme.textSecondary(),
        )
    }
}

internal fun homeHeaderUsesCasedEyebrow(locale: Locale): Boolean =
    // "11sp + uppercase + letter spacing" only suits scripts with letter case (Latin / Cyrillic). CJK, Arabic,
    // Devanagari and Thai have no case, and letter spacing would break Arabic joining and the Devanagari headline,
    // so they get 13sp, no uppercase, no spacing (matches iOS homeHeaderUsesCasedEyebrow).
    locale.language !in setOf("zh", "ja", "ko", "ar", "hi", "th")

internal fun formatHomeHeaderDate(
    date: Date,
    locale: Locale,
    timeZone: TimeZone = TimeZone.getDefault(),
): String {
    // Chinese / Japanese: 5<month>7<day> <weekday>, using the numeric + unit style both share
    // Korean:             5월 7일 목요일
    // Everything else:    Thursday, May 7
    val pattern = when (locale.language) {
        "zh", "ja" -> "M月d日 EEEE"
        "ko" -> "M월 d일 EEEE"
        else -> "EEEE, MMMM d"
    }
    return SimpleDateFormat(pattern, locale).apply {
        this.timeZone = timeZone
    }.format(date)
}

/** Milliseconds until the next local full hour: the period boundaries at 5/12/18/23 and midnight all fall on full hours; computed per time zone so offsets like +05:30 work. */
internal fun millisUntilNextLocalHour(nowMillis: Long, timeZone: TimeZone = TimeZone.getDefault()): Long {
    val next = Calendar.getInstance(timeZone).apply {
        timeInMillis = nowMillis
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
        add(Calendar.HOUR_OF_DAY, 1)
    }
    return (next.timeInMillis - nowMillis).coerceAtLeast(1L)
}

/**
 * Wall clock for the masthead: re-read from the current time whenever the app returns to the foreground, and
 * advanced at the next local full hour while it stays there. The date, greeting period and tagline all key off it;
 * otherwise a phone left on Home at 23:50 would still show yesterday's date and "Still up" the next day. delay
 * does not follow the wall clock (it pauses in deep sleep), so returning to the foreground must re-read rather
 * than rely on the timer alone.
 */
@Composable
private fun rememberHomeHeaderNowMillis(): Long {
    val lifecycleOwner = LocalLifecycleOwner.current
    var nowMillis by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val now = System.currentTimeMillis()
                nowMillis = now
                delay(millisUntilNextLocalHour(now))
            }
        }
    }
    return nowMillis
}

/** Centered greeting: date eyebrow / 30sp greeting / tagline (one of four per period of the day). */
@Composable
private fun HeroGreeting(
    nowMillis: Long,
    modifier: Modifier = Modifier,
) {
    val resources = LocalResources.current
    val locale = LocalConfiguration.current.locales[0]
    val usesCasedEyebrow = remember(locale) { homeHeaderUsesCasedEyebrow(locale) }
    val dateText = remember(locale, nowMillis) {
        val text = formatHomeHeaderDate(Date(nowMillis), locale)
        if (usesCasedEyebrow) text.uppercase(locale) else text
    }
    val greeting = remember(resources, nowMillis) {
        resources.getString(AuroraGreeting.greetingResId(Calendar.getInstance().apply { timeInMillis = nowMillis }))
    }
    val tagline = remember(resources, nowMillis) {
        resources.getString(AuroraGreeting.taglineResId(Calendar.getInstance().apply { timeInMillis = nowMillis }))
    }
    val textTertiary = AuroraTheme.textTertiary()

    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // The date row holds only the date
        Text(
            text = dateText,
            fontSize = if (usesCasedEyebrow) 11.sp else 13.sp,
            lineHeight = if (usesCasedEyebrow) 14.sp else 16.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = if (usesCasedEyebrow) 1.3.sp else 0.sp,
            color = textTertiary,
            maxLines = 1,
        )

        BasicText(
            text = greeting,
            modifier = Modifier
                .padding(top = 8.dp)
                .fillMaxWidth(),
            style = TextStyle(
                fontSize = 30.sp,
                lineHeight = 36.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.7).sp,
                color = AuroraTheme.textPrimary(),
                textAlign = TextAlign.Center,
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            // iOS minimumScaleFactor(0.75)
            autoSize = TextAutoSize.StepBased(minFontSize = 22.5.sp, maxFontSize = 30.sp, stepSize = 0.5.sp),
        )

        BasicText(
            text = tagline,
            modifier = Modifier
                .padding(top = 6.dp)
                .fillMaxWidth(),
            style = TextStyle(
                fontSize = 15.sp,
                lineHeight = 20.sp,
                color = AuroraTheme.textSecondary(),
                textAlign = TextAlign.Center,
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            // iOS minimumScaleFactor(0.85)
            autoSize = TextAutoSize.StepBased(minFontSize = 12.75.sp, maxFontSize = 15.sp, stepSize = 0.25.sp),
        )
    }
}

/** Search state: a capsule search field (cardFill + 0.8dp cardBorder) with Cancel on the right. */
@Composable
private fun HomeSearchBar(
    searchQuery: String,
    onSearchQueryChange: (String) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = AuroraTheme.accent()
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .height(42.dp)
                .background(AuroraTheme.cardFill(), RoundedCornerShape(50))
                .border(0.8.dp, AuroraTheme.cardBorder(), RoundedCornerShape(50))
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Search,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = AuroraTheme.textTertiary(),
            )
            val textStyle = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, color = AuroraTheme.textPrimary())
            val placeholder = stringResource(R.string.search_conversation_titles_or_content)
            BasicTextField(
                value = searchQuery,
                onValueChange = onSearchQueryChange,
                singleLine = true,
                textStyle = textStyle,
                cursorBrush = SolidColor(accent),
                modifier = Modifier
                    .weight(1f)
                    .semantics { contentDescription = placeholder },
                decorationBox = { innerTextField ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (searchQuery.isEmpty()) {
                            Text(
                                text = placeholder,
                                style = textStyle,
                                color = AuroraTheme.textTertiary(),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.clearAndSetSemantics { },
                            )
                        }
                        innerTextField()
                    }
                },
            )
        }
        Box(
            modifier = Modifier
                .heightIn(min = HOME_HEADER_ACTION_HIT_HEIGHT)
                .clickable(role = Role.Button, onClick = onCancel),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = stringResource(R.string.cancel),
                fontSize = 15.sp,
                lineHeight = 18.sp,
                fontWeight = FontWeight.Medium,
                color = accent,
                maxLines = 1,
            )
        }
    }
}
