import Foundation
import OriveoProviderKit

/// Conversation snapshot needed for one compaction: messages in chronological order; budget and estimation parameters come from this chat plan.
struct ContextCompactionSnapshot {
    var messages: [ContextCheckpoint.Message]
    /// Attachment placeholders by message id (one placeholder line per attachment in the summary request).
    var attachments: [String: [ContextCompactor.Attachment]] = [:]
    var B: Int
    var U: Int
    var rhoHi: Double
    /// Estimated tokens of the conversation system + tool definitions carried over by the appended form.
    var prefixTokens: Int
    /// Estimated tokens of the fixed overhead outside the tail (system, tools, etc.) when falling back.
    var fixedTokens: Int
    var model: String
}

/// Context compaction coordinator: picks AI / fallback mode, calls the summary,
/// produces and persists the checkpoint row, and hands it to the uploader when sync is bound. The circuit breaker is kept in memory per conversation and is not persisted.
/// The summary call, snapshot reading and upload are injected as closures; the pure compact functions are unchanged.
/// In production the snapshot and summary closure are passed per call (concurrent compactions of the same conversation each use their own); the constructor-injected snapshot / summarize are kept for tests.
@MainActor
final class ContextCompactionCoordinator {
    enum Trigger: String, Hashable, Sendable {
        case preSend
        case overflow
        case manual
    }

    struct Result: Hashable {
        var outcome: ContextCompactor.Outcome
        var row: ContextCheckpointRecord?
        var failures: [[ContextCompactor.FailureReason]]
        /// This AI summary was cancelled (by the user or because the whole send was stopped); manual compaction does not show a notice for it.
        var cancelled = false
    }

    static let remoteFlagKey = "context_compaction_enabled"

    private let store: ContextCompactionStore
    private let aiSummaryEnabled: () -> Bool
    private let remoteCompactionEnabled: () -> Bool
    private let snapshot: (String) -> ContextCompactionSnapshot?
    private let summarize: (String, ContextCompactor.SummaryRequest) async -> String?
    private let upload: ((ContextCheckpointRecord, [String]) -> Void)?
    private let now: () -> Date
    private var breakers: [String: ContextCompactionBreaker] = [:]
    /// In-flight AI summary calls, recorded per conversation and per call token; each one is ended on cancel.
    private var inflightSummaries: [String: [UUID: SummaryCall]] = [:]
    /// Single flight per conversation: the conversation that is running, plus the calls queued behind it (by call token; a waiter is woken individually when cancelled).
    private var runningCompactions: Set<String> = []
    private var compactionWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// Start / end of AI summaries in progress for this conversation (true = the first call started, false = the last one ended).
    var summaryActivityChanged: ((String, Bool) -> Void)?

    /// summarize(conversationId, request) returning nil = that call failed; upload nil = sync is not bound.
    init(
        store: ContextCompactionStore,
        aiSummaryEnabled: @escaping () -> Bool = { AppPreferencesStore.savedContextAISummaryEnabled },
        remoteCompactionEnabled: @escaping () -> Bool = {
            MetadataClient.shared.syncFeatureFlag(ContextCompactionCoordinator.remoteFlagKey, defaultValue: true)
        },
        snapshot: @escaping (String) -> ContextCompactionSnapshot? = { _ in nil },
        summarize: @escaping (String, ContextCompactor.SummaryRequest) async -> String? = { _, _ in nil },
        upload: ((ContextCheckpointRecord, [String]) -> Void)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.aiSummaryEnabled = aiSummaryEnabled
        self.remoteCompactionEnabled = remoteCompactionEnabled
        self.snapshot = snapshot
        self.summarize = summarize
        self.upload = upload
        self.now = now
    }

    // MARK: Circuit breaker

    func breakerState(conversationId: String) -> ContextCompactionBreaker.State {
        (breakers[conversationId] ?? ContextCompactionBreaker()).state
    }

    /// One round is recorded per chat send.
    func recordTurn(conversationId: String) {
        apply(.turn, conversationId: conversationId)
    }

    func retry(conversationId: String) {
        apply(.retry, conversationId: conversationId)
    }

    /// Test seam: sets this conversation's circuit-breaker state directly.
    func debugSetBreakerForTesting(_ breaker: ContextCompactionBreaker, conversationId: String) {
        breakers[conversationId] = breaker
    }

    private func apply(_ event: ContextCompactionBreaker.Event, conversationId: String) {
        var breaker = breakers[conversationId] ?? ContextCompactionBreaker()
        breaker.apply(event)
        breakers[conversationId] = breaker
    }

    // MARK: In progress and cancellation

    func isSummarizing(conversationId: String) -> Bool {
        !(inflightSummaries[conversationId]?.isEmpty ?? true)
    }

    /// Cancels this conversation's in-flight AI summaries: preSend / overflow continue with the fallback, manual returns noop.
    func cancelSummary(conversationId: String) {
        for call in (inflightSummaries[conversationId] ?? [:]).values {
            call.cancel()
        }
    }

    /// One summary call: a child Task runs the summary; when cancelled (this call by cancelSummary or the outer Task) it returns immediately without waiting for the network to wrap up.
    @MainActor
    private final class SummaryCall {
        private var continuation: CheckedContinuation<String??, Never>?
        private var child: Task<Void, Never>?
        private(set) var cancelled = false

        func start(
            _ summarize: @escaping (ContextCompactor.SummaryRequest) async -> String?,
            request: ContextCompactor.SummaryRequest,
            continuation: CheckedContinuation<String??, Never>
        ) {
            self.continuation = continuation
            child = Task { @MainActor [weak self] in
                let output = await summarize(request)
                self?.finish(.some(output))
            }
        }

        func cancel() {
            guard continuation != nil else { return }
            cancelled = true
            child?.cancel()
            finish(nil)
        }

        /// nil = cancelled.
        private func finish(_ value: String??) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    /// Returns nil = this call was cancelled; .some(nil) = the summary failed.
    private func cancellableSummary(
        conversationId: String,
        request: ContextCompactor.SummaryRequest,
        summarize: @escaping (ContextCompactor.SummaryRequest) async -> String?
    ) async -> String?? {
        if Task.isCancelled { return nil }
        let token = UUID()
        let call = SummaryCall()
        let wasIdle = !isSummarizing(conversationId: conversationId)
        inflightSummaries[conversationId, default: [:]][token] = call
        if wasIdle { summaryActivityChanged?(conversationId, true) }
        defer {
            inflightSummaries[conversationId]?[token] = nil
            if inflightSummaries[conversationId]?.isEmpty == true {
                inflightSummaries[conversationId] = nil
                summaryActivityChanged?(conversationId, false)
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                call.start(summarize, request: request, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in call.cancel() }
        }
    }

    // MARK: Entry points

    func compact(conversationId: String, trigger: Trigger) async -> Result {
        let summarize = self.summarize
        return await compact(
            conversationId: conversationId,
            trigger: trigger,
            snapshot: snapshot(conversationId),
            summarize: { request in await summarize(conversationId, request) }
        )
    }

    /// Each call brings its own snapshot and summary closure: two concurrent compactions of the same conversation never read each other's staging. summarize returning nil = that call failed.
    /// fallbackOnAIFailure = false (pre-compaction): when the AI summary fails, is too large or is cancelled, returns noop and writes no fallback row; the circuit breaker still counts.
    func compact(
        conversationId: String,
        trigger: Trigger,
        snapshot: ContextCompactionSnapshot?,
        fallbackOnAIFailure: Bool = true,
        summarize: @escaping (ContextCompactor.SummaryRequest) async -> String?
    ) async -> Result {
        guard let snapshot, !snapshot.messages.isEmpty else {
            return Result(outcome: .noop, row: nil, failures: [])
        }
        let covered = snapshot.messages.map { ContextCheckpoint.CoveredMessage(id: $0.id, text: $0.text ?? "") }
        // Single flight: if a compaction is already running for the same conversation (e.g. the AI summary of a pre-compaction), wait for it to finish and re-judge by latestValid, instead of issuing a second summary concurrently.
        var landedWhileWaiting = false
        if runningCompactions.contains(conversationId) {
            let before = latestValid(conversationId: conversationId, history: covered)?.checkpointId
            while runningCompactions.contains(conversationId) {
                await waitForRunningCompaction(conversationId: conversationId)
                if Task.isCancelled {
                    return Result(outcome: .noop, row: nil, failures: [], cancelled: true)
                }
            }
            let after = latestValid(conversationId: conversationId, history: covered)?.checkpointId
            landedWhileWaiting = after != nil && after != before
        }
        runningCompactions.insert(conversationId)
        defer { finishRunningCompaction(conversationId: conversationId) }

        let previous = latestValid(conversationId: conversationId, history: covered)
        // Before sending: if the awaited run already stored a row and after applying it P-hat < 0.90*B, hand that row back to send with.
        if landedWhileWaiting, trigger == .preSend, let previous,
           Self.fitsSendBudget(previous, snapshot: snapshot) {
            return Result(outcome: previous.kind == .summary ? .summary : .fallback, row: previous, failures: [])
        }

        var failures: [[ContextCompactor.FailureReason]] = []
        if useAI(conversationId: conversationId, trigger: trigger) {
            switch await summarizeSpan(
                conversationId: conversationId, snapshot: snapshot, previous: previous, summarize: summarize
            ) {
            case .noop:
                return Result(outcome: .noop, row: nil, failures: [])
            case .summary(let row):
                return settled(.summary, row: row, failures: [])
            case .failed(let attempts):
                failures = attempts
            case .tooLarge:
                break
            case .cancelled:
                // Stop (outer cancellation) or a cancelled manual compaction -> nothing is persisted; preSend / overflow continue with the fallback and no failure is counted.
                if Task.isCancelled || trigger == .manual || !fallbackOnAIFailure {
                    return Result(outcome: .noop, row: nil, failures: [], cancelled: true)
                }
            }
            if !fallbackOnAIFailure {
                return Result(outcome: .noop, row: nil, failures: failures)
            }
        }
        guard let row = fallbackRow(conversationId: conversationId, snapshot: snapshot, previous: previous) else {
            return Result(outcome: .noop, row: nil, failures: failures)
        }
        return settled(.fallback, row: row, failures: failures)
    }

    private func latestValid(
        conversationId: String,
        history: [ContextCheckpoint.CoveredMessage]
    ) -> ContextCheckpointRecord? {
        do {
            return try store.latestValid(conversationId: conversationId, history: history)
        } catch {
            print("[ContextCompactionCoordinator] latestValid failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// P-hat = fixedTokens (already includes the prefix and the current message) + stored-row estimate + estimate of the history after coversTo, the same rule as pre-compaction.
    private static func fitsSendBudget(_ row: ContextCheckpointRecord, snapshot: ContextCompactionSnapshot) -> Bool {
        var history = snapshot.messages[...]
        if let index = history.firstIndex(where: { $0.id == row.coversTo }) {
            history = history[(index + 1)...]
        }
        let pHat = snapshot.fixedTokens
            + ContextBudget.estimateMessage(row.text, rhoHi: snapshot.rhoHi)
            + history.reduce(0) { $0 + $1.estTokens }
        return pHat < ContextBudget.derived(B: snapshot.B).sendCompactAt
    }

    /// Suspends until the compaction running for this conversation ends; a waiter's Task returns immediately when cancelled (send stopped).
    private func waitForRunningCompaction(conversationId: String) async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !runningCompactions.contains(conversationId) {
                    continuation.resume()
                } else {
                    compactionWaiters[conversationId, default: [:]][token] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(conversationId: conversationId, token: token) }
        }
    }

    private func resumeWaiter(conversationId: String, token: UUID) {
        guard let continuation = compactionWaiters[conversationId]?.removeValue(forKey: token) else { return }
        continuation.resume()
    }

    private func finishRunningCompaction(conversationId: String) {
        runningCompactions.remove(conversationId)
        let waiters = compactionWaiters.removeValue(forKey: conversationId) ?? [:]
        for continuation in waiters.values { continuation.resume() }
    }

    /// A persistence failure returns noop (row nil, failures unchanged, no upload); the send path falls back to the in-memory fallback accordingly.
    private func settled(
        _ outcome: ContextCompactor.Outcome,
        row: ContextCheckpointRecord,
        failures: [[ContextCompactor.FailureReason]]
    ) -> Result {
        // The whole send was already stopped -> nothing is persisted.
        guard !Task.isCancelled else {
            return Result(outcome: .noop, row: nil, failures: failures, cancelled: true)
        }
        guard let saved = persist(row) else {
            return Result(outcome: .noop, row: nil, failures: failures)
        }
        return Result(outcome: outcome, row: saved, failures: failures)
    }

    /// Whether this conversation currently runs in AI mode (preference on AND remote flag on AND circuit breaker llm); pre-compaction uses it to decide whether to start.
    func isAIMode(conversationId: String) -> Bool {
        useAI(conversationId: conversationId, trigger: .preSend)
    }

    /// AI = preference on AND remote flag on AND this conversation's breaker is llm; manual ignores the preference and the breaker and falls back only when the remote flag is off.
    private func useAI(conversationId: String, trigger: Trigger) -> Bool {
        guard remoteCompactionEnabled() else { return false }
        if trigger == .manual { return true }
        return aiSummaryEnabled() && breakerState(conversationId: conversationId).mode == .llm
    }

    private enum AIOutcome {
        case noop
        case tooLarge
        case summary(ContextCheckpointRecord)
        case failed([[ContextCompactor.FailureReason]])
        case cancelled
    }

    /// At most 2 summary calls; a passing summary records llmSuccess, and failing both records one llmFailure.
    private func summarizeSpan(
        conversationId: String,
        snapshot: ContextCompactionSnapshot,
        previous: ContextCheckpointRecord?,
        summarize: @escaping (ContextCompactor.SummaryRequest) async -> String?
    ) async -> AIOutcome {
        let span = ContextCheckpoint.selectSpan(messages: snapshot.messages, B: snapshot.B, previousCoversTo: previous?.coversTo)
        guard span.action == .compact, !span.spanIds.isEmpty else { return .noop }
        let byId = Dictionary(snapshot.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spanMessages = span.spanIds.compactMap { id in
            byId[id].map {
                ContextCompactor.SpanMessage(
                    id: $0.id, role: $0.role, text: $0.text ?? "", attachments: snapshot.attachments[$0.id] ?? []
                )
            }
        }
        let request = ContextCompactor.summaryRequest(ContextCompactor.SummaryRequestInput(
            U: snapshot.U,
            prefixTokens: snapshot.prefixTokens,
            rhoHi: snapshot.rhoHi,
            language: nil,
            summaryMax: ContextBudget.derived(B: snapshot.B).summaryMax,
            previousCheckpointText: previous?.text,
            previousSummary: previous?.summary,
            span: spanMessages
        ))
        guard request.shape != .tooLarge else { return .tooLarge }

        var outputs: [String?] = []
        var result: ContextCompactor.CompactResult?
        for _ in 0..<ContextCompactor.maxSummaryAttempts {
            guard let output = await cancellableSummary(
                conversationId: conversationId, request: request, summarize: summarize
            ) else { return .cancelled }
            outputs.append(output)
            let attempt = ContextCompactor.compact(ContextCompactor.CompactInput(
                conversationId: conversationId,
                B: snapshot.B,
                rhoHi: snapshot.rhoHi,
                messages: snapshot.messages,
                previous: previous.map { ContextCompactor.Previous(coversTo: $0.coversTo, summary: $0.summary) },
                summaryOutputs: outputs
            ))
            result = attempt
            if attempt.outcome != .fallback { break }
        }
        guard let result else { return .noop }
        switch result.outcome {
        case .noop:
            return .noop
        case .fallback:
            apply(.llmFailure, conversationId: conversationId)
            return .failed(result.failures)
        case .summary:
            apply(.llmSuccess, conversationId: conversationId)
            guard let coversFrom = result.coversFrom, let coversTo = result.coversTo,
                  let checkpointId = result.checkpointId, let digest = result.coversDigest, let text = result.text,
                  let messagesCovered = result.messagesCovered
            else { return .noop }
            return .summary(ContextCheckpointRecord(
                conversationId: conversationId,
                checkpointId: checkpointId,
                kind: .summary,
                coversFrom: coversFrom,
                coversTo: coversTo,
                coversDigest: digest,
                messagesCovered: messagesCovered,
                userMessageIds: result.keptUserIds ?? [],
                text: text,
                summary: (outputs.last ?? nil).map(Self.trimmedSummary),
                language: nil,
                model: snapshot.model,
                packerVersion: ContextCheckpoint.packerVersion,
                createdAt: nowMillis(),
                cost: nil
            ))
        }
    }

    /// Deterministic fallback; without checkpointText it is a noop. coversTo = the message before the first tail message.
    private func fallbackRow(
        conversationId: String,
        snapshot: ContextCompactionSnapshot,
        previous: ContextCheckpointRecord?
    ) -> ContextCheckpointRecord? {
        let messages = snapshot.messages
        let fallback = ContextCheckpoint.fallback(
            messages: messages,
            B: snapshot.B,
            rhoHi: snapshot.rhoHi,
            fixedTokens: snapshot.fixedTokens,
            oldSummary: previous?.summary
        )
        guard let text = fallback.checkpointText, let first = messages.first else { return nil }
        let tailStart = fallback.tailStartId.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count
        guard tailStart > 0 else { return nil }
        let lastIndex = tailStart - 1
        let coversTo = messages[lastIndex].id
        return ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: ContextCheckpoint.checkpointId(conversationId: conversationId, coversTo: coversTo),
            kind: .fallback,
            coversFrom: first.id,
            coversTo: coversTo,
            coversDigest: ContextCheckpoint.coversDigest(
                messages[0...lastIndex].map { .init(id: $0.id, text: $0.text ?? "") }
            ),
            messagesCovered: lastIndex + 1,
            userMessageIds: fallback.keptUserIds,
            text: text,
            summary: previous?.summary,
            language: nil,
            model: snapshot.model,
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: nowMillis(),
            cost: nil
        )
    }

    /// Persist: if sync is bound, hand out the row and all local checkpointIds of this conversation. A persistence failure is only logged and returns nil.
    private func persist(_ row: ContextCheckpointRecord) -> ContextCheckpointRecord? {
        do {
            try store.save(row)
        } catch {
            print("[ContextCompactionCoordinator] save failed: \(error.localizedDescription)")
            return nil
        }
        if let upload {
            let ids = (try? store.list(conversationId: row.conversationId).map(\.checkpointId)) ?? [row.checkpointId]
            upload(row, ids)
        }
        return row
    }

    /// The summary column stores the trimmed summary: the same rule as ContextCheckpoint.serialize (ContextSanitizer.unicodeWhiteSpace).
    private static let summaryWhiteSpace: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: Unicode.Scalar(0x0009)! ... Unicode.Scalar(0x000D)!)
        set.insert(charactersIn: Unicode.Scalar(0x2000)! ... Unicode.Scalar(0x200A)!)
        for value: UInt32 in [0x0020, 0x0085, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000] {
            set.insert(Unicode.Scalar(value)!)
        }
        return set
    }()

    private static func trimmedSummary(_ text: String) -> String {
        text.trimmingCharacters(in: summaryWhiteSpace)
    }

    private func nowMillis() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
    }
}
