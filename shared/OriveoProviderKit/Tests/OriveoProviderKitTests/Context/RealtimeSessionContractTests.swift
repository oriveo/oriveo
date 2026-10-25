import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/realtime-session.v1.json` case by case: inputs are mapped to RealtimeSessionInput, run through the production
// ContextAssembler.assembleRealtimeSession to get a RealtimeSessionPlan, and every field of expected is compared (strings byte for byte);
// fingerprintCases line up the fingerprints and shouldReopen of two plans. The test name is the fixture case id.

private struct RealtimeSessionContract: Decodable {
    struct Constants: Decodable {
        var deliveryRealtime: String
        var systemMaxCap: Int
        var attachmentPlaceholders: [String: String]
    }

    struct Note: Decodable {
        var title: String
        var text: String
    }

    struct Knowledge: Decodable {
        var name: String
        var text: String
    }

    struct Conversation: Decodable {
        var id: String
        var useMemory: Bool
        var skillPrompt: String?
        var instructions: String?
        var pinnedNotes: [Note]?
        var knowledgeFiles: [Knowledge]?
    }

    struct Scope: Decodable {
        var type: String
        var id: String?
    }

    struct MemoryItem: Decodable {
        var id: String
        var kind: String
        var content: String
        var pinned: Bool?
        var status: String?
        var layer: String?
        var scope: Scope?
    }

    struct Attachment: Decodable {
        var id: String
        var kind: String
    }

    struct Message: Decodable {
        var id: String
        var role: String
        var text: String
        var state: String
        var attachments: [Attachment]?
        var realtimeSessionId: String?
    }

    struct Input: Decodable {
        var contextWindow: Int?
        var rhoHi: Double?
        var conversation: Conversation
        var memoryItems: [MemoryItem]?
        var history: [Message]?
        var checkpoint: String?
        var reminderEnabled: Bool?
        var currentSessionId: String?
    }

    struct HistoryItem: Decodable, Equatable {
        var role: String
        var text: String
    }

    struct Fingerprint: Decodable, Equatable {
        var instructionsSha256: String
        var lastHistoryId: String?
    }

    struct Omitted: Decodable, Equatable {
        var knowledge: Int
        var notes: Int
        var memory: Int
        var history: Int
    }

    struct Budget: Decodable, Equatable {
        var B: Int
        var limit: Int
        var systemMax: Int
        var estimatedInstructions: Int
        var estimatedInjected: Int
    }

    struct Expected: Decodable {
        var reject: String?
        var instructions: String?
        var history: [HistoryItem]?
        var historyIds: [String?]?
        var fingerprint: Fingerprint?
        var segments: [String]?
        var omitted: Omitted?
        var memoryIds: [String]?
        var reminder: Bool?
        var budget: Budget?
    }

    struct Case: Decodable {
        var id: String
        var input: Input
        var expected: Expected
    }

    struct FingerprintInput: Decodable {
        var prev: Input
        var next: Input
    }

    struct FingerprintExpected: Decodable {
        var prev: Fingerprint
        var next: Fingerprint
        var reopen: Bool
    }

    struct FingerprintCase: Decodable {
        var id: String
        var input: FingerprintInput
        var expected: FingerprintExpected
    }

    var constants: Constants
    var cases: [Case]
    var fingerprintCases: [FingerprintCase]

    static func load() throws -> RealtimeSessionContract {
        try ContextContractFixture.load("realtime-session.v1.json")
    }

    static let caseIds: [String] = (try? load())?.cases.map(\.id) ?? []
    static let fingerprintCaseIds: [String] = (try? load())?.fingerprintCases.map(\.id) ?? []
}

private func realtimeInput(_ input: RealtimeSessionContract.Input, caseId: String) throws -> RealtimeSessionInput {
    let history = try (input.history ?? []).map { message in
        RealtimeSessionMessage(
            id: message.id,
            role: try #require(ContextMessageRole(rawValue: message.role), "\(caseId)"),
            text: message.text,
            state: try #require(ContextMessageState(rawValue: message.state), "\(caseId)"),
            attachments: try (message.attachments ?? []).map {
                ContextAttachmentRef(id: $0.id, kind: try #require(ContextAttachmentKind(rawValue: $0.kind), "\(caseId)"))
            },
            realtimeSessionId: message.realtimeSessionId
        )
    }
    let memoryItems = try (input.memoryItems ?? []).map { item in
        let scope: ContextMemoryScope? = try item.scope.map { scope in
            switch scope.type {
            case "global": return .global
            case "conversation": return .conversation(id: try #require(scope.id, "\(caseId)"))
            default:
                Issue.record("\(caseId): unknown scope \(scope.type)")
                return .global
            }
        }
        return ContextMemoryItem(
            id: item.id, kind: item.kind, content: item.content, pinned: item.pinned ?? false,
            status: item.status, layer: item.layer, scope: scope
        )
    }
    let conversation = input.conversation
    return RealtimeSessionInput(
        contextWindow: input.contextWindow,
        rhoHi: input.rhoHi ?? 0.5,
        conversation: ContextConversation(
            id: conversation.id,
            useMemory: conversation.useMemory,
            skillPrompt: conversation.skillPrompt,
            instructions: conversation.instructions,
            pinnedNotes: (conversation.pinnedNotes ?? []).map { ContextPinnedNote(title: $0.title, text: $0.text) },
            knowledgeFiles: (conversation.knowledgeFiles ?? []).map { ContextKnowledgeFile(name: $0.name, text: $0.text) }
        ),
        memoryItems: memoryItems,
        history: history,
        checkpoint: input.checkpoint,
        reminderEnabled: input.reminderEnabled ?? true,
        currentSessionId: input.currentSessionId
    )
}

private func fingerprint(_ value: RealtimeSessionFingerprint?) -> RealtimeSessionContract.Fingerprint? {
    value.map { .init(instructionsSha256: $0.instructionsSha256, lastHistoryId: $0.lastHistoryId) }
}

@Suite("RealtimeSessionContract")
struct RealtimeSessionContractTests {
    @Test("constants")
    func constantsMatchFixture() throws {
        let constants = try RealtimeSessionContract.load().constants
        #expect(ContextAssembler.deliveryRealtime == constants.deliveryRealtime)
        for kind in [ContextAttachmentKind.image, .file, .video, .audio] {
            #expect(ContextAssembler.realtimeAttachmentPlaceholder(kind) == constants.attachmentPlaceholders[kind.rawValue])
        }
        #expect(ContextAssembler.realtimeAttachmentPlaceholder(rawKind: "sticker") == constants.attachmentPlaceholders["file"])
        #expect(RequestPurpose(rawValue: "realtimeSession") == .realtimeSession)
    }

    @Test(arguments: RealtimeSessionContract.caseIds)
    func realtimeSessionCase(_ caseId: String) throws {
        let contract = try RealtimeSessionContract.load()
        let item = try #require(contract.cases.first { $0.id == caseId })
        let plan = ContextAssembler.assembleRealtimeSession(try realtimeInput(item.input, caseId: caseId))
        let expected = item.expected

        #expect(plan.reject?.rawValue == expected.reject, "\(caseId) reject")
        #expect(plan.instructions == expected.instructions, "\(caseId) instructions")
        #expect(
            plan.history?.map { RealtimeSessionContract.HistoryItem(role: $0.role.rawValue, text: $0.text) } == expected.history,
            "\(caseId) history"
        )
        #expect(fingerprint(plan.fingerprint) == expected.fingerprint, "\(caseId) fingerprint")
        guard expected.reject == nil else { return }

        #expect(plan.history?.map(\.id) == expected.historyIds, "\(caseId) historyIds")
        #expect(plan.segments.map(\.rawValue) == expected.segments, "\(caseId) segments")
        #expect(
            RealtimeSessionContract.Omitted(
                knowledge: plan.omitted.knowledge, notes: plan.omitted.notes,
                memory: plan.omitted.memory, history: plan.omitted.history
            ) == expected.omitted,
            "\(caseId) omitted"
        )
        #expect(plan.memoryIds == expected.memoryIds, "\(caseId) memoryIds")
        #expect(plan.reminder == expected.reminder, "\(caseId) reminder")
        #expect(
            plan.budget.map {
                RealtimeSessionContract.Budget(
                    B: $0.B, limit: $0.limit, systemMax: $0.systemMax,
                    estimatedInstructions: $0.estimatedInstructions, estimatedInjected: $0.estimatedInjected
                )
            } == expected.budget,
            "\(caseId) budget"
        )
    }

    @Test(arguments: RealtimeSessionContract.fingerprintCaseIds)
    func fingerprintCase(_ caseId: String) throws {
        let contract = try RealtimeSessionContract.load()
        let item = try #require(contract.fingerprintCases.first { $0.id == caseId })
        let prev = ContextAssembler.assembleRealtimeSession(try realtimeInput(item.input.prev, caseId: caseId))
        let next = ContextAssembler.assembleRealtimeSession(try realtimeInput(item.input.next, caseId: caseId))
        #expect(fingerprint(prev.fingerprint) == item.expected.prev, "\(caseId) prev")
        #expect(fingerprint(next.fingerprint) == item.expected.next, "\(caseId) next")
        let prevFingerprint = try #require(prev.fingerprint, "\(caseId)")
        let nextFingerprint = try #require(next.fingerprint, "\(caseId)")
        #expect(ContextAssembler.shouldReopen(prevFingerprint, nextFingerprint) == item.expected.reopen, "\(caseId) reopen")
    }
}
