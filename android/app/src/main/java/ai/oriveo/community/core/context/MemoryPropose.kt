package ai.oriveo.community.core.context

import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolLoopToolFunction
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** memory-propose.v3 skip reasons (fixture `skipReasons`). */
enum class MemoryProposeSkipReason(val wire: String) {
    INVALID_ARGUMENTS("invalid_arguments"),
    TOO_LONG("too_long"),
    QUOTE_NOT_IN_MESSAGE("quote_not_in_message"),
    SECRET("secret"),
    SPECIAL("special"),
    CONVERSATION_INSTRUCTION("conversation_instruction"),
    CONVERSATION_NOT_INSTRUCTION("conversation_not_instruction"),
    INSTRUCT_LIMIT("instruct_limit"),
    TURN_LIMIT("turn_limit"),
    DUPLICATE_ACTIVE("duplicate_active"),
    EXISTS("exists"),
    DUPLICATE_PENDING("duplicate_pending"),
    REJECTED_RECENTLY("rejected_recently"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryProposeSkipReason? = entries.firstOrNull { it.wire == wire }
    }
}

/** memory-propose.v3 modes (fixture `modes`). */
enum class MemoryProposeMode(val wire: String) {
    TOOL("tool"),
    FALLBACK("fallback"),
    NONE("none"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryProposeMode? = entries.firstOrNull { it.wire == wire }
    }
}

/** Request purpose seen by the mode decision; only CHAT can carry propose_memory. */
enum class MemoryProposePurpose(val wire: String) {
    CHAT("chat"),
    COMPACTION("compaction"),
    CONTINUE("continue"),
    TOOL_LOOP_LEG("toolLoopLeg"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryProposePurpose? = entries.firstOrNull { it.wire == wire }
    }
}

/** Inputs of memory-propose.v3 rule 1; [connectionSupportsTools] is the MCP tool predicate plus the Moonshot $web_search check. */
data class MemoryProposeModeInput(
    val purpose: MemoryProposePurpose,
    val freshSend: Boolean,
    val memoryEnabled: Boolean,
    val autoSuggest: Boolean,
    val connectionSupportsTools: Boolean,
    val degraded: Boolean,
)

data class MemoryProposeContext(
    val conversationId: String,
    val folderId: String?,
    val messageId: String,
    val nowMs: Long,
    val activeContents: List<String>,
    val records: List<MemoryCandidate>,
    /** Text of this turn's fresh user message. */
    val userText: String,
)

/** Outcome of one propose_memory call: memory-intent create / skip, or v3 instruct (conversation-instruction bar). */
enum class MemoryProposeAction(val wire: String) {
    CREATE("create"),
    SKIP("skip"),
    INSTRUCT("instruct"),
}

data class MemoryProposeDecision(
    val action: MemoryProposeAction,
    val reason: MemoryProposeSkipReason?,
    val candidate: MemoryCandidate?,
    /** Instruct only: sourceQuote trimmed by White_Space, offered to the conversation-instruction bar. */
    val sentence: String? = null,
)

/** Host tool propose_memory (memory-propose.v3 rules 1, 4, 6). */
object MemoryPropose {

    const val TOOL_NAME = "propose_memory"

    const val MAX_PROPOSALS_PER_TURN = 3

    const val MAX_INSTRUCT_PER_TURN = 1

    /** Answer to every propose_memory call, whatever the outcome (rule 3). */
    const val TOOL_RESULT = "Recorded as a suggestion; the user will decide whether to save it. Continue your reply. Do not ask about it or say it was saved."

    /** Kinds the tool accepts (memory-intent.v1 `kinds` plus memory-propose.v3 `episodicKinds`). */
    val KINDS: List<MemoryKind> = listOf(
        MemoryKind.INSTRUCTION,
        MemoryKind.PROJECT,
        MemoryKind.GOAL,
        MemoryKind.PREFERENCE,
        MemoryKind.IDENTITY,
        MemoryKind.FACT,
        MemoryKind.DECISION,
        MemoryKind.EVENT,
    )

    /** Kinds whose candidates and accepted items go to L3 (memory-propose.v3 `episodicKinds`). */
    val EPISODIC_KINDS: Set<MemoryKind> = setOf(MemoryKind.DECISION, MemoryKind.EVENT)

    /** Layer for a candidate or an accepted item of [kind]: episodic for decision / event, semantic otherwise. */
    fun layerFor(kind: MemoryKind): MemoryLayer = if (kind in EPISODIC_KINDS) MemoryLayer.EPISODIC else MemoryLayer.SEMANTIC

    /** Scopes the tool accepts (fixture `scopes`). */
    val SCOPES: List<MemoryIntentScope> = listOf(
        MemoryIntentScope.GLOBAL,
        MemoryIntentScope.FOLDER,
        MemoryIntentScope.UNSPECIFIED,
        MemoryIntentScope.CONVERSATION,
    )

    /** Fixture `tool`, key order kept so the serialized form matches byte-for-byte. */
    val TOOL_JSON: JsonObject = Json.parseToJsonElement(
        """
        {
          "type": "function",
          "function": {
            "name": "propose_memory",
            "description": "Propose one long-term memory for the user to confirm, or one standing instruction for this conversation. Call it when the user's own message in this turn asks you to remember something for future conversations, or states a lasting fact or preference about themselves, or a decision or event they will want to look up later, that they clearly want kept beyond this conversation. Also call it when the user asks you to keep answering in a certain way for the rest of this conversation (from now on, going forward, always, never, every time...): set scope to conversation and kind to instruction. One atomic statement per call, keeping the user's meaning and language; never record your own inference. Do not call it for: reminders and to-dos; questions, including 'can you remember...'; corrections or statements that something is no longer true; quoted, hypothetical or role-play text; anything containing passwords, keys, codes, payment or ID details, health, sexuality, religion, politics, ethnicity, criminal record or immigration status. Nothing is saved until the user confirms. After calling, continue your reply normally and do not mention the proposal.",
            "parameters": {
              "type": "object",
              "properties": {
                "proposition": {
                  "type": "string",
                  "description": "The fact, preference or rule to keep, as one self-contained statement in the language the user wrote."
                },
                "kind": {
                  "type": "string",
                  "enum": [
                    "instruction",
                    "project",
                    "goal",
                    "preference",
                    "identity",
                    "fact",
                    "decision",
                    "event"
                  ],
                  "description": "instruction: a standing rule for how to respond; project: about a project the user works on; goal: something the user is working toward; preference: what the user likes or dislikes; identity: who the user is; fact: any other lasting fact about the user; decision: something the user decided and will want to look up later; event: something that happened that the user will want to look up later."
                },
                "scope": {
                  "type": "string",
                  "enum": [
                    "global",
                    "folder",
                    "unspecified",
                    "conversation"
                  ],
                  "description": "global: the user said it applies to all chats; folder: the user said it applies to this project or folder; unspecified: the user named no scope; conversation: a way of answering the user wants kept for the rest of this conversation only (use kind instruction)."
                },
                "sourceQuote": {
                  "type": "string",
                  "description": "The exact words in the user's message that this comes from, copied verbatim."
                }
              },
              "required": [
                "proposition",
                "kind",
                "scope",
                "sourceQuote"
              ],
              "additionalProperties": false
            }
          }
        }
        """,
    ).jsonObject

    val tool: ToolLoopToolDefinition = TOOL_JSON["function"]!!.jsonObject.let { fn ->
        ToolLoopToolDefinition(
            function = ToolLoopToolFunction(
                name = fn["name"]!!.jsonPrimitive.content,
                description = fn["description"]!!.jsonPrimitive.content,
                parameters = fn["parameters"]!!.jsonObject,
            ),
        )
    }

    fun mode(input: MemoryProposeModeInput): MemoryProposeMode = when {
        input.purpose != MemoryProposePurpose.CHAT || !input.freshSend -> MemoryProposeMode.NONE
        !input.memoryEnabled || !input.autoSuggest || !input.connectionSupportsTools || input.degraded ->
            MemoryProposeMode.FALLBACK
        else -> MemoryProposeMode.TOOL
    }

    /** Rule 6: [rejectionQualifies] is the tool-unsupported-4xx matcher verdict for the rejection. */
    fun degrade(
        rejectionQualifies: Boolean,
        legIndex: Int,
        streamStarted: Boolean,
        receivedStructuredToolCalls: Boolean,
    ): Boolean = rejectionQualifies && legIndex == 0 && !streamStarted && !receivedStructuredToolCalls

    /** Key of the in-process degraded set: connection id and model id joined by a newline. */
    fun degradedKey(connectionId: String, modelId: String): String = connectionId + "\n" + modelId

    /** Rule 4; [priorInstructInTurn] counts earlier calls of the same turn whose outcome was instruct. */
    fun propose(
        argumentsJson: String,
        context: MemoryProposeContext,
        priorInTurn: Int,
        priorInstructInTurn: Int = 0,
    ): MemoryProposeDecision {
        if (priorInTurn >= MAX_PROPOSALS_PER_TURN) return skip(MemoryProposeSkipReason.TURN_LIMIT)
        val invalid = skip(MemoryProposeSkipReason.INVALID_ARGUMENTS)
        val args = runCatching { Json.parseToJsonElement(argumentsJson) }.getOrNull() as? JsonObject ?: return invalid
        val proposition = args.stringField("proposition") ?: return invalid
        val sourceQuote = args.stringField("sourceQuote") ?: return invalid
        val kind = args.stringField("kind")?.let { w -> KINDS.firstOrNull { it.wire == w } } ?: return invalid
        val scope = args.stringField("scope")?.let { w -> SCOPES.firstOrNull { it.wire == w } } ?: return invalid
        val content = proposition.trimWhiteSpace()
        val quote = MemoryIntent.canonical(sourceQuote)
        if (content.isEmpty() || quote.isEmpty()) return invalid
        if (content.codePointCount(0, content.length) > MemoryIntentLexicon.CONTENT_MAX_CODE_POINTS) {
            return skip(MemoryProposeSkipReason.TOO_LONG)
        }
        if (!MemoryIntent.canonical(context.userText).contains(quote)) {
            return skip(MemoryProposeSkipReason.QUOTE_NOT_IN_MESSAGE)
        }
        val sensitive = listOf(context.userText, content, sourceQuote).map { MemoryIntent.classify(it).sensitive }
        if (sensitive.any { it == MemoryIntentSensitive.SECRET }) return skip(MemoryProposeSkipReason.SECRET)
        if (sensitive.drop(1).any { it == MemoryIntentSensitive.SPECIAL }) return skip(MemoryProposeSkipReason.SPECIAL)
        // v3: scope=conversation accepts only instruction and yields instruct (the sentence goes to the instruction suggestion bar; no memory candidate is created)
        if (scope == MemoryIntentScope.CONVERSATION) {
            if (kind != MemoryKind.INSTRUCTION) return skip(MemoryProposeSkipReason.CONVERSATION_NOT_INSTRUCTION)
            if (priorInstructInTurn >= MAX_INSTRUCT_PER_TURN) return skip(MemoryProposeSkipReason.INSTRUCT_LIMIT)
            return MemoryProposeDecision(MemoryProposeAction.INSTRUCT, null, null, sourceQuote.trimWhiteSpace())
        }
        // A convention scoped to this conversation belongs to the "set as conversation instructions" suggestion, not to a memory item
        val v1 = MemoryIntent.classify(context.userText)
        if (v1.suggestion == MemoryIntentSuggestion.CONVERSATION_INSTRUCTION || v1.blocked == MemoryIntentBlocked.CONVERSATION_SCOPE) {
            return skip(MemoryProposeSkipReason.CONVERSATION_INSTRUCTION)
        }
        val decision = MemoryIntent.makeCandidate(
            MemoryIntentClassification(
                intent = MemoryIntent.Intent.IMPLICIT_PERSIST,
                rule = null,
                span = null,
                proposition = content,
                kind = kind,
                scope = scope,
                sensitive = MemoryIntentSensitive.NONE,
                blocked = null,
                suggestion = MemoryIntentSuggestion.MEMORY,
            ),
            MemoryCandidateContext(
                conversationId = context.conversationId,
                folderId = context.folderId,
                messageId = context.messageId,
                nowMs = context.nowMs,
                activeContents = context.activeContents,
                records = context.records,
            ),
        )
        return MemoryProposeDecision(
            action = if (decision.action == MemoryCandidateAction.CREATE) MemoryProposeAction.CREATE else MemoryProposeAction.SKIP,
            reason = decision.reason?.let { r -> MemoryProposeSkipReason.fromWire(r.wire)!! },
            candidate = decision.candidate,
        )
    }

    private fun skip(reason: MemoryProposeSkipReason) = MemoryProposeDecision(MemoryProposeAction.SKIP, reason, null)

    private fun JsonObject.stringField(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
}
