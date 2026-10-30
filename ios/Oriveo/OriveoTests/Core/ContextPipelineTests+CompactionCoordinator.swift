import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Compaction coordinator: choosing the mode, calling the summary, falling back, persisting, and uploading.
/// The summary and upload are injected as closures; assertions read the rows the coordinator actually writes into the context_checkpoint table.
extension ContextPipelineTests {

    /// B = 20000 -> tail 5000, summaryMax 1000; each message is 1500 tokens, so with 10 messages the tail starts at m8 and span = m0...m7.
    private static let compactionB = 20_000
    private static let compactionRhoHi = 0.25
    private static let compactionModel = "relay-model"
    private static let validCheckpointSummary = ContextCheckpoint.headings
        .map { "## \($0)\n(none)" }
        .joined(separator: "\n")

    private final class CompactionProbe {
        var aiEnabled = true
        var remoteEnabled = true
        var outputs: [String?] = []
        var requests: [ContextCompactor.SummaryRequest] = []
        var uploads: [(row: ContextCheckpointRecord, ids: [String])] = []
        var messages: [ContextCheckpoint.Message] = []
        var U = 200_000
    }

    private static func compactionMessages(_ count: Int) -> [ContextCheckpoint.Message] {
        (0..<count).map { index in
            ContextCheckpoint.Message(
                id: "m\(index)", role: index % 2 == 0 ? .user : .assistant, estTokens: 1500, text: "text \(index)"
            )
        }
    }

    private static func covered(_ messages: [ContextCheckpoint.Message], through id: String) -> String {
        let index = messages.firstIndex { $0.id == id } ?? (messages.count - 1)
        return ContextCheckpoint.coversDigest(messages[0...index].map { .init(id: $0.id, text: $0.text ?? "") })
    }

    private func makeCompactionCoordinator(
        _ probe: CompactionProbe,
        store: ContextCompactionStore,
        bound: Bool = false
    ) -> ContextCompactionCoordinator {
        ContextCompactionCoordinator(
            store: store,
            aiSummaryEnabled: { probe.aiEnabled },
            remoteCompactionEnabled: { probe.remoteEnabled },
            snapshot: { _ in
                ContextCompactionSnapshot(
                    messages: probe.messages,
                    B: Self.compactionB,
                    U: probe.U,
                    rhoHi: Self.compactionRhoHi,
                    prefixTokens: 0,
                    fixedTokens: 0,
                    model: Self.compactionModel
                )
            },
            summarize: { _, request in
                probe.requests.append(request)
                return probe.outputs.isEmpty ? nil : probe.outputs.removeFirst()
            },
            upload: bound ? { row, ids in probe.uploads.append((row, ids)) } : nil
        )
    }

    // MARK: Cases

    @Test func coordinator_fallback_mode_saves_fallback_row() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        probe.aiEnabled = false
        probe.messages = Self.compactionMessages(10)
        let coordinator = makeCompactionCoordinator(probe, store: store)

        let result = await coordinator.compact(conversationId: conversation, trigger: .preSend)

        #expect(probe.requests.isEmpty)
        #expect(result.outcome == .fallback)
        let row = try #require(result.row)
        let expected = ContextCheckpoint.fallback(
            messages: probe.messages, B: Self.compactionB, rhoHi: Self.compactionRhoHi, fixedTokens: 0
        )
        #expect(row.kind == .fallback)
        #expect(row.coversFrom == "m0")
        #expect(row.coversTo == "m7")
        #expect(row.messagesCovered == 8)
        #expect(row.userMessageIds == ["m0", "m2", "m4", "m6"])
        #expect(row.text == expected.checkpointText)
        #expect(row.summary == nil)
        #expect(row.language == nil)
        #expect(row.cost == nil)
        #expect(row.model == Self.compactionModel)
        #expect(row.packerVersion == ContextCheckpoint.packerVersion)
        #expect(row.checkpointId == ContextCheckpoint.checkpointId(conversationId: conversation, coversTo: "m7"))
        #expect(row.coversDigest == Self.covered(probe.messages, through: "m7"))
        #expect(try store.list(conversationId: conversation) == [row])
    }

    @Test func coordinator_ai_mode_saves_summary_row() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        probe.messages = Self.compactionMessages(10)
        probe.outputs = [Self.validCheckpointSummary]
        let coordinator = makeCompactionCoordinator(probe, store: store)

        let result = await coordinator.compact(conversationId: conversation, trigger: .preSend)

        #expect(probe.requests.count == 1)
        #expect(probe.requests.first?.shape == .appended)
        #expect(probe.requests.first?.maxOutputTokens == ContextBudget.derived(B: Self.compactionB).summaryMax)
        #expect(result.outcome == .summary)
        #expect(result.failures.isEmpty)
        let row = try #require(result.row)
        #expect(row.kind == .summary)
        #expect(row.summary == Self.validCheckpointSummary)
        #expect(row.userMessageIds == ["m0", "m2", "m4", "m6"])
        let kept = row.userMessageIds.map { id in
            ContextCheckpoint.KeptMessage(id: id, text: "text \(id.dropFirst())", truncated: false)
        }
        #expect(row.text == ContextCheckpoint.serialize(
            coversFrom: "m0", coversTo: "m7", messagesCovered: 8, kept: kept, summary: Self.validCheckpointSummary
        ))
        #expect(row.coversFrom == "m0")
        #expect(row.coversTo == "m7")
        #expect(row.messagesCovered == 8)
        #expect(row.language == nil)
        #expect(row.cost == nil)
        #expect(row.model == Self.compactionModel)
        #expect(row.checkpointId == ContextCheckpoint.checkpointId(conversationId: conversation, coversTo: "m7"))
        #expect(row.coversDigest == Self.covered(probe.messages, through: "m7"))
        #expect(try store.list(conversationId: conversation) == [row])
        #expect(coordinator.breakerState(conversationId: conversation).failures == 0)
    }

    /// When persistence fails (the conversation is not in the database and the foreign key rejects the write), both the summary and fallback paths return noop, write no row, and do not upload.
    @Test func coordinator_save_failure_returns_no_row() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let missingConversation = UUID().uuidString

        let summaryProbe = CompactionProbe()
        summaryProbe.messages = Self.compactionMessages(10)
        summaryProbe.outputs = [Self.validCheckpointSummary]
        let summaryCoordinator = makeCompactionCoordinator(summaryProbe, store: store, bound: true)
        let summary = await summaryCoordinator.compact(conversationId: missingConversation, trigger: .preSend)
        #expect(summaryProbe.requests.count == 1)
        #expect(summary.outcome == .noop)
        #expect(summary.row == nil)
        #expect(summary.failures.isEmpty)
        #expect(summaryProbe.uploads.isEmpty)

        let fallbackProbe = CompactionProbe()
        fallbackProbe.messages = Self.compactionMessages(10)
        fallbackProbe.outputs = ["not a checkpoint", nil]
        let fallbackCoordinator = makeCompactionCoordinator(fallbackProbe, store: store, bound: true)
        let fallback = await fallbackCoordinator.compact(conversationId: missingConversation, trigger: .preSend)
        #expect(fallbackProbe.requests.count == 2)
        #expect(fallback.outcome == .noop)
        #expect(fallback.row == nil)
        #expect(fallback.failures == [[.headings], [.callError]])
        #expect(fallbackProbe.uploads.isEmpty)

        #expect(try store.list(conversationId: missingConversation).isEmpty)
    }

    @Test func coordinator_invalid_twice_falls_back_and_counts_failure() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        probe.messages = Self.compactionMessages(10)
        probe.outputs = ["not a checkpoint", nil]
        let coordinator = makeCompactionCoordinator(probe, store: store)

        let result = await coordinator.compact(conversationId: conversation, trigger: .preSend)

        #expect(probe.requests.count == 2)
        #expect(result.outcome == .fallback)
        #expect(result.failures == [[.headings], [.callError]])
        #expect(result.row?.kind == .fallback)
        #expect(try store.list(conversationId: conversation).map(\.kind) == [.fallback])
        let breaker = coordinator.breakerState(conversationId: conversation)
        #expect(breaker.failures == 1)
        #expect(breaker.mode == .llm)
    }

    @Test func coordinator_two_failed_compactions_trip_breaker() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let other = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        let coordinator = makeCompactionCoordinator(probe, store: store)

        probe.messages = Self.compactionMessages(10)
        probe.outputs = ["bad", "bad"]
        _ = await coordinator.compact(conversationId: conversation, trigger: .preSend)
        probe.messages = Self.compactionMessages(14)
        probe.outputs = ["bad", "bad"]
        _ = await coordinator.compact(conversationId: conversation, trigger: .overflow)
        #expect(probe.requests.count == 4)
        #expect(coordinator.breakerState(conversationId: conversation).mode == .fallbackOnly)

        probe.messages = Self.compactionMessages(18)
        probe.outputs = [Self.validCheckpointSummary]
        let tripped = await coordinator.compact(conversationId: conversation, trigger: .preSend)
        #expect(probe.requests.count == 4)
        #expect(tripped.outcome == .fallback)

        // The circuit breaker is per conversation: another conversation still uses AI.
        let elsewhere = await coordinator.compact(conversationId: other, trigger: .preSend)
        #expect(probe.requests.count == 5)
        #expect(elsewhere.outcome == .summary)

        // Recovers after fallbackTurns turns; retry resets it immediately.
        for _ in 0..<ContextCompactionBreaker.fallbackTurns {
            coordinator.recordTurn(conversationId: conversation)
        }
        #expect(coordinator.breakerState(conversationId: conversation).mode == .llm)
        probe.messages = Self.compactionMessages(22)
        probe.outputs = ["bad", "bad"]
        _ = await coordinator.compact(conversationId: conversation, trigger: .preSend)
        coordinator.retry(conversationId: conversation)
        #expect(coordinator.breakerState(conversationId: conversation).failures == 0)
    }

    @Test func coordinator_too_large_falls_back_without_failure() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        probe.messages = Self.compactionMessages(10)
        probe.outputs = [Self.validCheckpointSummary]
        probe.U = 100
        let coordinator = makeCompactionCoordinator(probe, store: store)

        let result = await coordinator.compact(conversationId: conversation, trigger: .preSend)

        #expect(probe.requests.isEmpty)
        #expect(result.outcome == .fallback)
        #expect(result.failures.isEmpty)
        #expect(result.row?.kind == .fallback)
        #expect(coordinator.breakerState(conversationId: conversation).failures == 0)
    }

    @Test func coordinator_remote_flag_off_forces_fallback() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        probe.remoteEnabled = false
        probe.messages = Self.compactionMessages(10)
        probe.outputs = [Self.validCheckpointSummary]
        let coordinator = makeCompactionCoordinator(probe, store: store)

        let manual = await coordinator.compact(conversationId: conversation, trigger: .manual)

        #expect(probe.requests.isEmpty)
        #expect(manual.outcome == .fallback)
        #expect(manual.row?.kind == .fallback)
    }

    @Test func coordinator_manual_ignores_pref_and_breaker() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        let coordinator = makeCompactionCoordinator(probe, store: store)
        probe.messages = Self.compactionMessages(10)
        probe.outputs = ["bad", "bad"]
        _ = await coordinator.compact(conversationId: conversation, trigger: .preSend)
        probe.messages = Self.compactionMessages(14)
        probe.outputs = ["bad", "bad"]
        _ = await coordinator.compact(conversationId: conversation, trigger: .preSend)
        #expect(coordinator.breakerState(conversationId: conversation).mode == .fallbackOnly)

        probe.aiEnabled = false
        probe.messages = Self.compactionMessages(18)
        probe.outputs = [Self.validCheckpointSummary]
        let manual = await coordinator.compact(conversationId: conversation, trigger: .manual)

        #expect(probe.requests.count == 5)
        #expect(manual.outcome == .summary)
        #expect(manual.row?.kind == .summary)
    }

    @Test func coordinator_incremental_passes_previous_summary() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        let coordinator = makeCompactionCoordinator(probe, store: store)
        probe.messages = Self.compactionMessages(10)
        probe.outputs = [Self.validCheckpointSummary]
        let first = try #require(await coordinator.compact(conversationId: conversation, trigger: .preSend).row)

        let secondSummary = Self.validCheckpointSummary.replacingOccurrences(of: "(none)", with: "(later)")
        probe.messages = Self.compactionMessages(14)
        probe.outputs = [secondSummary]
        let second = await coordinator.compact(conversationId: conversation, trigger: .preSend)

        #expect(probe.requests.count == 2)
        let request = try #require(probe.requests.last)
        #expect(request.messages.first?.text.hasPrefix(first.text) == true)
        #expect(request.messages.first?.text.contains("text 8") == true)
        let row = try #require(second.row)
        #expect(second.outcome == .summary)
        #expect(row.coversFrom == "m0")
        #expect(row.coversTo == "m11")
        #expect(row.messagesCovered == 12)
        #expect(row.summary == secondSummary)
        #expect(try store.list(conversationId: conversation).map(\.checkpointId) == [first.checkpointId, row.checkpointId])
    }

    @Test func coordinator_saved_row_uploads_when_bound() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        probe.aiEnabled = false

        let unbound = makeCompactionCoordinator(probe, store: store, bound: false)
        probe.messages = Self.compactionMessages(10)
        let first = try #require(await unbound.compact(conversationId: conversation, trigger: .preSend).row)
        #expect(probe.uploads.isEmpty)

        let bound = makeCompactionCoordinator(probe, store: store, bound: true)
        probe.messages = Self.compactionMessages(14)
        let second = try #require(await bound.compact(conversationId: conversation, trigger: .preSend).row)

        #expect(probe.uploads.count == 1)
        #expect(probe.uploads.first?.row == second)
        #expect(Set(probe.uploads.first?.ids ?? []) == Set([first.checkpointId, second.checkpointId]))
        #expect(try store.list(conversationId: conversation).map(\.checkpointId) == probe.uploads.first?.ids)
    }

    /// The send path marks user messages offered as compaction candidates with isDirective via the recognizer (through the production ChatRequestBuilder.build path).
    @Test func compaction_inputs_mark_directives() throws {
        let directive = TestFactories.makeMessage(role: .user, text: "From now on, reply in English.")
        let plain = TestFactories.makeMessage(role: .user, text: "Tell me about the history of Rome.")
        let messages = [
            directive,
            TestFactories.makeMessage(role: .assistant, text: "Sure."),
            plain,
            TestFactories.makeMessage(role: .assistant, text: "Rome was founded long ago."),
            TestFactories.makeMessage(role: .user, text: "Continue."),
        ]
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let assembly = ChatRequestAssemblyContext(
            window: ContextWindowInput(W: nil, windowKind: .total, maxOutput: ContextMaxOutputSources()),
            rhoHi: Self.compactionRhoHi,
            overflowFallbackB: Self.compactionB,
            overflowCompactionInputs: true
        )

        let inputs = try #require(ChatRequestBuilder.build(from: snapshot, assembly: assembly).compactionInputs)

        let byId = Dictionary(uniqueKeysWithValues: inputs.messages.map { ($0.id, $0) })
        #expect(byId[directive.id.uuidString]?.isDirective == true)
        #expect(byId[plain.id.uuidString]?.isDirective == false)
        #expect(inputs.messages.filter { $0.role == .assistant }.allSatisfy { !$0.isDirective })
    }

    /// With manual compaction (compactionStopsAtMedia) the compaction snapshot is cut before the first message that carries media;
    /// that message and everything after it are kept as is and counted into fixedTokens; with no media it is the same snapshot as before (through the production path ChatRequestBuilder.build).
    @Test func manual_compaction_inputs_stop_before_first_media_message() throws {
        let image = Attachment(
            id: UUID(), kind: .image, fileName: "chart.png", mimeType: "image/png", base64Data: "aW1hZ2U="
        )
        var withImage = TestFactories.makeMessage(role: .user, text: "Look at this chart.")
        withImage.attachments = [image]
        let before = [
            TestFactories.makeMessage(role: .user, text: "Tell me about the history of Rome."),
            TestFactories.makeMessage(role: .assistant, text: "Rome was founded long ago."),
        ]
        let after = [
            withImage,
            TestFactories.makeMessage(role: .assistant, text: "The chart shows growth."),
            TestFactories.makeMessage(role: .user, text: "Explain more."),
            TestFactories.makeMessage(role: .assistant, text: "Growth came from trade."),
            TestFactories.makeMessage(role: .user, text: "Continue."),
        ]
        func inputs(_ messages: [ChatMessage], stopsAtMedia: Bool) throws -> ChatCompactionInputs {
            let snapshot = ChatRequestSnapshot(
                conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
                messages: messages,
                preferences: ChatRequestPreferencesSnapshot(),
                skill: nil,
                sendPath: .send(excludingMessageID: nil)
            )
            let assembly = ChatRequestAssemblyContext(
                window: ContextWindowInput(W: nil, windowKind: .total, maxOutput: ContextMaxOutputSources()),
                rhoHi: Self.compactionRhoHi,
                overflowFallbackB: Self.compactionB,
                overflowCompactionInputs: true,
                compactionStopsAtMedia: stopsAtMedia
            )
            return try #require(ChatRequestBuilder.build(from: snapshot, assembly: assembly).compactionInputs)
        }

        let all = try inputs(before + after, stopsAtMedia: false)
        let manual = try inputs(before + after, stopsAtMedia: true)
        // The current message (the last user) is not part of the history; the pre-change snapshot includes the image message and the history after it.
        #expect(all.messages.map(\.id) == (before + after.dropLast()).map(\.id.uuidString))
        #expect(all.attachments[withImage.id.uuidString]?.first?.kind == .image)
        // Manual compaction: only what precedes the image message becomes a summary candidate; the image message and everything after it are kept as is.
        #expect(manual.messages.map(\.id) == before.map(\.id.uuidString))
        #expect(manual.attachments.isEmpty)
        let keptTokens = all.messages.dropFirst(before.count).reduce(0) { $0 + $1.estTokens }
        #expect(keptTokens > 0)
        #expect(manual.fixedTokens == all.fixedTokens + keptTokens)

        // No media: both modes yield the same snapshot.
        let plain = before + after.dropFirst()
        let plainAll = try inputs(plain, stopsAtMedia: false)
        let plainManual = try inputs(plain, stopsAtMedia: true)
        #expect(plainManual.messages.map(\.id) == plainAll.messages.map(\.id))
        #expect(plainManual.fixedTokens == plainAll.fixedTokens)
    }

    /// "Media" includes files carrying raw data (sent natively); files injected as plain text do not count and can still go into the summary.
    @Test func manual_compaction_media_counts_native_files_only() throws {
        func file(native: Bool) -> Oriveo.Attachment {
            Oriveo.Attachment(
                id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
                base64Data: Data("extracted".utf8).base64EncodedString(),
                originalBase64Data: native ? "JVBERi0=" : nil
            )
        }
        var textFile = TestFactories.makeMessage(role: .user, text: "Read these notes.")
        textFile.attachments = [file(native: false)]
        var nativeFile = TestFactories.makeMessage(role: .user, text: "Read this PDF.")
        nativeFile.attachments = [file(native: true)]
        let messages = [
            textFile,
            TestFactories.makeMessage(role: .assistant, text: "Noted."),
            nativeFile,
            TestFactories.makeMessage(role: .assistant, text: "The PDF covers revenue."),
            TestFactories.makeMessage(role: .user, text: "Continue."),
        ]
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let assembly = ChatRequestAssemblyContext(
            window: ContextWindowInput(W: nil, windowKind: .total, maxOutput: ContextMaxOutputSources()),
            rhoHi: Self.compactionRhoHi,
            overflowFallbackB: Self.compactionB,
            overflowCompactionInputs: true,
            compactionStopsAtMedia: true
        )
        let inputs = try #require(ChatRequestBuilder.build(from: snapshot, assembly: assembly).compactionInputs)
        #expect(inputs.messages.map(\.id) == messages.prefix(2).map(\.id.uuidString))
    }

    /// Send arrives one step late: the pre-compaction already finished and persisted its row after send assembly but before compact was called (it missed "wait for it").
    /// The caller did not use this row during assembly → hand it back directly for sending, without summarizing the same span again and without writing a second row.
    @Test func coordinator_pre_send_reuses_row_landed_after_assembly_without_waiting() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let probe = CompactionProbe()
        probe.messages = Self.compactionMessages(10)
        probe.outputs = [Self.validCheckpointSummary]
        let coordinator = makeCompactionCoordinator(probe, store: store)
        let landed = try #require(await coordinator.compact(conversationId: conversation, trigger: .preSend).row)

        var lateSummaries = 0
        let snapshot = ContextCompactionSnapshot(
            messages: probe.messages, B: Self.compactionB, U: probe.U, rhoHi: Self.compactionRhoHi,
            prefixTokens: 0, fixedTokens: 0, model: Self.compactionModel
        )
        let result = await coordinator.compact(
            conversationId: conversation,
            trigger: .preSend,
            snapshot: snapshot,
            assembledCheckpoint: .known(nil),
            summarize: { _ in
                lateSummaries += 1
                return Self.validCheckpointSummary
            }
        )

        #expect(lateSummaries == 0)
        #expect(result.outcome == .summary)
        #expect(result.row?.checkpointId == landed.checkpointId)
        #expect(try store.list(conversationId: conversation).count == 1)
    }
}
