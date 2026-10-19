package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.DirectiveDetector.Sentence
import ai.oriveo.community.core.context.DirectiveDetector.Term
import ai.oriveo.community.core.mcp.mcpSha256Hex

enum class MemoryIntentRule(val wire: String) {
    QUOTED("quoted"),
    META("meta"),
    QUESTION("question"),
    RECALL("recall"),
    DELETE("delete"),
    SUPERSEDE("supersede"),
    TRANSIENT("transient"),
    REMINDER("reminder"),
    REMINISCE("reminisce"),
    ANAPHOR("anaphor"),
    PERSIST("persist"),
    DIRECTIVE("directive"),
    LOOSE_DIRECTIVE("loose_directive"),
    ACK("ack"),
    ANAPHOR_DIRECTIVE("anaphor_directive"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryIntentRule? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryIntentScope(val wire: String) {
    GLOBAL("global"),
    FOLDER("folder"),
    CONVERSATION("conversation"),
    UNSPECIFIED("unspecified"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryIntentScope? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryIntentSensitive(val wire: String) {
    NONE("none"),
    SECRET("secret"),
    SPECIAL("special"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryIntentSensitive? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryIntentBlocked(val wire: String) {
    CONVERSATION_SCOPE("conversation_scope"),
    SECRET("secret"),
    SPECIAL("special"),
    TOO_LONG("too_long"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryIntentBlocked? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryIntentSuggestion(val wire: String) {
    MEMORY("memory"),
    CONVERSATION_INSTRUCTION("conversationInstruction"),
    NONE("none"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryIntentSuggestion? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryCandidateStatus(val wire: String) {
    PENDING("pending"),
    ACCEPTED("accepted"),
    REJECTED("rejected"),
    SUPERSEDED("superseded"),
    EXPIRED("expired"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryCandidateStatus? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryCandidateAction(val wire: String) {
    CREATE("create"),
    SKIP("skip"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryCandidateAction? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryCandidateSkipReason(val wire: String) {
    NO_SUGGESTION("no_suggestion"),
    AUTO_SUGGEST_OFF("auto_suggest_off"),
    DUPLICATE_ACTIVE("duplicate_active"),
    EXISTS("exists"),
    DUPLICATE_PENDING("duplicate_pending"),
    REJECTED_RECENTLY("rejected_recently"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryCandidateSkipReason? = entries.firstOrNull { it.wire == wire }
    }
}

enum class MemoryCandidateError(val wire: String) {
    NOT_PENDING("not_pending"),
    EXPIRED("expired"),
    EMPTY("empty"),
    TOO_LONG("too_long"),
    ;

    companion object {
        fun fromWire(wire: String): MemoryCandidateError? = entries.firstOrNull { it.wire == wire }
    }
}

/** Classification of one user message (memory-intent.v1 rule 9). */
data class MemoryIntentClassification(
    val intent: MemoryIntent.Intent,
    val rule: MemoryIntentRule?,
    val span: String?,
    val proposition: String?,
    val kind: MemoryKind?,
    val scope: MemoryIntentScope?,
    val sensitive: MemoryIntentSensitive,
    val blocked: MemoryIntentBlocked?,
    val suggestion: MemoryIntentSuggestion,
)

data class MemoryCandidateSource(
    val type: MemorySourceType = MemorySourceType.CONVERSATION,
    val conversationId: String?,
    val messageIds: List<String>,
    val observedAtMs: Long?,
)

/** Local-only memory candidate record (never cloud-synced, never in backups). */
data class MemoryCandidate(
    val id: String,
    val status: MemoryCandidateStatus,
    val proposedLayer: MemoryLayer,
    val proposedKind: MemoryKind,
    val content: String,
    val scope: MemoryItemScope,
    val source: MemoryCandidateSource,
    val sensitivity: MemorySensitivity,
    val confidence: Double,
    val fingerprint: String,
    val createdAtMs: Long,
    val expiresAtMs: Long,
    val resolvedAtMs: Long?,
)

data class MemoryCandidateContext(
    val conversationId: String,
    val folderId: String?,
    val messageId: String,
    val nowMs: Long,
    val activeContents: List<String>,
    val records: List<MemoryCandidate>,
    /** Per-account local "auto suggest" switch; off skips implicit_persist only (explicit "remember" still creates). */
    val autoSuggest: Boolean = true,
)

data class MemoryCandidateDecision(
    val action: MemoryCandidateAction,
    val reason: MemoryCandidateSkipReason?,
    val candidate: MemoryCandidate?,
)

data class MemoryCandidateEdit(
    val content: String? = null,
    val kind: MemoryKind? = null,
    val scope: MemoryItemScope? = null,
)

/** Draft the client turns into a new Memory Item through its normal create path. */
data class MemoryItemDraft(
    val layer: MemoryLayer,
    val kind: MemoryKind,
    val status: MemoryStatus,
    val content: String,
    val scope: MemoryItemScope,
    val source: MemoryCandidateSource,
    val sensitivity: MemorySensitivity,
    val confidence: Double,
)

/** Either [record] (plus [item] for accept) or [error]. */
data class MemoryCandidateTransition(
    val record: MemoryCandidate? = null,
    val item: MemoryItemDraft? = null,
    val error: MemoryCandidateError? = null,
)

data class MemoryCandidateSweep(
    val keptIds: List<String>,
    val expiredIds: List<String>,
    val supersededIds: List<String>,
    val purgedIds: List<String>,
)

/**
 * Memory write-intent classifier and candidate lifecycle (memory-intent.v1 `algorithm` 1–14).
 * Pure: no storage, no network. Directive primitives and detection come from [DirectiveDetector].
 */
object MemoryIntent {

    /** Message write intent (memory-intent.v1 `intents`). */
    enum class Intent(val wire: String) {
        EXPLICIT_PERSIST("explicit_persist"),
        IMPLICIT_PERSIST("implicit_persist"),
        TRANSIENT("transient"),
        RECALL("recall"),
        DELETE_OR_SUPERSEDE("delete_or_supersede"),
        ACK_OR_META("ack_or_meta"),
        UNCERTAIN("uncertain"),
        NONE("none"),
        ;

        val persists: Boolean get() = this == EXPLICIT_PERSIST || this == IMPLICIT_PERSIST

        companion object {
            fun fromWire(wire: String): Intent? = entries.firstOrNull { it.wire == wire }
        }
    }


    fun classify(text: String): MemoryIntentClassification {
        var best: Decision? = null
        for (sentence in DirectiveDetector.sentences(text)) {
            val decision = decide(sentence) ?: continue
            if (best == null || decision.rank > best.rank) best = decision
        }
        val sensitive = sensitive(text)
        val isDirective by lazy { DirectiveDetector.detect(text).isDirective }
        if (best == null || !best.intent.persists) {
            val suggestion = when {
                sensitive == MemoryIntentSensitive.SECRET -> MemoryIntentSuggestion.NONE
                isDirective -> MemoryIntentSuggestion.CONVERSATION_INSTRUCTION
                else -> MemoryIntentSuggestion.NONE
            }
            return MemoryIntentClassification(
                intent = best?.intent ?: MemoryIntent.Intent.NONE,
                rule = best?.rule,
                span = best?.span,
                proposition = null,
                kind = null,
                scope = null,
                sensitive = sensitive,
                blocked = null,
                suggestion = suggestion,
            )
        }
        val proposition = best.proposition!!
        val blocked = when {
            best.scope == MemoryIntentScope.CONVERSATION -> MemoryIntentBlocked.CONVERSATION_SCOPE
            sensitive == MemoryIntentSensitive.SECRET -> MemoryIntentBlocked.SECRET
            sensitive == MemoryIntentSensitive.SPECIAL -> MemoryIntentBlocked.SPECIAL
            proposition.cpLength() > MemoryIntentLexicon.CONTENT_MAX_CODE_POINTS -> MemoryIntentBlocked.TOO_LONG
            else -> null
        }
        val suggestion = when {
            sensitive == MemoryIntentSensitive.SECRET -> MemoryIntentSuggestion.NONE
            blocked == null -> MemoryIntentSuggestion.MEMORY
            isDirective -> MemoryIntentSuggestion.CONVERSATION_INSTRUCTION
            else -> MemoryIntentSuggestion.NONE
        }
        return MemoryIntentClassification(
            intent = best.intent,
            rule = best.rule,
            span = best.span,
            proposition = proposition,
            kind = best.kind,
            scope = best.scope,
            sensitive = sensitive,
            blocked = blocked,
            suggestion = suggestion,
        )
    }

    /** norm(content), White_Space runs collapsed to one U+0020, both ends trimmed. */
    fun canonical(content: String): String {
        val normalized = DirectiveDetector.norm(content)
        val sb = StringBuilder(normalized.length)
        var inSpace = false
        for (ch in normalized) {
            if (ch.isUnicodeWhiteSpace()) {
                if (!inSpace) sb.append(' ')
                inSpace = true
            } else {
                sb.append(ch)
                inSpace = false
            }
        }
        return sb.toString().trimWhiteSpace()
    }

    fun fingerprint(content: String): String = mcpSha256Hex(canonical(content))

    fun makeCandidate(classification: MemoryIntentClassification, context: MemoryCandidateContext): MemoryCandidateDecision {
        val noSuggestion = skip(MemoryCandidateSkipReason.NO_SUGGESTION)
        if (classification.suggestion != MemoryIntentSuggestion.MEMORY || !classification.intent.persists) return noSuggestion
        val content = classification.proposition ?: return noSuggestion
        val kind = classification.kind ?: return noSuggestion
        val proposedScope = classification.scope ?: return noSuggestion
        if (!context.autoSuggest && classification.intent == Intent.IMPLICIT_PERSIST) {
            return skip(MemoryCandidateSkipReason.AUTO_SUGGEST_OFF)
        }
        val fp = fingerprint(content)
        if (context.activeContents.any { fingerprint(it) == fp }) return skip(MemoryCandidateSkipReason.DUPLICATE_ACTIVE)
        // MemoryItems.uuid hashes under MemoryItems.UUID_NAMESPACE, which equals memory-intent uuidNamespace;
        // constants_match_fixture asserts both against the fixture.
        val id = MemoryItems.uuid(context.messageId + "\n" + fp)
        for (r in context.records) {
            val reason = when {
                r.id == id -> MemoryCandidateSkipReason.EXISTS
                r.fingerprint == fp && r.status == MemoryCandidateStatus.PENDING -> MemoryCandidateSkipReason.DUPLICATE_PENDING
                r.fingerprint == fp && r.status == MemoryCandidateStatus.REJECTED && context.nowMs < r.expiresAtMs ->
                    MemoryCandidateSkipReason.REJECTED_RECENTLY
                else -> null
            }
            if (reason != null) return skip(reason)
        }
        val folder = context.folderId
        val scope = when (proposedScope) {
            MemoryIntentScope.FOLDER ->
                if (folder != null) MemoryItemScope(MemoryScopeType.FOLDER, folder)
                else MemoryItemScope(MemoryScopeType.CONVERSATION, context.conversationId)
            MemoryIntentScope.UNSPECIFIED ->
                if (folder != null) MemoryItemScope(MemoryScopeType.FOLDER, folder)
                else MemoryItemScope(MemoryScopeType.GLOBAL, null)
            MemoryIntentScope.CONVERSATION -> MemoryItemScope(MemoryScopeType.CONVERSATION, context.conversationId)
            MemoryIntentScope.GLOBAL -> MemoryItemScope(MemoryScopeType.GLOBAL, null)
        }
        val candidate = MemoryCandidate(
            id = id,
            status = MemoryCandidateStatus.PENDING,
            proposedLayer = MemoryPropose.layerFor(kind),
            proposedKind = kind,
            content = content,
            scope = scope,
            source = MemoryCandidateSource(
                conversationId = context.conversationId,
                messageIds = listOf(context.messageId),
                observedAtMs = context.nowMs,
            ),
            sensitivity = MemorySensitivity.NORMAL,
            confidence = if (classification.intent == MemoryIntent.Intent.EXPLICIT_PERSIST) {
                MemoryIntentLexicon.CONFIDENCE_EXPLICIT
            } else {
                MemoryIntentLexicon.CONFIDENCE_IMPLICIT
            },
            fingerprint = fp,
            createdAtMs = context.nowMs,
            expiresAtMs = context.nowMs + MemoryIntentLexicon.CANDIDATE_TTL_MS,
            resolvedAtMs = null,
        )
        return MemoryCandidateDecision(MemoryCandidateAction.CREATE, null, candidate)
    }

    fun accept(record: MemoryCandidate, edit: MemoryCandidateEdit?, nowMs: Long): MemoryCandidateTransition {
        if (record.status != MemoryCandidateStatus.PENDING) return MemoryCandidateTransition(error = MemoryCandidateError.NOT_PENDING)
        if (nowMs >= record.expiresAtMs) return MemoryCandidateTransition(error = MemoryCandidateError.EXPIRED)
        val content = edit?.content?.trimWhiteSpace() ?: record.content
        if (content.isEmpty()) return MemoryCandidateTransition(error = MemoryCandidateError.EMPTY)
        if (content.cpLength() > MemoryIntentLexicon.CONTENT_MAX_CODE_POINTS) {
            return MemoryCandidateTransition(error = MemoryCandidateError.TOO_LONG)
        }
        val kind = edit?.kind ?: record.proposedKind
        val item = MemoryItemDraft(
            // The layer follows the final kind, so it changes with it when the user edits the kind
            layer = MemoryPropose.layerFor(kind),
            kind = kind,
            status = MemoryStatus.ACTIVE,
            content = content,
            scope = edit?.scope ?: record.scope,
            source = record.source,
            sensitivity = record.sensitivity,
            confidence = if (content == record.content) record.confidence else 1.0,
        )
        return MemoryCandidateTransition(record = cleared(record, MemoryCandidateStatus.ACCEPTED, nowMs, record.expiresAtMs), item = item)
    }

    fun reject(record: MemoryCandidate, nowMs: Long): MemoryCandidateTransition {
        if (record.status != MemoryCandidateStatus.PENDING) return MemoryCandidateTransition(error = MemoryCandidateError.NOT_PENDING)
        return MemoryCandidateTransition(
            record = cleared(record, MemoryCandidateStatus.REJECTED, nowMs, nowMs + MemoryIntentLexicon.CANDIDATE_TTL_MS),
        )
    }

    fun sweep(records: List<MemoryCandidate>, activeContents: List<String>, nowMs: Long): MemoryCandidateSweep {
        val activeFingerprints = activeContents.map(::fingerprint).toSet()
        val kept = ArrayList<String>()
        val expired = ArrayList<String>()
        val superseded = ArrayList<String>()
        val purged = ArrayList<String>()
        for (r in records) {
            when {
                r.status == MemoryCandidateStatus.PENDING && nowMs >= r.expiresAtMs -> {
                    expired += r.id
                    purged += r.id
                }
                r.status == MemoryCandidateStatus.PENDING && r.fingerprint in activeFingerprints -> {
                    superseded += r.id
                    purged += r.id
                }
                r.status == MemoryCandidateStatus.PENDING -> kept += r.id
                r.status == MemoryCandidateStatus.REJECTED && nowMs < r.expiresAtMs -> kept += r.id
                else -> purged += r.id
            }
        }
        return MemoryCandidateSweep(kept, expired, superseded, purged)
    }

    // ---- candidate helpers ----

    private fun skip(reason: MemoryCandidateSkipReason) = MemoryCandidateDecision(MemoryCandidateAction.SKIP, reason, null)

    private fun cleared(record: MemoryCandidate, status: MemoryCandidateStatus, nowMs: Long, expiresAtMs: Long) = record.copy(
        status = status,
        content = "",
        source = MemoryCandidateSource(conversationId = null, messageIds = emptyList(), observedAtMs = null),
        resolvedAtMs = nowMs,
        expiresAtMs = expiresAtMs,
    )

    // ---- sentence decision (rule 4) ----

    private class Decision(
        val intent: MemoryIntent.Intent,
        val rule: MemoryIntentRule,
        val span: String,
        val proposition: String? = null,
        val kind: MemoryKind? = null,
        val scope: MemoryIntentScope? = null,
    ) {
        val rank: Int = when (intent) {
            MemoryIntent.Intent.DELETE_OR_SUPERSEDE -> 80
            MemoryIntent.Intent.EXPLICIT_PERSIST -> 70
            MemoryIntent.Intent.IMPLICIT_PERSIST -> if (scope != MemoryIntentScope.CONVERSATION) 65 else 60
            MemoryIntent.Intent.UNCERTAIN -> 50
            MemoryIntent.Intent.RECALL -> 40
            MemoryIntent.Intent.TRANSIENT -> 30
            MemoryIntent.Intent.ACK_OR_META -> 20
            MemoryIntent.Intent.NONE -> 0
        }
    }

    private fun decide(sentence: Sentence): Decision? {
        val span = sentence.span
        val masked = sentence.masked.codePoints().toArray()
        val m2 = codeMask(masked).let { String(it, 0, it.size) }
        val o = Sentence(span, span)
        val s = Sentence(span, m2)
        val detection by lazy { DirectiveDetector.detect(span) }
        fun simple(intent: MemoryIntent.Intent, rule: MemoryIntentRule) = Decision(intent, rule, span)
        fun implicit(rule: MemoryIntentRule, global: Boolean): Decision {
            val scope = when {
                global -> MemoryIntentScope.GLOBAL
                has(s, Table.FOLDER_MARKERS) -> MemoryIntentScope.FOLDER
                else -> MemoryIntentScope.CONVERSATION
            }
            return Decision(MemoryIntent.Intent.IMPLICIT_PERSIST, rule, span, span, MemoryKind.INSTRUCTION, scope)
        }

        if (has(o, Table.MEMORY_WORDS) && !has(s, Table.MEMORY_WORDS)) {
            return simple(MemoryIntent.Intent.ACK_OR_META, MemoryIntentRule.QUOTED)
        }
        if (has(s, Table.MEMORY_WORDS) && has(s, Table.META_TERMS)) {
            return simple(MemoryIntent.Intent.ACK_OR_META, MemoryIntentRule.META)
        }
        if (sentence.isQuestion) {
            val recall = (has(s, Table.MEMORY_WORDS) && has(s, Table.RECALL_ADDRESSEES)) || has(s, Table.RECALL_TERMS)
            return if (recall) simple(MemoryIntent.Intent.RECALL, MemoryIntentRule.QUESTION) else null
        }
        if (has(s, Table.RECALL_TERMS)) return simple(MemoryIntent.Intent.RECALL, MemoryIntentRule.RECALL)
        if (hasExcept(s, Table.DELETE_TERMS, Table.DELETE_EXCEPTIONS)) {
            return simple(MemoryIntent.Intent.DELETE_OR_SUPERSEDE, MemoryIntentRule.DELETE)
        }
        if (has(s, Table.SUPERSEDE_TERMS)) return simple(MemoryIntent.Intent.DELETE_OR_SUPERSEDE, MemoryIntentRule.SUPERSEDE)
        if (hasExcept(s, Table.TRANSIENT_TERMS, Table.TRANSIENT_EXCEPTIONS)) {
            return simple(MemoryIntent.Intent.TRANSIENT, MemoryIntentRule.TRANSIENT)
        }
        if (head(s, Table.REMINDER_STARTS)) {
            return if (detection.isDirective) {
                implicit(MemoryIntentRule.DIRECTIVE, detection.scope == DirectiveScope.GLOBAL)
            } else {
                simple(MemoryIntent.Intent.TRANSIENT, MemoryIntentRule.REMINDER)
            }
        }
        if (head(s, Table.PERSIST_STARTS) && !head(s, Table.ACK_TERMS)) {
            val p = proposition(span)
            if (p.isNotEmpty() && head(Sentence(p, p), Table.REMINISCE_STARTS)) {
                return simple(MemoryIntent.Intent.ACK_OR_META, MemoryIntentRule.REMINISCE)
            }
            if (anaphorOnly(p)) return simple(MemoryIntent.Intent.UNCERTAIN, MemoryIntentRule.ANAPHOR)
            val scope = when {
                dirHasAnyGlobal(s) -> MemoryIntentScope.GLOBAL
                has(s, Table.FOLDER_MARKERS) -> MemoryIntentScope.FOLDER
                has(s, Table.CONVERSATION_MARKERS) -> MemoryIntentScope.CONVERSATION
                else -> MemoryIntentScope.UNSPECIFIED
            }
            return Decision(MemoryIntent.Intent.EXPLICIT_PERSIST, MemoryIntentRule.PERSIST, span, p, kindOf(p), scope)
        }
        if (detection.isDirective) return implicit(MemoryIntentRule.DIRECTIVE, detection.scope == DirectiveScope.GLOBAL)
        if (has(s, Table.IMPLICIT_MARKERS) &&
            DIR_ZH_EN.any { l -> l.verbs.any { l.matches(it, s) } } &&
            DIR_ZH_EN.none { l -> l.vetoes.any { l.matches(it, s) } } &&
            !has(s, Table.ACK_TERMS)
        ) {
            return implicit(MemoryIntentRule.LOOSE_DIRECTIVE, dirHasAnyGlobal(s))
        }
        if (has(s, Table.ACK_TERMS)) return simple(MemoryIntent.Intent.ACK_OR_META, MemoryIntentRule.ACK)
        if (has(s, Table.UNCERTAIN_MARKERS) && has(s, Table.ANAPHOR_DIRECTIVE)) {
            return simple(MemoryIntent.Intent.UNCERTAIN, MemoryIntentRule.ANAPHOR_DIRECTIVE)
        }
        return null
    }

    private fun dirHasAnyGlobal(s: Sentence): Boolean =
        DirectiveDetector.LANGUAGES.any { l -> l.globalMarkers.any { l.matches(it, s) } }

    // ---- code mask (rule 3) ----

    private fun codeMask(m: IntArray): IntArray {
        val out = m.copyOf()
        var i = 0
        while (i < m.size) {
            if (m[i] !in 0x21..0x7E) {
                i++
                continue
            }
            var end = i
            while (end < m.size && m[end] in 0x21..0x7E) end++
            var code = false
            for (k in i until end) {
                val c = m[k]
                if (c in CODE_TOKEN_CHARS) code = true
                if (k + 1 < end && c in 'a'.code..'z'.code && m[k + 1] in 'A'.code..'Z'.code) code = true
                if (k + 2 < end && isAsciiAlnum(c) && m[k + 1] == '.'.code && isAsciiLetter(m[k + 2])) code = true
                if (code) break
            }
            if (code) for (k in i until end) out[k] = ' '.code
            i = end
        }
        return out
    }

    private fun isAsciiLetter(c: Int): Boolean = c in 'a'.code..'z'.code || c in 'A'.code..'Z'.code

    private fun isAsciiAlnum(c: Int): Boolean = isAsciiLetter(c) || c in '0'.code..'9'.code

    // ---- proposition (rule 5) ----

    private class PropTerm(raw: String, val word: Boolean) {
        val cps: IntArray = raw.codePoints().toArray()
    }

    private fun proposition(span: String): String {
        val cps = span.codePoints().toArray()
        val folded = IntArray(cps.size) { if (cps[it] in 'A'.code..'Z'.code) cps[it] + 32 else cps[it] }
        fun matches(t: PropTerm, i: Int): Boolean {
            val n = t.cps.size
            if (n == 0 || i + n > folded.size) return false
            for (k in 0 until n) if (folded[i + k] != t.cps[k]) return false
            return !t.word || i + n == folded.size || !DirectiveDetector.isWordCodePoint(folded[i + n])
        }
        fun longest(terms: List<PropTerm>, i: Int): Int = terms.filter { matches(it, i) }.maxOfOrNull { it.cps.size } ?: 0
        fun skipSeparators(from: Int): Int {
            var i = from
            while (i < cps.size && isSeparator(cps[i])) i++
            return i
        }
        var i = 0
        while (true) {
            i = skipSeparators(i)
            if (PERSIST_PROP.any { matches(it, i) }) break
            val n = longest(PREFIX_PROP, i)
            if (n == 0) return span.trimWhiteSpace()
            i += n
        }
        i += longest(PERSIST_PROP, i)
        while (true) {
            i = skipSeparators(i)
            val n = longest(LINKER_PROP, i)
            if (n == 0) break
            i += n
        }
        return String(cps, i, cps.size - i).trimWhiteSpace()
    }

    private fun isSeparator(cp: Int): Boolean = isWhiteSpace(cp) || cp in SEPARATORS

    private fun isWhiteSpace(cp: Int): Boolean = cp <= 0xFFFF && cp.toChar().isUnicodeWhiteSpace()

    // ---- anaphorOnly / kindOf (rule 6) ----

    private fun anaphorOnly(p: String): Boolean {
        val cps = p.trimWhiteSpace().codePoints().toArray()
        var end = cps.size
        while (end > 0 && isSeparator(cps[end - 1])) end--
        if (end == 0) return true
        val stripped = String(cps, 0, end)
        val strippedNorm = DirectiveDetector.norm(stripped)
        val core = DirectiveDetector.wordform(DirectiveDetector.norm(p)).trim(' ')
        return LANGS.any { l ->
            l.terms(Table.ANAPHOR_ONLY).any { t ->
                if (l.mode == DirectiveLexicon.Mode.SUBSTRING) strippedNorm == t.norm else core == t.word
            }
        }
    }

    private fun kindOf(p: String): MemoryKind {
        val s = Sentence(p, p)
        if (DirectiveDetector.detect(p).isDirective || DIR_ZH_EN.any { it.passesStarts(s) }) return MemoryKind.INSTRUCTION
        return KIND_TABLES.firstOrNull { (table, _) -> head(s, table) }?.second ?: MemoryKind.FACT
    }

    // ---- sensitive (rule 8) ----

    private fun sensitive(text: String): MemoryIntentSensitive {
        val scanned = text.codePoints().limit(DirectiveLexicon.MAX_SCAN_CODE_POINTS.toLong()).toArray()
            .let { String(it, 0, it.size) }
        val s = Sentence(scanned, scanned)
        val secret = has(s, Table.SECRET_TERMS) || SECRET_REGEXES.any { (regex, luhn) ->
            regex.findAll(scanned).any { m -> !luhn || luhnValid(m.value) }
        }
        return when {
            secret -> MemoryIntentSensitive.SECRET
            has(s, Table.SPECIAL_TERMS) -> MemoryIntentSensitive.SPECIAL
            else -> MemoryIntentSensitive.NONE
        }
    }

    private fun luhnValid(match: String): Boolean {
        val digits = match.filter { it in '0'..'9' }.map { it - '0' }
        if (digits.isEmpty()) return false
        var sum = 0
        digits.asReversed().forEachIndexed { index, d ->
            sum += if (index % 2 == 1) (d * 2).let { if (it > 9) it - 9 else it } else d
        }
        return sum % 10 == 0
    }

    // ---- lexicon (rules 1–2) ----

    private enum class Table(val pick: (MemoryIntentLexicon.Language) -> List<String>) {
        MEMORY_WORDS({ it.memoryWords }),
        META_TERMS({ it.metaTerms }),
        RECALL_ADDRESSEES({ it.recallAddressees }),
        RECALL_TERMS({ it.recallTerms }),
        DELETE_TERMS({ it.deleteTerms }),
        DELETE_EXCEPTIONS({ it.deleteExceptions }),
        SUPERSEDE_TERMS({ it.supersedeTerms }),
        TRANSIENT_TERMS({ it.transientTerms }),
        TRANSIENT_EXCEPTIONS({ it.transientExceptions }),
        PERSIST_STARTS({ it.persistStarts }),
        REMINDER_STARTS({ it.reminderStarts }),
        ACK_TERMS({ it.ackTerms }),
        REMINISCE_STARTS({ it.reminisceStarts }),
        ANAPHOR_ONLY({ it.anaphorOnly }),
        ANAPHOR_DIRECTIVE({ it.anaphorDirective }),
        UNCERTAIN_MARKERS({ it.uncertainMarkers }),
        IMPLICIT_MARKERS({ it.implicitMarkers }),
        FOLDER_MARKERS({ it.folderMarkers }),
        CONVERSATION_MARKERS({ it.conversationMarkers }),
        SECRET_TERMS({ it.secretTerms }),
        SPECIAL_TERMS({ it.specialTerms }),
        KIND_PROJECT({ it.kindProject }),
        KIND_GOAL({ it.kindGoal }),
        KIND_PREFERENCE({ it.kindPreference }),
        KIND_IDENTITY({ it.kindIdentity }),
    }

    /** One memory lexicon language matched in the mode of its directive-detector language. */
    private class Lang(val source: MemoryIntentLexicon.Language) {
        val mode = source.mode
        private val dirSource: DirectiveLexicon.Language = DirectiveLexicon.languages.first { it.code == source.code }
        val dir: DirectiveDetector.Lang = DirectiveDetector.LANGUAGES[DirectiveLexicon.languages.indexOf(dirSource)]
        private val terms = HashMap<Table, List<Term>>()
        private val heads = HashMap<Table, DirectiveDetector.Lang>()

        fun terms(table: Table): List<Term> = terms.getOrPut(table) { table.pick(source).map(::Term) }

        fun has(s: Sentence, table: Table): Boolean = terms(table).any { dir.matches(it, s) }

        /** Rule 9 with this language's directive fillers and [table] in place of starts. */
        fun head(s: Sentence, table: Table): Boolean =
            heads.getOrPut(table) { DirectiveDetector.Lang(dirSource.copy(starts = table.pick(source))) }.passesStarts(s)

        fun hasExcept(s: Sentence, table: Table, exceptions: Table): Boolean {
            if (mode == DirectiveLexicon.Mode.SUBSTRING) {
                var n = s.norm
                for (e in terms(exceptions)) if (e.norm.isNotEmpty()) n = n.replace(e.norm, " ")
                return terms(table).any { n.contains(it.norm) }
            }
            var w = s.wordform
            for (e in terms(exceptions)) {
                val pattern = " ${e.word} "
                while (true) {
                    val at = w.indexOf(pattern)
                    if (at < 0) break
                    w = w.substring(0, at) + " " + w.substring(at + pattern.length)
                }
            }
            return terms(table).any { w.contains(" ${it.word} ") }
        }
    }

    private val LANGS: List<Lang> by lazy { MemoryIntentLexicon.languages.map(::Lang) }

    private val DIR_ZH_EN: List<DirectiveDetector.Lang> by lazy { LANGS.map { it.dir } }

    private fun has(s: Sentence, table: Table): Boolean = LANGS.any { it.has(s, table) }

    private fun head(s: Sentence, table: Table): Boolean = LANGS.any { it.head(s, table) }

    private fun hasExcept(s: Sentence, table: Table, exceptions: Table): Boolean = LANGS.any { it.hasExcept(s, table, exceptions) }

    private val KIND_TABLES: List<Pair<Table, MemoryKind>> = listOf(
        Table.KIND_PROJECT to MemoryKind.PROJECT,
        Table.KIND_GOAL to MemoryKind.GOAL,
        Table.KIND_PREFERENCE to MemoryKind.PREFERENCE,
        Table.KIND_IDENTITY to MemoryKind.IDENTITY,
    )

    private val PERSIST_PROP: List<PropTerm> by lazy {
        MemoryIntentLexicon.languages.flatMap { l -> l.persistStarts.map { PropTerm(it, l.mode == DirectiveLexicon.Mode.WORD) } }
    }

    private val PREFIX_PROP: List<PropTerm> by lazy {
        LANGS.flatMap { l ->
            val dirSource = DirectiveLexicon.languages.first { it.code == l.source.code }
            dirSource.fillers.map { PropTerm(it, dirSource.mode == DirectiveLexicon.Mode.WORD) } +
                l.source.politePrefixes.map { PropTerm(it, l.mode == DirectiveLexicon.Mode.WORD) }
        }
    }

    private val LINKER_PROP: List<PropTerm> by lazy {
        MemoryIntentLexicon.languages.flatMap { l -> l.linkers.map { PropTerm(it, l.mode == DirectiveLexicon.Mode.WORD) } }
    }

    private val CODE_TOKEN_CHARS: Set<Int> = MemoryIntentLexicon.CODE_TOKEN_CHARS.codePoints().toArray().toSet()

    private val SEPARATORS: Set<Int> = MemoryIntentLexicon.SEPARATORS.codePoints().toArray().toSet()

    private val SECRET_REGEXES: List<Pair<Regex, Boolean>> by lazy {
        MemoryIntentLexicon.secretPatterns.map { Regex(it.regex) to it.luhn }
    }

    private fun String.cpLength(): Int = codePointCount(0, length)
}
