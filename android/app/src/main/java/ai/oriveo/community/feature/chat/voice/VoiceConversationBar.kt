package ai.oriveo.community.feature.chat.voice

import android.content.Intent
import android.util.Log
import androidx.annotation.StringRes
import androidx.annotation.VisibleForTesting
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.draw.innerShadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.BreakIterator
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlin.math.ceil

/** Which page hosts the bar; it decides the statuses the bar can legitimately show. */
enum class VoiceConversationPage { Home, Chat }

/** Status words of the bar and the statuses each page can reach. */
object VoiceConversationBarStatus {
    /** Debug builds only: how many times the bar rendered a status [reachable] rules out; smoke cases assert 0. */
    @VisibleForTesting
    val unreachableHits = AtomicInteger(0)

    /**
     * Home only ever listens (with live caption or a say-again notice), thinks, is muted or fails: the first transcript
     * hands over to the chat page before any reply. Anything else on home is a bug. The chat page reaches every key.
     * Both sets equal the contract's pageReachableStatusKeys.
     */
    fun reachable(page: VoiceConversationPage): Set<ConversationStatusKey> = when (page) {
        VoiceConversationPage.Home -> setOf(
            ConversationStatusKey.LISTENING,
            ConversationStatusKey.CAPTION,
            ConversationStatusKey.THINKING,
            ConversationStatusKey.MUTED,
            ConversationStatusKey.SAY_AGAIN,
            ConversationStatusKey.CHECK_LANGUAGE,
            ConversationStatusKey.ERROR,
        )
        VoiceConversationPage.Chat -> ConversationStatusKey.entries.toSet()
    }

    @StringRes
    fun label(key: ConversationStatusKey): Int = when (key) {
        // Caption itself is shown by [text]; this is its fallback while the caption is still empty.
        ConversationStatusKey.LISTENING, ConversationStatusKey.CAPTION -> R.string.voice_conversation_status_listening
        ConversationStatusKey.THINKING -> R.string.voice_conversation_status_thinking
        ConversationStatusKey.SPEAKING -> R.string.voice_conversation_status_speaking
        ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT -> R.string.voice_conversation_status_speaking_tap_to_interrupt
        ConversationStatusKey.MUTED -> R.string.voice_conversation_status_muted
        ConversationStatusKey.AWAITING_APPROVAL -> R.string.voice_conversation_status_awaiting_approval
        ConversationStatusKey.SAY_AGAIN -> R.string.voice_conversation_status_say_again
        ConversationStatusKey.CHECK_LANGUAGE -> R.string.voice_conversation_status_check_language
        ConversationStatusKey.ERROR -> R.string.voice_conversation_status_error
    }

    /**
     * Text in the status word's place: the live [caption] while the status is caption, or under any status for a
     * [realtime] session (its caption is the stage line's text: user / assistant line → text, status line → "", so
     * the status word shows); null when blank or otherwise (use [label]).
     */
    fun captionText(key: ConversationStatusKey, caption: String?, realtime: Boolean = false): String? =
        caption?.takeIf { (realtime || key == ConversationStatusKey.CAPTION) && it.isNotBlank() }

    /** Accessibility action label of the orb (what a tap does); null = the tap does nothing in this status. */
    @StringRes
    fun tapHint(key: ConversationStatusKey): Int? = when (key) {
        ConversationStatusKey.LISTENING, ConversationStatusKey.CAPTION, ConversationStatusKey.SAY_AGAIN,
        ConversationStatusKey.CHECK_LANGUAGE,
        -> R.string.voice_conversation_orb_hint_listening
        ConversationStatusKey.THINKING -> R.string.voice_conversation_orb_hint_thinking
        ConversationStatusKey.SPEAKING, ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT ->
            R.string.voice_conversation_orb_hint_speaking
        ConversationStatusKey.MUTED -> R.string.voice_conversation_unmute_a11y
        ConversationStatusKey.AWAITING_APPROVAL, ConversationStatusKey.ERROR -> null
    }
}

/**
 * DEBUG-only screenshot hook: launching with the intent extra
 * `VOICE_CONVERSATION_DEMO=<status raw value>` (listening, thinking, speaking, speakingTapToInterrupt, muted,
 * awaitingApproval, error) shows the voice bar frozen in that status on home and chat. No microphone, no sound,
 * no controller.
 */
object VoiceConversationDemo {
    const val EXTRA = "VOICE_CONVERSATION_DEMO"

    var status: ConversationStatusKey? = null
        private set

    fun capture(intent: Intent?) {
        if (!BuildConfig.DEBUG) return
        val raw = intent?.getStringExtra(EXTRA) ?: return
        status = parse(raw)
    }

    /** DEBUG-only shot entry: freezes the bar in [status] (null = no demo, the real host runs). No-op in release. */
    fun show(status: ConversationStatusKey?) {
        if (!BuildConfig.DEBUG) return
        this.status = status
    }

    /** Status raw value (listening, thinking, …) → key; unknown → null. */
    fun parse(raw: String?): ConversationStatusKey? = ConversationStatusKey.entries.firstOrNull { it.rawValue == raw }
}


/**
 * Minimum content height of the voice stage (S4 stage contract item 1); the navigation bar inset comes on top.
 * Taller words / chip (large text) grow the stage upward; the orb, the buttons and their bottom inset stay fixed.
 */
internal val VoiceStageHeight = 366.dp
internal val StageOrbTop = 18.dp
internal val StageCaptionGap = 30.dp
internal val StageChipGap = 12.dp
/** Gap from the panel header's bottom to the orb box's top (PM0 card A3). */
internal val StageHeaderGap = 12.dp
internal val StageButtonSize = 64.dp
/** Minimum gap from the buttons' bottom to the stage bottom. */
internal val StageButtonBottom = 20.dp
/** Buttons' bottom sits at least this far above the screen bottom (iOS 54 pt): max(54 − nav bar, 20) + nav bar. */
internal val StageButtonScreenBottom = 54.dp

// Glyph boxes sized so the visible glyph matches iOS (visible iOS box ÷ the Material glyph's share of its 24 grid):
// xmark 22 bold is 17×17 pt visible, close_w700 fills 572/960 → 29; mic 25 medium is ~25.7 pt tall,
// mic_w500 fills 780/960 → 32; mic.slash is ~26.3 pt tall, mic_off_w500 fills 810/960 → 31.
internal val StageEndGlyphSize = 29.dp
internal val StageMicGlyphSize = 32.dp
internal val StageMicOffGlyphSize = 31.dp

/** Button row's bottom padding inside a stage whose bottom is [stageBottomGap] above the screen bottom. */
internal fun stageButtonBottom(stageBottomGap: Dp): Dp =
    maxOf(StageButtonScreenBottom - stageBottomGap, StageButtonBottom)
/** Caption / status column side inset (iOS: 36 pt). */
internal val StageCaptionInset = 36.dp
/** Bottom button row side inset. */
internal val StageButtonInset = 44.dp

/** Realtime failure card side inset. */
private val StageCardInset = 16.dp
private val StageChipShape = RoundedCornerShape(18.dp)
private const val STATUS_SWITCH_MS = 200
/** E-690: how long the stage shows "Switched to <model>" before the normal status line returns. */
internal const val SWITCH_NOTICE_MS = 1_600L
private const val CAPTION_MAX_LINES = 2
private const val LANGUAGE_CHIP_MAX_LINES = 3
private const val STATUS_MAX_LINES = 3
/** Caption highlight (voice-conversation.v1 constants captionBrightScalars / captionBrightWords). */
internal const val CAPTION_BRIGHT_SCALARS = 8
internal const val CAPTION_BRIGHT_WORDS = 3
private const val ELLIPSIS = "…"

/** Status → orb mode (S4 stage contract item 5): listening turns into User while the user is speaking. */
internal fun voiceOrbMode(status: ConversationStatusKey, userSpeaking: Boolean): VoiceOrbMode = when (status) {
    ConversationStatusKey.LISTENING -> if (userSpeaking) VoiceOrbMode.User else VoiceOrbMode.Listen
    ConversationStatusKey.CAPTION -> VoiceOrbMode.User
    ConversationStatusKey.THINKING -> VoiceOrbMode.Think
    ConversationStatusKey.SPEAKING, ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT -> VoiceOrbMode.Ai
    ConversationStatusKey.MUTED, ConversationStatusKey.AWAITING_APPROVAL, ConversationStatusKey.ERROR -> VoiceOrbMode.Muted
    ConversationStatusKey.SAY_AGAIN, ConversationStatusKey.CHECK_LANGUAGE -> VoiceOrbMode.Listen
}

/** The two "didn't catch that" statuses: amber words and the amber fog. */
internal fun voiceStageNotice(status: ConversationStatusKey): Boolean =
    status == ConversationStatusKey.SAY_AGAIN || status == ConversationStatusKey.CHECK_LANGUAGE

/** Stage text colors (S4 stage contract item 2). */
internal object VoiceStageColors {
    // Earlier caption words: at least 4.5:1 on the stage (same values as the status word).
    // Old text and status text sit on the aurora haze: the unconfirmed color #71717A measures only 2.9-3.9:1 here, so the secondary color is used instead (revised)
    fun captionLead(dark: Boolean): Color = if (dark) Color(0xFFB3B3BA) else Color(0xFF52525B)
    fun statusWord(dark: Boolean): Color = if (dark) Color(0xFFB3B3BA) else Color(0xFF52525B)
    fun notice(dark: Boolean): Color = if (dark) Color(0xFFFCD34D) else Color(0xFFB45309)
}

/** Han, kana or Hangul: text in these scripts is not space-separated, so its tail is counted in code points. */
private fun isCjk(codePoint: Int): Boolean = when (Character.UnicodeScript.of(codePoint)) {
    Character.UnicodeScript.HAN, Character.UnicodeScript.HIRAGANA, Character.UnicodeScript.KATAKANA,
    Character.UnicodeScript.HANGUL,
    -> true
    else -> false
}

/** Grapheme cluster start offsets of [text] (plus the end offset). */
private fun graphemeBounds(text: String): IntArray {
    val it = BreakIterator.getCharacterInstance()
    it.setText(text)
    val bounds = ArrayList<Int>()
    var b = it.first()
    while (b != BreakIterator.DONE) {
        bounds.add(b)
        b = it.next()
    }
    return bounds.toIntArray()
}

/** The caption split into the dimmed lead and the body-colored newest part. */
internal data class CaptionHighlight(val dim: String, val bright: String)

/**
 * voice-conversation.v1 captionHighlight: text with a Han / kana / Hangul character → grapheme clusters from the end
 * until their scalar count reaches [CAPTION_BRIGHT_SCALARS]; otherwise whitespace-separated words, ≤
 * [CAPTION_BRIGHT_WORDS] all bright, else bright from the [CAPTION_BRIGHT_WORDS]-th word from the end (the whitespace
 * before it stays dim). No trimming.
 */
internal fun captionHighlight(text: String): CaptionHighlight {
    if (text.codePoints().anyMatch(::isCjk)) {
        val bounds = graphemeBounds(text)
        var i = bounds.size - 1
        var scalars = 0
        while (i > 0 && scalars < CAPTION_BRIGHT_SCALARS) {
            i--
            scalars += text.codePointCount(bounds[i], bounds[i + 1])
        }
        val at = if (bounds.isEmpty()) 0 else bounds[i]
        return CaptionHighlight(text.substring(0, at), text.substring(at))
    }
    val wordStarts = ArrayList<Int>()
    var prevSpace = true
    var k = 0
    while (k < text.length) {
        val cp = text.codePointAt(k)
        val space = Character.isWhitespace(cp) || Character.isSpaceChar(cp)
        if (!space && prevSpace) wordStarts.add(k)
        prevSpace = space
        k += Character.charCount(cp)
    }
    if (wordStarts.size <= CAPTION_BRIGHT_WORDS) return CaptionHighlight("", text)
    val at = wordStarts[wordStarts.size - CAPTION_BRIGHT_WORDS]
    return CaptionHighlight(text.substring(0, at), text.substring(at))
}

/**
 * Cuts [text] from its head until [fits] accepts "…" + the rest (StartEllipsis only handles one line). Whole grapheme
 * clusters only; when not even one cluster fits, the last one is kept.
 */
internal fun headTrimmed(text: String, fits: (String) -> Boolean): String {
    if (fits(text)) return text
    val bounds = graphemeBounds(text)
    val starts = bounds.copyOfRange(0, (bounds.size - 1).coerceAtLeast(0))
    if (starts.isEmpty()) return text
    fun candidate(k: Int) = ELLIPSIS + text.substring(starts[k]).trimStart()
    var lo = 1
    var hi = starts.size
    while (lo < hi) {
        val mid = (lo + hi) / 2
        if (fits(candidate(mid))) hi = mid else lo = mid + 1
    }
    return if (lo >= starts.size) ELLIPSIS + text.substring(starts.last()) else candidate(lo)
}

/** The caption split into the dimmed lead and the body-colored tail. */
internal fun captionAnnotated(shown: String, lead: Color, tail: Color): AnnotatedString = buildAnnotatedString {
    val split = captionHighlight(shown)
    withStyle(SpanStyle(color = lead)) { append(split.dim) }
    withStyle(SpanStyle(color = tail)) { append(split.bright) }
}

/**
 * Voice stage (S4 v3, item 1–6 of the stage contract): replaces the page's input area. Aurora fog over the page
 * background (top 26 dp fades in), the 148 dp liquid orb (one button → [onTapOrb]), two lines of caption / status
 * word, the recognition language chip while [status] is check-language, and 64 dp mute (start) / end (end) buttons.
 *
 * The status word is not a live region: the host announces it once per change ([StatusAnnouncer], D-38). The orb's
 * description stays the status word while a caption is shown.
 */
@Composable
fun VoiceConversationBar(
    status: ConversationStatusKey,
    level: StateFlow<Float>?,
    page: VoiceConversationPage,
    onEnd: () -> Unit,
    onTapOrb: () -> Unit,
    onToggleMute: () -> Unit,
    modifier: Modifier = Modifier,
    /** Live caption shown instead of the status word while [status] is caption; empty = the listening word. */
    caption: String? = null,
    /** Realtime session: a non-blank [caption] replaces the status word under any status (assistant reveal / user). */
    realtimeCaption: Boolean = false,
    /** Test hook: layout of the status word / caption (truncation checks). */
    onStatusLayout: ((TextLayoutResult) -> Unit)? = null,
    /** entrance / exit driven by [VoiceConversationSwitcher]; null = shown as is. */
    motion: VoiceBarMotion? = null,
    /** The user is speaking (no caption yet): the orb follows the voice while listening. */
    userSpeaking: Boolean = false,
    /** Light-nudge counter: each change shakes the orb once. */
    nudges: Int = 0,
    /** Recognition language shown in the check-language chip, in the UI language; null = automatic. */
    languageName: String? = null,
    /** The check-language chip was tapped: open the recognition language sheet. */
    onOpenLanguage: () -> Unit = {},
    /** Test hook: the orb shook for a nudge. */
    @VisibleForTesting onOrbShake: (() -> Unit)? = null,
    /** Test hook: layout of the check-language chip label (no-truncation checks at large text sizes). */
    @VisibleForTesting onLanguageChipLayout: ((TextLayoutResult) -> Unit)? = null,
    /** Realtime failure (status error): its card, or the max_duration word, takes the caption slot. */
    failure: RealtimeFailure? = null,
    /** A failure card button was tapped. */
    onFailureAction: (RealtimeFailureAction) -> Unit = {},
    /** E-690: display name of the model the conversation is switching to; null = not switching. */
    switchingTo: String? = null,
    /** Centered above the orb (the home page's model pill, PM0 card A3); null = none. */
    header: (@Composable () -> Unit)? = null,
) {
    if (status !in VoiceConversationBarStatus.reachable(page)) {
        // Unreachable by design (see VoiceConversationBarStatus.reachable); rendered anyway, reported in debug.
        if (BuildConfig.DEBUG) {
            Log.w("VoiceConversationBar", "status ${status.rawValue} is unreachable on $page")
            VoiceConversationBarStatus.unreachableHits.incrementAndGet()
        }
    }
    val mode = voiceOrbMode(status, userSpeaking)
    val notice = voiceStageNotice(status)
    val failureCard = realtimeFailureCard(failure)
    val failureWord = realtimeFailureStatusWord(failure)
    val failureSpoken = when {
        failureCard != null -> stringResource(failureCard.title, *failureCard.titleArgs.toTypedArray())
        failureWord != null -> stringResource(failureWord)
        else -> null
    }
    VoiceStagePanel(
        mode = mode,
        level = level,
        notice = notice,
        modifier = modifier,
        motion = motion,
        leadingButton = {
            MuteButton(muted = status == ConversationStatusKey.MUTED, motion = motion, onClick = onToggleMute)
        },
        trailingButton = { EndButton(motion = motion, onClick = onEnd) },
        header = header,
    ) { buttonBottom ->
        StageOrb(
            status = status,
            caption = caption,
            realtimeCaption = realtimeCaption,
            mode = mode,
            level = level,
            nudges = nudges,
            onTap = onTapOrb,
            spokenOverride = failureSpoken,
            motion = motion,
            onShake = onOrbShake,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = StageOrbTop),
        )
        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .padding(top = StageOrbTop + VoiceAuroraOrbSize + StageCaptionGap)
                // Reserves the button row (plus the chip gap) so taller words push the stage up, not into the buttons.
                .padding(bottom = buttonBottom + StageButtonSize + StageChipGap),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Only the words keep the 36 dp side inset; the chip may span the stage width, like iOS chipButton.
            when {
                // The card spans nearly the stage width, wider than the words.
                failureCard != null -> RealtimeFailureCard(
                    model = failureCard,
                    onAction = onFailureAction,
                    modifier = Modifier.padding(horizontal = StageCardInset),
                )
                failureWord != null -> Box(Modifier.padding(horizontal = StageCaptionInset)) {
                    StatusWord(label = failureWord, notice = false, onLayout = { onStatusLayout?.invoke(it) })
                }
                else -> Box(Modifier.padding(horizontal = StageCaptionInset)) {
                    StageWords(
                        status = status,
                        caption = caption,
                        realtimeCaption = realtimeCaption,
                        onStatusLayout = onStatusLayout,
                        switchingTo = switchingTo,
                    )
                }
            }
            if (status == ConversationStatusKey.CHECK_LANGUAGE) {
                Spacer(Modifier.height(StageChipGap))
                LanguageChip(
                    name = languageName ?: stringResource(R.string.voice_language_automatic),
                    onClick = onOpenLanguage,
                    onLayout = onLanguageChipLayout,
                )
            }
        }
    }
}

/**
 * The voice stage's panel shell (S4 stage contract item 1), shared by the ≋ stage and the realtime idle dock (E-526):
 * content at least [VoiceStageHeight] tall on a transparent panel (the page backdrop shows through; the chat list fades
 * itself out above the stage, PM0 card A4), the aurora fog under everything, and the bottom button row with a
 * [leadingButton] slot on the left and a [trailingButton] slot on the right ([StageButtonInset] side inset,
 * [stageButtonBottom] above the bottom). An optional [header] sits centered on top, [StageHeaderGap] above the orb;
 * the content moves down by its height.
 */
@Composable
internal fun VoiceStagePanel(
    mode: VoiceOrbMode,
    level: StateFlow<Float>?,
    notice: Boolean,
    modifier: Modifier = Modifier,
    motion: VoiceBarMotion? = null,
    leadingButton: @Composable () -> Unit = {},
    trailingButton: @Composable () -> Unit = {},
    header: (@Composable () -> Unit)? = null,
    /** Receives the button row's bottom padding so content can reserve the row above it. */
    content: @Composable BoxScope.(buttonBottom: Dp) -> Unit,
) {
    // Stage bottom to window bottom (px), measured live: the fog anchors to the window bottom, not the stage.
    val view = LocalView.current
    val bottomGap = remember { mutableIntStateOf(0) }
    // The stage sits on the nav bar in the chat page, so the gap is the nav bar inset there; derived so a moving gap
    // (keyboard, home hero card) recomposes only when the padding itself changes.
    val density = LocalDensity.current
    val buttonBottom by remember(density) {
        derivedStateOf { stageButtonBottom(with(density) { bottomGap.intValue.toDp() }) }
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .graphicsLayer { motion?.let { alpha = it.frame().barAlpha } }
            .heightIn(min = VoiceStageHeight)
            .onGloballyPositioned {
                val gap = (view.rootView.height - (it.positionInWindow().y + it.size.height)).toInt().coerceAtLeast(0)
                if (gap != bottomGap.intValue) bottomGap.intValue = gap
            },
    ) {
        VoiceAuroraFog(
            mode = mode,
            level = level,
            notice = notice,
            modifier = Modifier.matchParentSize(),
            bottomGap = { bottomGap.intValue },
        )
        Column(Modifier.fillMaxWidth()) {
            if (header != null) {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) { header() }
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(
                        // The orb is StageOrbTop into the content: pull the content up so the gap is StageHeaderGap.
                        if (header != null) {
                            Modifier.layout { measurable, constraints ->
                                val lift = (StageOrbTop - StageHeaderGap).roundToPx()
                                val placeable = measurable.measure(constraints)
                                layout(placeable.width, placeable.height - lift) { placeable.place(0, -lift) }
                            }
                        } else {
                            Modifier
                        },
                    )
                    .heightIn(min = VoiceStageHeight),
            ) {
                content(buttonBottom)
            }
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(horizontal = StageButtonInset)
                .padding(bottom = buttonBottom),
        ) {
            Box(Modifier.align(Alignment.CenterStart)) { leadingButton() }
            Box(Modifier.align(Alignment.CenterEnd)) { trailingButton() }
        }
    }
}

/** Status-line key of the E-690 "Switched to <model>" notice. */
private data class StageSwitchNotice(val name: String)

/**
 * Caption (cascade) or status word, cross-fading 200 ms ease-in-out when switching between them or between words.
 * E-690: each new [switchingTo] shows "Switched to <model>" over both for [SWITCH_NOTICE_MS], even if the switch
 * finishes sooner.
 */
@Composable
private fun StageWords(
    status: ConversationStatusKey,
    caption: String?,
    realtimeCaption: Boolean,
    onStatusLayout: ((TextLayoutResult) -> Unit)?,
    switchingTo: String?,
) {
    var switchNotice by remember { mutableStateOf<String?>(null) }
    // Latched when the composition that saw the name is applied: the host may clear switchingTo right after the stage
    // composed it, and a LaunchedEffect cancelled before it ran would lose the notice.
    val lastSwitching = remember { arrayOfNulls<String>(1) }
    SideEffect {
        if (switchingTo != null && switchingTo != lastSwitching[0]) switchNotice = switchingTo
        lastSwitching[0] = switchingTo
    }
    // Keyed on the notice, not on switchingTo: the switch ending early does not cancel the 1.6 s.
    LaunchedEffect(switchNotice) {
        if (switchNotice != null) {
            delay(SWITCH_NOTICE_MS)
            switchNotice = null
        }
    }
    val captionText = VoiceConversationBarStatus.captionText(status, caption, realtimeCaption)
    // The leaving caption keeps its last text while it fades out.
    val lastCaption = remember { arrayOf("") }
    captionText?.let { lastCaption[0] = it }
    val wordKey: Any? = when {
        switchNotice != null -> StageSwitchNotice(switchNotice!!)
        captionText != null -> null
        else -> status
    }
    Crossfade(
        targetState = wordKey,
        animationSpec = tween(STATUS_SWITCH_MS, easing = EaseInOut),
        label = "voice-stage-words",
    ) { key ->
        val report: (TextLayoutResult) -> Unit = { if (key == wordKey) onStatusLayout?.invoke(it) }
        when (key) {
            null -> StageCaption(text = lastCaption[0], onLayout = report)
            is StageSwitchNotice -> StatusText(stringResource(R.string.voice_realtime_switched_to, key.name), false, report)
            is ConversationStatusKey -> StatusWord(VoiceConversationBarStatus.label(key), voiceStageNotice(key), report)
        }
    }
}

@Composable
internal fun StatusWord(@StringRes label: Int, notice: Boolean, onLayout: (TextLayoutResult) -> Unit) {
    StatusText(stringResource(label), notice, onLayout)
}

@Composable
private fun StatusText(text: String, notice: Boolean, onLayout: (TextLayoutResult) -> Unit) {
    val dark = OriveoTheme.isDark
    val style = OriveoTheme.typography.body.copy(
        fontSize = if (notice) 20.sp else 17.sp,
        fontWeight = if (notice) FontWeight.SemiBold else FontWeight.Medium,
        letterSpacing = if (notice) (-0.3).sp else 0.sp,
        lineHeight = 1.32.em,
        color = if (notice) VoiceStageColors.notice(dark) else VoiceStageColors.statusWord(dark),
    )
    Text(
        text = text,
        style = style,
        textAlign = TextAlign.Center,
        // Status words are never ellipsized: up to three lines at large text sizes (captions stay at two).
        maxLines = STATUS_MAX_LINES,
        overflow = TextOverflow.Clip,
        onTextLayout = onLayout,
        // Spoken on the orb node instead (StageOrb), so it is read once.
        modifier = Modifier.fillMaxWidth().clearAndSetSemantics {},
    )
}

/** Two lines at most, cut from the head with "…"; the last few code points / words in the body color. */
@Composable
private fun StageCaption(text: String, onLayout: (TextLayoutResult) -> Unit) {
    val dark = OriveoTheme.isDark
    val primary = OriveoTheme.colors.textPrimary
    val style = OriveoTheme.typography.body.copy(
        fontSize = 20.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.3).sp,
        lineHeight = 1.32.em,
        color = primary,
    )
    BoxWithConstraints(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        val measurer = rememberTextMeasurer()
        val widthPx = constraints.maxWidth
        val shown = remember(text, widthPx, style) {
            headTrimmed(text) { candidate ->
                measurer.measure(candidate, style, constraints = Constraints(maxWidth = widthPx)).lineCount <= CAPTION_MAX_LINES
            }
        }
        val annotated = remember(shown, dark, primary) { captionAnnotated(shown, VoiceStageColors.captionLead(dark), primary) }
        Text(
            text = annotated,
            style = style,
            textAlign = TextAlign.Center,
            maxLines = CAPTION_MAX_LINES,
            overflow = TextOverflow.Clip,
            onTextLayout = onLayout,
            // Spoken on the orb node instead (StageOrb), so it is read once.
            modifier = Modifier.fillMaxWidth().clearAndSetSemantics {},
        )
    }
}

/**
 * The orb as the stage's one big button: tap = interrupt / done talking. Like iOS orbButton it is the one node the
 * screen reader hears for orb + words: the live caption while there is one, else the status word (D-38, E-472).
 */
@Composable
private fun StageOrb(
    status: ConversationStatusKey,
    caption: String?,
    realtimeCaption: Boolean,
    mode: VoiceOrbMode,
    level: StateFlow<Float>?,
    nudges: Int,
    onTap: () -> Unit,
    motion: VoiceBarMotion?,
    onShake: (() -> Unit)?,
    modifier: Modifier = Modifier,
    /** Read instead of the status word (a realtime failure's copy). */
    spokenOverride: String? = null,
) {
    val word = stringResource(VoiceConversationBarStatus.label(status))
    val spoken = spokenOverride ?: VoiceConversationBarStatus.captionText(status, caption, realtimeCaption) ?: word
    val hint = VoiceConversationBarStatus.tapHint(status)?.let { stringResource(it) }
    Box(
        modifier = modifier
            .then(
                if (motion == null) {
                    Modifier
                } else {
                    // Reported outside the travel layer, so the start point doesn't move with the orb.
                    Modifier
                        .onGloballyPositioned { motion.orbCenter = it.boundsInWindow().center }
                        .graphicsLayer {
                            val offset = motion.frame().orbOffset
                            translationX = offset.x
                            translationY = offset.y
                        }
                },
            )
            .size(VoiceAuroraOrbSize)
            // No clip and no ripple: the orb's glow spills past its circle.
            .clickable(interactionSource = null, indication = null, onClick = onTap)
            .clearAndSetSemantics {
                contentDescription = spoken
                testTag = "voice_conversation_orb_button"
                role = Role.Button
                onClick(label = hint) {
                    onTap()
                    true
                }
            }
            ,
    ) {
        VoiceAuroraOrb(mode = mode, level = level, nudges = nudges, onShake = onShake)
    }
}

/**
 * The chip label with the colon glued to the word before it: a word joiner before ":" / "：", and a no-break space
 * for the spaced French " :", so a wrap never starts a line with the colon.
 */
internal fun languageChipNoBreakColon(label: String): String =
    label.replace(Regex(" ([:：])"), "\u00A0$1").replace(Regex("(?<=[^\\s\u00A0])([:：])"), "\u2060$1")

/** Check-language chip (S4 stage contract item 4): globe + "Recognition Language: X"; opens the language sheet. */
@Composable
private fun LanguageChip(name: String, onClick: () -> Unit, onLayout: ((TextLayoutResult) -> Unit)? = null) {
    val dark = OriveoTheme.isDark
    val label = stringResource(R.string.voice_conversation_language_chip, name)
    val shown = remember(label) { languageChipNoBreakColon(label) }
    val hint = stringResource(R.string.voice_conversation_language_chip_a11y_hint)
    val content = if (dark) Color(0xFFEDE9FE) else Color(0xFF6D28D9) // dark-palette-guard: keep (c) v3 voice contract fixed purple
    val fill = if (dark) Color(0xFFA78BFA).copy(alpha = 0.20f) else Color(0xFF7C4DFF).copy(alpha = 0.10f) // dark-palette-guard: keep (c) v3 voice contract fixed purple; capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
    val stroke = Color(0xFFC4B5FD).copy(alpha = 0.35f) // dark-palette-guard: keep (c) v3 voice contract fixed purple
    // The globe grows with the system text size, like the label beside it.
    val globe = 15.dp * LocalDensity.current.fontScale
    val style = OriveoTheme.typography.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold, color = content)
    val measurer = rememberTextMeasurer()
    Row(
        modifier = Modifier
            .heightIn(min = 36.dp)
            .clip(StageChipShape)
            .background(fill, StageChipShape)
            .then(if (dark) Modifier.border(0.5.dp, stroke, StageChipShape) else Modifier)
            .clickable(onClick = onClick)
            .clearAndSetSemantics {
                contentDescription = label
                testTag = "voice_conversation_language_chip"
                role = Role.Button
                onClick(label = hint) {
                    onClick()
                    true
                }
            }
            
            .padding(start = 12.dp, end = 14.dp, top = 6.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painter = painterResource(VoiceGlyphs.language), contentDescription = null, tint = content, modifier = Modifier.size(globe))
        Text(
            text = shown,
            style = style,
            // Like iOS chipLabel: each wrapped line centered, up to three lines, never ellipsized (the longest
            // language name stays whole at 200 % text size).
            textAlign = TextAlign.Center,
            maxLines = LANGUAGE_CHIP_MAX_LINES,
            overflow = TextOverflow.Clip,
            onTextLayout = { onLayout?.invoke(it) },
            modifier = Modifier.layout { measurable, constraints ->
                // Width by content, like a wrapped SwiftUI Text: shrink to the widest line, so a wrapped chip stays
                // narrower than the stage (E-473). Every line fits that width, so the line breaks don't change.
                val probe = measurer.measure(
                    shown,
                    style,
                    maxLines = LANGUAGE_CHIP_MAX_LINES,
                    constraints = Constraints(maxWidth = constraints.maxWidth),
                )
                val widest = (0 until probe.lineCount).maxOfOrNull { probe.getLineRight(it) - probe.getLineLeft(it) } ?: 0f
                val width = ceil(widest).toInt().coerceIn(constraints.minWidth, constraints.maxWidth)
                val placeable = measurable.measure(constraints.copy(minWidth = width, maxWidth = width))
                layout(placeable.width, placeable.height) { placeable.place(0, 0) }
            },
        )
    }
}

/** Mute (S4 stage contract item 3): frosted circle with a violet mic; solid violet with mic-off while muted; top inner highlight. */
@Composable
private fun MuteButton(muted: Boolean, motion: VoiceBarMotion?, onClick: () -> Unit) {
    val dark = OriveoTheme.isDark
    val brand = stageButtonBrand(dark)
    val fill = if (muted) Modifier.background(brand, CircleShape) else stageGlassFill(dark)
    // Top inner highlight in both states, same as the end button.
    val decoration = fill.innerShadow(
        shape = CircleShape,
        shadow = Shadow(radius = 1.dp, color = Color.White.copy(alpha = 0.32f), offset = DpOffset(0.dp, 1.dp)),
    )
    val tint = when {
        muted -> if (dark) Color(0xFF18181B) else Color.White
        else -> brand
    }
    StageCircleButton(
        label = stringResource(if (muted) R.string.voice_conversation_unmute_a11y else R.string.voice_conversation_mute_a11y),
        tag = "voice_conversation_mute_button",
        decoration = decoration,
        motion = motion,
        onClick = onClick,
    ) {
        Icon(
            painter = painterResource(if (muted) VoiceGlyphs.micOff else VoiceGlyphs.mic),
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(if (muted) StageMicOffGlyphSize else StageMicGlyphSize),
        )
    }
}

/** Brand purple of the stage's glass buttons (mute icon, keyboard icon, muted fill). */
internal fun stageButtonBrand(dark: Boolean): Color =
    if (dark) Color(0xFFC4B5FD) else Color(0xFF7C4DFF) // dark-palette-guard: keep (c) v3 voice contract fixed purple

/** Glass fill of an unselected stage button (mute off, the idle dock's keyboard button), without the top highlight. */
internal fun stageGlassFill(dark: Boolean): Modifier = if (dark) {
    Modifier
        .background(Color.White.copy(alpha = 0.10f), CircleShape)
        .border(0.5.dp, Color.White.copy(alpha = 0.10f), CircleShape)
} else {
    Modifier
        .dropShadow(
            shape = CircleShape,
            shadow = Shadow(radius = 24.dp, color = Color(0xFF5B21B6).copy(alpha = 0.14f), offset = DpOffset(0.dp, 10.dp)),
        )
        .background(Color.White.copy(alpha = 0.78f), CircleShape)
        .border(0.5.dp, Color(0xFF7C3AED).copy(alpha = 0.16f), CircleShape) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
}

/** Top inner highlight shared by every stage button. */
internal fun Modifier.stageButtonHighlight(): Modifier = innerShadow(
    shape = CircleShape,
    shadow = Shadow(radius = 1.dp, color = Color.White.copy(alpha = 0.32f), offset = DpOffset(0.dp, 1.dp)),
)

/** End (S4 stage contract item 3): red vertical gradient, top inner highlight, red shadow, white ✕. */
@Composable
private fun EndButton(motion: VoiceBarMotion?, onClick: () -> Unit) {
    val dark = OriveoTheme.isDark
    val decoration = Modifier
        .dropShadow(
            shape = CircleShape,
            shadow = Shadow(
                radius = 24.dp,
                color = Color(0xFFE8382F).copy(alpha = if (dark) 0.42f else 0.30f),
                offset = DpOffset(0.dp, 10.dp),
            ),
        )
        .background(Brush.verticalGradient(listOf(Color(0xFFFF5A52), Color(0xFFE8382F))), CircleShape)
        .innerShadow(
            shape = CircleShape,
            shadow = Shadow(radius = 1.dp, color = Color.White.copy(alpha = 0.32f), offset = DpOffset(0.dp, 1.dp)),
        )
    StageCircleButton(
        label = stringResource(R.string.voice_conversation_end_a11y),
        tag = "voice_conversation_end_button",
        decoration = decoration,
        motion = motion,
        onClick = onClick,
    ) {
        Icon(
            painter = painterResource(VoiceGlyphs.closeStage),
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(StageEndGlyphSize),
        )
    }
}

/** 64 dp circle (= touch target) that scales 0.6 → 1 with the stage's entrance. */
@Composable
internal fun StageCircleButton(
    label: String,
    tag: String,
    decoration: Modifier,
    motion: VoiceBarMotion?,
    onClick: () -> Unit,
    icon: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .graphicsLayer {
                motion?.let {
                    val scale = it.frame().sideScale
                    scaleX = scale
                    scaleY = scale
                }
            }
            .size(StageButtonSize)
            .then(decoration)
            .clip(CircleShape)
            .semantics { contentDescription = label }
            
            .testTag(tag)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { icon() }
}

/** Status word announcement hook for the bar's host (D-38); see [StatusAnnouncer]. */
@Composable
fun AnnounceVoiceStatus(
    status: ConversationStatusKey?,
    announcer: StatusAnnouncer,
    failure: RealtimeFailure? = null,
    switchingTo: String? = null,
) {
    val text = voiceStatusAnnouncement(status, failure)?.let { (res, args) -> stringResource(res, *args.toTypedArray()) }
    // E-690: "Switched to <model>" is spoken once; the status word waits until the switch is over.
    val switched = switchingTo?.let { stringResource(R.string.voice_realtime_switched_to, it) }
    LaunchedEffect(text, switched) {
        when {
            switched != null -> announcer.announce(switched)
            text != null -> announcer.announce(text)
        }
    }
}
