package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind

/**
 * Pure functions for the realtime voice model: failure classification, picker realtime rows, capability projection,
 * legacy-user migration, and lifecycle rules. Cases are aligned one-to-one with shared/voice-contracts/realtime-model.v1.json.
 * No IO and no clock; copy keys stay as String, and the UI layer maps them to R.string.
 */
object RealtimeModel {

    const val CONNECT_TIMEOUT_MS = 10_000L
    const val UPLINK_BACKLOG_MS = 8_000L
    /** Automatic reopen attempts with history after an unexpected drop (Gemini reconnects through its existing handle instead, up to 4 times). */
    const val AUTO_REOPEN_ATTEMPTS = 1
    const val GEMINI_HANDLE_RECONNECTS = 4

    // The six category names match the failure categories of the realtime conversation module.
    const val CATEGORY_AUTH = "auth"
    const val CATEGORY_QUOTA = "quota"
    const val CATEGORY_MODEL_GONE = "model_gone"
    const val CATEGORY_MAX_DURATION = "max_duration"
    const val CATEGORY_NETWORK = "network"
    const val CATEGORY_UNKNOWN = "unknown"
    val CATEGORIES: List<String> = listOf(
        CATEGORY_AUTH, CATEGORY_QUOTA, CATEGORY_MODEL_GONE, CATEGORY_MAX_DURATION, CATEGORY_NETWORK, CATEGORY_UNKNOWN,
    )

    const val ACTION_OPEN_CONNECTION = "openConnection"
    const val ACTION_RETRY = "retry"
    const val ACTION_SWITCH_MODEL = "switchModel"
    const val ACTION_CONTINUE_WITH_HISTORY = "continueWithHistory"

    val ACTIONS: Map<String, List<String>> = mapOf(
        CATEGORY_AUTH to listOf(ACTION_OPEN_CONNECTION),
        CATEGORY_QUOTA to listOf(ACTION_RETRY, ACTION_SWITCH_MODEL),
        CATEGORY_MODEL_GONE to listOf(ACTION_SWITCH_MODEL),
        CATEGORY_MAX_DURATION to listOf(ACTION_CONTINUE_WITH_HISTORY),
        CATEGORY_NETWORK to listOf(ACTION_RETRY),
        CATEGORY_UNKNOWN to listOf(ACTION_RETRY, ACTION_SWITCH_MODEL),
    )

    /** Fixture copy.failure: category name -> copy key */
    val COPY_FAILURE: Map<String, String> = CATEGORIES.associateWith { "voice_realtime_failure_$it" }

    /** Fixture copy.actions: exit -> button copy key; continueWithHistory is the tap-the-orb action itself, so it has no button text */
    val COPY_ACTIONS: Map<String, String?> = mapOf(
        ACTION_OPEN_CONNECTION to "voice_realtime_action_open_connection",
        ACTION_RETRY to "voice_realtime_action_retry",
        ACTION_SWITCH_MODEL to "voice_realtime_action_switch_model",
        ACTION_CONTINUE_WITH_HISTORY to null,
    )

    /** Fixture copy.failureArg: provider = provider display name, model = catalog model, none = no placeholder */
    val COPY_FAILURE_ARG: Map<String, String> = mapOf(
        CATEGORY_AUTH to "provider",
        CATEGORY_QUOTA to "provider",
        CATEGORY_MODEL_GONE to "model",
        CATEGORY_MAX_DURATION to "none",
        CATEGORY_NETWORK to "model",
        CATEGORY_UNKNOWN to "model",
    )

    const val COPY_NO_ATTACHMENTS = "voice_realtime_no_attachments"
    const val COPY_NO_WEB_SEARCH = "voice_realtime_no_web_search"
    const val COPY_NO_THINKING = "voice_realtime_no_thinking"
    const val COPY_NO_TOOLS = "voice_realtime_no_tools"
    val COPY_CAPABILITY: List<String> = listOf(COPY_NO_ATTACHMENTS, COPY_NO_WEB_SEARCH, COPY_NO_THINKING, COPY_NO_TOOLS)

    const val COPY_MODEL_TAG = "voice_realtime_model_tag"
    const val COPY_MODEL_SUBTITLE = "voice_realtime_model_subtitle"
    const val COPY_FILTER_COUNT = "voice_realtime_filter_count"
    val COPY_PICKER: List<String> = listOf(COPY_MODEL_TAG, COPY_MODEL_SUBTITLE, COPY_FILTER_COUNT)

    const val COPY_MOVED_TITLE = "voice_realtime_moved_title"
    const val COPY_MOVED_SWITCH = "voice_realtime_moved_switch"
    const val COPY_MOVED_KEEP = "voice_realtime_moved_keep"
    val COPY_MIGRATION: List<String> = listOf(COPY_MOVED_TITLE, COPY_MOVED_SWITCH, COPY_MOVED_KEEP)

    const val COPY_BACK_TO_STAGE = "voice_realtime_back_to_stage"
    const val COPY_TAP_TO_START = "voice_realtime_tap_to_start"
    const val COPY_SWITCH_TO_KEYBOARD = "voice_realtime_switch_to_keyboard"
    const val COPY_SWITCHED_TO = "voice_realtime_switched_to"
    const val COPY_MODEL_LOADING = "voice_realtime_model_loading"
    val COPY_COMPOSER: List<String> =
        listOf(COPY_BACK_TO_STAGE, COPY_TAP_TO_START, COPY_SWITCH_TO_KEYBOARD, COPY_SWITCHED_TO, COPY_MODEL_LOADING)

    const val COPY_DISCLOSURE_TITLE = "voice_realtime_disclosure_title"
    const val COPY_DISCLOSURE_BODY = "voice_realtime_disclosure_body"
    val COPY_DISCLOSURE: List<String> = listOf(COPY_DISCLOSURE_TITLE, COPY_DISCLOSURE_BODY)

    // ---- Failure classification ----

    /** Normalized signals the host collects on connection failure or unexpected session end (fields: fixture rules.failure) */
    data class FailureSignal(
        val httpStatus: Int? = null,
        val errorCode: String? = null,
        val catalogHasModel: Boolean? = null,
        val endedReason: String? = null,
        val elapsedSec: Double? = null,
        val maxSessionSec: Double? = null,
        val connectError: Boolean? = null,
        val connectTimedOut: Boolean? = null,
        val reopenFailed: Boolean? = null,
        val uplinkBacklogMs: Double? = null,
        val closeCode: Int? = null,
    )

    data class FailureResult(
        val category: String,
        val copyKey: String,
        val copyArg: String,
        val actions: List<String>,
        val actionCopyKeys: List<String?>,
    )

    /** First match wins, checked in the order auth -> quota -> model_gone -> max_duration -> network -> unknown */
    fun classifyFailure(signal: FailureSignal = FailureSignal()): FailureResult {
        val http = signal.httpStatus
        val code = signal.errorCode
        val category = when {
            http == 401 || http == 403 || code == "invalid_api_key" -> CATEGORY_AUTH
            http == 429 || code == "insufficient_quota" || code == "rate_limit_exceeded" -> CATEGORY_QUOTA
            (signal.reopenFailed != true && (http == 404 || code == "model_not_found")) ||
                signal.catalogHasModel == false -> CATEGORY_MODEL_GONE
            signal.endedReason == "max_duration" || signal.endedReason == "timeout" ||
                (signal.maxSessionSec != null && signal.elapsedSec != null && signal.elapsedSec >= signal.maxSessionSec) ->
                CATEGORY_MAX_DURATION
            signal.connectError == true || signal.connectTimedOut == true || signal.reopenFailed == true ||
                (signal.uplinkBacklogMs != null && signal.uplinkBacklogMs > UPLINK_BACKLOG_MS) -> CATEGORY_NETWORK
            else -> CATEGORY_UNKNOWN
        }
        val actions = ACTIONS.getValue(category)
        return FailureResult(
            category = category,
            copyKey = COPY_FAILURE.getValue(category),
            copyArg = COPY_FAILURE_ARG.getValue(category),
            actions = actions,
            actionCopyKeys = actions.map { COPY_ACTIONS[it] },
        )
    }

    // ---- Picker realtime rows ----

    const val CONTEXT_CHAT = "chat"
    const val CONTEXT_HOME = "home"
    const val CONTEXT_CROSSCHECK = "crosscheck"

    const val FILTER_REALTIME = "realtime"
    const val FILTER_WEB_SEARCH = "webSearch"
    const val FILTER_THINKING = "thinking"

    const val ROW_KIND_TEXT = "text"
    const val ROW_KIND_REALTIME = "realtime"

    const val AUTH_API_KEY = "apiKey"

    data class TextModel(val model: String, val webSearch: Boolean = false, val thinking: Boolean = false)

    data class RealtimeCatalogEntry(val model: String, val isDefault: Boolean = false)

    /** auth: fixture semantics, "apiKey" = official direct apiKey connection; the production side maps it with [connectionAuth] */
    data class Connection(
        val id: String,
        val providerKind: String,
        val auth: String,
        val textModels: List<TextModel> = emptyList(),
    )

    data class PickerRow(val model: String, val kind: String)

    data class PickerGroup(val connectionId: String, val rows: List<PickerRow>)

    /** Picker selection (connectionId + model); which row it lands on is resolved at read time by [pickerRows] */
    data class Selected(val connectionId: String, val model: String)

    data class SelectedRow(val connectionId: String, val model: String, val kind: String)

    /** selectedRow: which listed row the selection lands on (same connection and model; text rows match first); null when not in the list */
    data class PickerResult(
        val showsRealtimeFilter: Boolean,
        val groups: List<PickerGroup>,
        val selectedRow: SelectedRow? = null,
    )

    /** Production mapping: a direct official connection (not Relay or a hosted provider) that authenticates with apiKey -> "apiKey", otherwise "other" */
    fun connectionAuth(kind: ProviderKind, authMode: ProviderAuthMode): String =
        if (kind != ProviderKind.Relay &&
            authMode == ProviderAuthMode.ApiKey
        ) AUTH_API_KEY else "other"

    /**
     * Source = catalog realtime[] x official apiKey connections; only in chat / home, never in crosscheck.
     * Rows come after the connection's text models; isDefault first, the rest in catalog order. The "realtime" filter intersects with webSearch / thinking;
     * groups left empty after filtering are removed entirely.
     */
    fun pickerRows(
        context: String,
        filters: List<String> = emptyList(),
        connections: List<Connection> = emptyList(),
        realtimeCatalog: Map<String, List<RealtimeCatalogEntry>> = emptyMap(),
        selected: Selected? = null,
    ): PickerResult {
        fun realtimeOf(conn: Connection): List<PickerRow> {
            if (context == CONTEXT_CROSSCHECK || conn.auth != AUTH_API_KEY) return emptyList()
            val list = realtimeCatalog[conn.providerKind].orEmpty()
            return (list.filter { it.isDefault } + list.filter { !it.isDefault })
                .map { PickerRow(it.model, ROW_KIND_REALTIME) }
        }
        val showsRealtimeFilter = connections.any { realtimeOf(it).isNotEmpty() }
        val active = filters.filter { it != FILTER_REALTIME || showsRealtimeFilter }
        val textMatches = { m: TextModel ->
            active.all {
                when (it) {
                    FILTER_WEB_SEARCH -> m.webSearch
                    FILTER_THINKING -> m.thinking
                    else -> false
                }
            }
        }
        val realtimeMatches = active.all { it == FILTER_REALTIME }
        val groups = connections.mapNotNull { conn ->
            val rows = conn.textModels.filter(textMatches).map { PickerRow(it.model, ROW_KIND_TEXT) } +
                (if (realtimeMatches) realtimeOf(conn) else emptyList())
            if (rows.isEmpty()) null else PickerGroup(conn.id, rows)
        }
        val hit = selected?.let { sel ->
            groups.firstOrNull { it.connectionId == sel.connectionId }?.rows?.firstOrNull { it.model == sel.model }
        }
        val selectedRow = hit?.let { SelectedRow(selected.connectionId, it.model, it.kind) }
        return PickerResult(showsRealtimeFilter, groups, selectedRow)
    }

    // ---- Capability projection ----

    const val MODEL_KIND_TEXT = "text"
    const val MODEL_KIND_REALTIME = "realtime"
    /** stage = voice stage, typing = typing mode (the same realtime model) */
    const val MODE_STAGE = "stage"
    const val MODE_TYPING = "typing"

    data class Capability(
        val attachments: String,
        val attachmentsReasonKey: String?,
        val webSearch: String,
        val webSearchReasonKey: String?,
        val thinking: String,
        val thinkingReasonKey: String?,
        val tools: String,
        val toolsReasonKey: String?,
        val sendsTools: Boolean,
        val regenerateEdit: String,
        val setAsDefault: String,
        val writesLastUsedModel: Boolean,
        val dictation: String,
        val voiceEntry: String,
        /** Model options panel: vision and file tiles and the capability summary; hidden for realtime, only the web search and thinking rows remain */
        val visionTile: String,
        val fileTile: String,
        val panelSummary: String,
    )

    fun capability(modelKind: String, mode: String): Capability {
        if (modelKind != MODEL_KIND_REALTIME) {
            return Capability(
                attachments = "default", attachmentsReasonKey = null,
                webSearch = "default", webSearchReasonKey = null,
                thinking = "default", thinkingReasonKey = null,
                tools = "default", toolsReasonKey = null,
                sendsTools = true,
                regenerateEdit = "default", setAsDefault = "default",
                writesLastUsedModel = true, dictation = "available", voiceEntry = "cascade",
                visionTile = "default", fileTile = "default", panelSummary = "default",
            )
        }
        val typing = mode == MODE_TYPING
        return Capability(
            attachments = if (typing) "disabledWithReason" else "hidden",
            attachmentsReasonKey = if (typing) COPY_NO_ATTACHMENTS else null,
            webSearch = "statusLine", webSearchReasonKey = COPY_NO_WEB_SEARCH,
            thinking = "statusLine", thinkingReasonKey = COPY_NO_THINKING,
            tools = if (typing) "disabledTappable" else "hidden",
            toolsReasonKey = if (typing) COPY_NO_TOOLS else null,
            sendsTools = false,
            regenerateEdit = "hidden",
            setAsDefault = "notOffered",
            writesLastUsedModel = false,
            dictation = if (typing) "available" else "hidden",
            voiceEntry = if (typing) "backToStage" else "stage",
            // Model options panel: only the web search and thinking status rows remain; vision, file tiles and the capability summary do not appear
            visionTile = "hidden", fileTile = "hidden", panelSummary = "hidden",
        )
    }

    // ---- Legacy-user migration ----

    const val ANSWER_SWITCH = "switch"
    const val ANSWER_KEEP = "keep"
    /** Interrupted by the system before an answer */
    const val ANSWER_DISMISSED = "dismissed"

    const val MIGRATION_ENTER_CASCADE = "enterCascade"
    const val MIGRATION_SELECT_REALTIME = "selectRealtime"
    const val MIGRATION_NONE = "none"

    data class OldChoice(val providerKind: String, val model: String, val connectionId: String)

    data class MigrationResult(
        val showPrompt: Boolean,
        val result: String,
        val deleteOldKeys: Boolean,
        val showDisclosure: Boolean,
    )

    /**
     * Called the first time the user taps ≋ after the upgrade. answer: switch / keep / dismissed / null (prompt not shown yet).
     * disclosureDeclined: the disclosure shown after switch was declined (no switch; still enter ≋ as usual; old keys are still deleted).
     */
    fun migration(
        oldKeyPresent: Boolean,
        oldChoice: OldChoice? = null,
        realtimeCatalog: Map<String, List<RealtimeCatalogEntry>> = emptyMap(),
        connections: List<Connection> = emptyList(),
        consented: Boolean = false,
        answer: String? = null,
        disclosureDeclined: Boolean = false,
    ): MigrationResult {
        val none = MigrationResult(showPrompt = false, result = MIGRATION_ENTER_CASCADE, deleteOldKeys = false, showDisclosure = false)
        if (!oldKeyPresent) return none
        val conn = oldChoice?.let { choice -> connections.firstOrNull { it.id == choice.connectionId } }
        val resolvable = oldChoice != null && conn != null &&
            conn.providerKind == oldChoice.providerKind && conn.auth == AUTH_API_KEY &&
            realtimeCatalog[oldChoice.providerKind].orEmpty().any { it.model == oldChoice.model }
        if (!resolvable) return none.copy(deleteOldKeys = true)
        return when (answer) {
            ANSWER_SWITCH -> {
                val showDisclosure = !consented
                MigrationResult(
                    showPrompt = true,
                    result = if (showDisclosure && disclosureDeclined) MIGRATION_ENTER_CASCADE else MIGRATION_SELECT_REALTIME,
                    deleteOldKeys = true,
                    showDisclosure = showDisclosure,
                )
            }
            ANSWER_KEEP -> MigrationResult(showPrompt = true, result = MIGRATION_ENTER_CASCADE, deleteOldKeys = true, showDisclosure = false)
            else -> MigrationResult(showPrompt = true, result = MIGRATION_NONE, deleteOldKeys = false, showDisclosure = false)
        }
    }

    // ---- Lifecycle: going to background or locking the screen keeps the session; an incoming call, Siri, or permanent audio focus loss ends it (reason system) ----

    const val LIFECYCLE_CONTINUE = "continue"
    const val LIFECYCLE_END = "end"
    const val REDUCER_SYSTEM_INTERRUPTION = "systemInterruption"

    data class LifecycleResult(val action: String, val reducerInput: String?)

    private val ENDS = setOf("phoneCall", "siri", "audioFocusLossPermanent")
    private val CONTINUES = setOf("enterBackground", "screenLock", "returnForeground")

    fun lifecycle(event: String): LifecycleResult = when (event) {
        in ENDS -> LifecycleResult(LIFECYCLE_END, REDUCER_SYSTEM_INTERRUPTION)
        in CONTINUES -> LifecycleResult(LIFECYCLE_CONTINUE, null)
        else -> throw IllegalArgumentException("unknown lifecycle event $event")
    }

    const val DROP_STAGE_DROP = "drop"
    const val DROP_STAGE_REOPEN_FAILED = "reopenFailed"
    const val AFTER_DROP_END = "end"
    const val AFTER_DROP_REOPEN = "reopen"
    const val AFTER_DROP_DORMANT = "dormant"
    const val AFTER_DROP_HANDLE_RECONNECT = "handleReconnect"
    private const val PROVIDER_GEMINI = "gemini"

    /** What an unexpected drop leads to; [refetchCatalog] is always false (the catalog is only refetched for a call that never reached Ready). */
    data class AfterDropResult(val action: String, val code: String?, val refetchCatalog: Boolean)

    // Where a drop goes: a failed reopen handshake is classified as network; Gemini reconnects its handle; any category other than network / unknown ends with that category;
    // a drop again after a reopen with no progress is unknown; a drop while muted goes dormant; otherwise reopen with history. No branch refetches the catalog.
    fun afterDrop(
        stage: String = DROP_STAGE_DROP,
        provider: String,
        category: String = CATEGORY_UNKNOWN,
        muted: Boolean = false,
        reopenedWithoutProgress: Boolean = false,
    ): AfterDropResult = when {
        stage == DROP_STAGE_REOPEN_FAILED -> AfterDropResult(AFTER_DROP_END, CATEGORY_NETWORK, false)
        provider == PROVIDER_GEMINI -> AfterDropResult(AFTER_DROP_HANDLE_RECONNECT, null, false)
        category != CATEGORY_NETWORK && category != CATEGORY_UNKNOWN -> AfterDropResult(AFTER_DROP_END, category, false)
        reopenedWithoutProgress -> AfterDropResult(AFTER_DROP_END, CATEGORY_UNKNOWN, false)
        muted -> AfterDropResult(AFTER_DROP_DORMANT, null, false)
        else -> AfterDropResult(AFTER_DROP_REOPEN, null, false)
    }

    const val BACK_TO_STAGE_SESSION_NONE = "none"
    const val BACK_TO_STAGE_SESSION_TYPING_OPENED = "typingOpened"
    const val BACK_TO_STAGE_SESSION_CAPTURING = "capturing"
    const val BACK_TO_STAGE_RESUME_CAPTURE = "resumeCapture"
    const val BACK_TO_STAGE_IDLE_STAGE = "idleStage"
    const val BACK_TO_STAGE_NONE = "none"

    /** What tapping the back-to-stage orb does; [interruptsPlayback] = the reply being played is cut first (same as tapping the orb). */
    data class BackToStageResult(val action: String, val interruptsPlayback: Boolean)

    // Back to stage: a typing-opened session is running -> resume capture on the same connection, interrupting the AI first if it is speaking; already capturing -> no-op; no session -> idle stage.
    fun backToStage(session: String, assistantSpeaking: Boolean = false): BackToStageResult = when (session) {
        BACK_TO_STAGE_SESSION_TYPING_OPENED -> BackToStageResult(BACK_TO_STAGE_RESUME_CAPTURE, assistantSpeaking)
        BACK_TO_STAGE_SESSION_CAPTURING -> BackToStageResult(BACK_TO_STAGE_NONE, false)
        BACK_TO_STAGE_SESSION_NONE -> BackToStageResult(BACK_TO_STAGE_IDLE_STAGE, false)
        else -> throw IllegalArgumentException("unknown back-to-stage session $session")
    }

    const val TYPED_CONTEXT_HOME = "home"
    const val TYPED_CONTEXT_CHAT = "chat"
    const val TYPED_PERSISTED = "persisted"
    const val TYPED_ENDED_BEFORE_PERSIST = "endedBeforePersist"
    const val TYPED_OPEN_FAILED = "openFailed"
    const val TYPED_DISCLOSURE_DECLINED = "disclosureDeclined"
    const val TYPED_HOST_LEFT = "hostLeft"

    data class TypedSendOutcome(val inputKeepsText: Boolean, val conversationCreated: Boolean)

    // When a sentence sent from realtime typing settles: the input is cleared only once that user sentence is persisted; the home screen also creates the conversation. Any other outcome keeps the text in the input.
    fun typedSendOutcome(context: String, outcome: String): TypedSendOutcome {
        val persisted = outcome == TYPED_PERSISTED
        return TypedSendOutcome(inputKeepsText = !persisted, conversationCreated = context == TYPED_CONTEXT_HOME && persisted)
    }
}
