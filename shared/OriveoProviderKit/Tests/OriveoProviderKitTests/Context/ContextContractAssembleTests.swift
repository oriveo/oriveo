import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/assemble.v1.json` case by case: inputs are mapped to ContextAssembleInput, run through the production
// ContextAssembler.assemble to get a ContextPlan, converted to a JSON shape, and every key that appears in expected is compared
// (system and block text byte for byte); the test name is the fixture case id.

/// Generic JSON value for the fixture expected; only keys that appear in expected are compared.
private indirect enum JSONValue: Decodable, Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var description: String {
        switch self {
        case .null: "null"
        case .bool(let value): "\(value)"
        case .number(let value): "\(value)"
        case .string(let value): "\"\(value)\""
        case .array(let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .object(let fields):
            "{" + fields.keys.sorted().map { "\($0): \(fields[$0]!.description)" }.joined(separator: ", ") + "}"
        }
    }

    static func int(_ value: Int?) -> JSONValue {
        value.map { .number(Double($0)) } ?? .null
    }

    static func text(_ value: String?) -> JSONValue {
        value.map { .string($0) } ?? .null
    }
}

/// expected is a subset of actual: objects compare only the keys expected has; arrays item by item; when expected writes a string in segments, only kind is compared.
private func subsetMismatch(expected: JSONValue, actual: JSONValue, path: String) -> String? {
    switch (expected, actual) {
    case (.object(let expectedFields), .object(let actualFields)):
        for key in expectedFields.keys.sorted() {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            guard let actualValue = actualFields[key] else { return "\(childPath): missing" }
            if let mismatch = subsetMismatch(expected: expectedFields[key]!, actual: actualValue, path: childPath) {
                return mismatch
            }
        }
        return nil
    case (.array(let expectedItems), .array(let actualItems)):
        guard expectedItems.count == actualItems.count else {
            return "\(path): count \(actualItems.count) != \(expectedItems.count) actual \(actual)"
        }
        for (index, (expectedItem, actualItem)) in zip(expectedItems, actualItems).enumerated() {
            if let mismatch = subsetMismatch(expected: expectedItem, actual: actualItem, path: "\(path)[\(index)]") {
                return mismatch
            }
        }
        return nil
    case (.string, .object(let actualFields)) where path.hasPrefix("segments"):
        return subsetMismatch(expected: expected, actual: actualFields["kind"] ?? .null, path: "\(path).kind")
    case (.string(let expectedText), .string(let actualText)):
        return Array(expectedText.utf8) == Array(actualText.utf8) ? nil : "\(path): \(actual) != \(expected)"
    default:
        return expected == actual ? nil : "\(path): \(actual) != \(expected)"
    }
}

private func planJSON(_ plan: ContextPlan) -> JSONValue {
    let messages: JSONValue = plan.messages.map { messages in
        .array(messages.map { message in
            .object([
                "id": .string(message.id),
                "role": .string(message.role.rawValue),
                "blocks": .array(message.blocks.map { block in
                    .object(["kind": .string(block.kind.rawValue), "text": .string(block.text)])
                }),
                "attachments": .array(message.attachments.map { .string($0.id) }),
            ])
        })
    } ?? .null
    let segments: JSONValue = .array(plan.segments.map { segment in
        var fields: [String: JSONValue] = [
            "kind": .string(segment.kind.rawValue),
            "tokens": .int(segment.tokens),
        ]
        if let items = segment.items { fields["items"] = .int(items) }
        if let omitted = segment.omitted { fields["omitted"] = .int(omitted) }
        return .object(fields)
    })
    return .object([
        "system": .text(plan.system),
        "messages": messages,
        "segments": segments,
        "omitted": .object([
            "knowledge": .int(plan.omitted.knowledge),
            "notes": .int(plan.omitted.notes),
            "memory": .int(plan.omitted.memory),
        ]),
        "reminder": .bool(plan.reminder),
        "unansweredMerged": .int(plan.unansweredMerged),
        "budget": .object([
            "W": .int(plan.budget.W),
            "B": .int(plan.budget.B),
            "oWire": .int(plan.budget.oWire),
            "estimatedInput": .int(plan.budget.estimatedInput),
        ]),
        "compaction": .string(plan.compaction.rawValue),
        "warnings": .array(plan.warnings.map { .string($0.rawValue) }),
        "reject": .text(plan.reject?.rawValue),
        "imagePrompt": .text(plan.imagePrompt),
        "memoryIds": .array(plan.memoryIds.map { .string($0) }),
    ])
}

private struct AssembleContract: Decodable {
    struct Constants: Decodable {
        var instructionsHeader: String
        var reminderPointer: String
        var continuePrompt: String
        var reminderFullTextMaxTokens: Int
        var reminderMinUserMessages: Int
        var libraryEmptyEntry: String
        var deliveryVoice: String
        var notes: [String: String]
    }

    struct Window: Decodable {
        var W: Int?
        var windowKind: String
        var maxOutput: Int
    }

    struct Note: Decodable {
        var title: String
        var text: String
    }

    struct KnowledgeFile: Decodable {
        var name: String
        var text: String
    }

    struct Conversation: Decodable {
        var id: String
        var useMemory: Bool
        var skillPrompt: String?
        var instructions: String?
        var pinnedNotes: [Note]?
        var knowledgeFiles: [KnowledgeFile]?
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

    struct Message: Decodable {
        var id: String
        var role: String
        var text: String
        var state: String
    }

    struct LibraryEntry: Decodable {
        var citation: Int?
        var title: String?
        var truncated: Bool
        var text: String
    }

    struct RecallEntry: Decodable {
        var id: String
        var text: String
        var date: String?
    }

    struct Dynamic: Decodable {
        var recall: [RecallEntry]?
        var library: [LibraryEntry]?
        var attachmentGuide: String?
        var delivery: String?
    }

    struct Input: Decodable {
        var purpose: String
        var window: Window
        var rhoHi: Double?
        var conversation: Conversation
        var memoryItems: [MemoryItem]?
        var toolSafety: String?
        var purposeSystem: String?
        var history: [Message]
        var current: String?
        var dynamic: Dynamic?
        var reminderEnabled: Bool?
        var checkpoint: String?
    }

    struct Case: Decodable {
        var id: String
        var input: Input
        var expected: JSONValue
    }

    var constants: Constants
    var cases: [Case]

    static func load() throws -> AssembleContract {
        try ContextContractFixture.load("assemble.v1.json")
    }

    static let caseIds: [String] = (try? load())?.cases.map(\.id) ?? []
}

private func assembleInput(_ input: AssembleContract.Input, caseId: String) throws -> ContextAssembleInput {
    let purpose = try #require(RequestPurpose(rawValue: input.purpose), "\(caseId)")
    let windowKind = try #require(ContextWindowKind(rawValue: input.window.windowKind), "\(caseId)")
    let history = try input.history.map { message in
        ContextMessage(
            id: message.id,
            role: try #require(ContextMessageRole(rawValue: message.role), "\(caseId)"),
            text: message.text,
            state: try #require(ContextMessageState(rawValue: message.state), "\(caseId)")
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
            id: item.id,
            kind: item.kind,
            content: item.content,
            pinned: item.pinned ?? false,
            status: item.status,
            layer: item.layer,
            scope: scope
        )
    }
    let conversation = input.conversation
    return ContextAssembleInput(
        purpose: purpose,
        window: ContextWindowInput(
            W: input.window.W,
            windowKind: windowKind,
            maxOutput: ContextMaxOutputSources(model: input.window.maxOutput)
        ),
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
        toolSafety: input.toolSafety,
        purposeSystem: input.purposeSystem,
        history: history,
        current: input.current,
        dynamic: input.dynamic.map {
            ContextDynamicInput(
                recall: ($0.recall ?? []).map { ContextRecallEntry(id: $0.id, text: $0.text, date: $0.date) },
                library: $0.library?.map {
                    ContextLibraryEntry(citation: $0.citation, title: $0.title, truncated: $0.truncated, text: $0.text)
                },
                attachmentGuide: $0.attachmentGuide,
                delivery: $0.delivery.flatMap(ContextDelivery.init(rawValue:))
            )
        },
        reminderEnabled: input.reminderEnabled ?? true,
        checkpoint: input.checkpoint
    )
}

@Suite("ContextContractAssemble")
struct ContextContractAssembleTests {
    @Test("constants")
    func constants() throws {
        let constants = try AssembleContract.load().constants
        #expect(AssembleContract.caseIds.count == 47)
        #expect(ContextAssembler.instructionsHeader == constants.instructionsHeader)
        #expect(ContextAssembler.reminderPointer == constants.reminderPointer)
        #expect(ContextAssembler.continuePrompt == constants.continuePrompt)
        #expect(ContextAssembler.reminderFullTextMaxTokens == constants.reminderFullTextMaxTokens)
        #expect(ContextAssembler.reminderMinUserMessages == constants.reminderMinUserMessages)
        #expect(ContextAssembler.libraryEmptyEntry == constants.libraryEmptyEntry)
        #expect(ContextAssembler.deliveryVoice == constants.deliveryVoice)
        #expect(ContextAssembler.envelopeNotes == constants.notes)
        #expect(ContextAssembler.envelopeNotes[ContextSanitizer.unansweredTag] == ContextSanitizer.unansweredNote)
    }

    @Test(arguments: AssembleContract.caseIds)
    func assembleCase(_ caseId: String) throws {
        let contract = try AssembleContract.load()
        let item = try #require(contract.cases.first { $0.id == caseId })
        let plan = ContextAssembler.assemble(try assembleInput(item.input, caseId: caseId))
        let mismatch = subsetMismatch(expected: item.expected, actual: planJSON(plan), path: "")
        #expect(mismatch == nil, "\(caseId): \(mismatch ?? "")")
    }
}
