import Foundation
import OriveoProviderKit
import Testing

// Cross-platform alignment decisions 12-17: the same answer on every platform where the fixture is silent; the test names align_12 ... align_17 are identical across platforms.

private func window(_ W: Int?, maxOutput: Int = 256) -> ContextWindowInput {
    ContextWindowInput(W: W, windowKind: .total, maxOutput: ContextMaxOutputSources(model: maxOutput))
}

private func message(_ id: String, _ role: ContextMessageRole, _ text: String,
                     _ state: ContextMessageState = .delivered,
                     attachments: [ContextAttachmentRef] = []) -> ContextMessage {
    ContextMessage(id: id, role: role, text: text, state: state, attachments: attachments)
}

@Suite("ContextContractAlignment")
struct ContextContractAlignmentTests {
    @Test("align_12")
    func align12CompactionOnlyForChatContinueToolLoop() {
        // W=2048 -> B=1792, sendCompactAt=1612; a 3300-byte history is about 1650 tokens, so chat must be required.
        let history = [message("u1", .user, String(repeating: "x", count: 3300)), message("a1", .assistant, "ok")]
        func plan(_ purpose: RequestPurpose) -> ContextPlan {
            ContextAssembler.assemble(ContextAssembleInput(
                purpose: purpose, window: window(2048), conversation: ContextConversation(id: "c1", useMemory: true),
                purposeSystem: "Review.", history: history, current: "Next"
            ))
        }
        #expect(plan(.chat).compaction == .required)
        #expect(plan(.continue).compaction == .required)
        #expect(plan(.toolLoopLeg).compaction == .required)
        #expect(plan(.compaction).compaction == .none)
        #expect(plan(.crosscheck).compaction == .none)
        #expect(plan(.memoryExtraction).compaction == .none)
        #expect(plan(.imageGeneration).compaction == .none)
    }

    @Test("align_13")
    func align13NoShrinkNoRejectOutsideFullSystemPurposes() {
        // W=1024 -> U=896; a 4000-byte current message is about 2000 tokens, so chat must be refused.
        let long = String(repeating: "m", count: 4000)
        let conversation = ContextConversation(
            id: "c1", useMemory: true,
            knowledgeFiles: [ContextKnowledgeFile(name: "k.md", text: String(repeating: "k", count: 4000))]
        )
        func plan(_ purpose: RequestPurpose) -> ContextPlan {
            ContextAssembler.assemble(ContextAssembleInput(
                purpose: purpose, window: window(1024, maxOutput: 128), conversation: conversation,
                purposeSystem: String(repeating: "s", count: 4000),
                history: [message("u1", .user, long)], current: long
            ))
        }
        #expect(plan(.chat).reject == .messageTooLong)
        #expect(plan(.chat).omitted.knowledge == 1)
        for purpose in [RequestPurpose.crosscheck, .memoryExtraction, .imageGeneration] {
            let result = plan(purpose)
            #expect(result.reject == nil, "\(purpose)")
            #expect(result.omitted.knowledge == 0, "\(purpose)")
            #expect(result.warnings.isEmpty, "\(purpose)")
        }
        #expect(plan(.crosscheck).messages?.count == 1)
        #expect(plan(.crosscheck).system == String(repeating: "s", count: 4000))
    }

    @Test("align_14")
    func align14ReminderCountsRawUserMessages() {
        // 5 raw user messages separated by failed turns merge into 1 after sanitize; with current that makes 6 -> triggers the reminder.
        var history: [ContextMessage] = []
        for index in 1...5 {
            history.append(message("u\(index)", .user, "Turn \(index)"))
            history.append(message("a\(index)", .assistant, "", .failed))
        }
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .chat, window: window(200_000, maxOutput: 8192),
            conversation: ContextConversation(id: "c1", useMemory: true, instructions: "Reply in French."),
            history: history, current: "Turn 6"
        ))
        #expect(plan.messages?.count == 1)
        #expect(plan.unansweredMerged == 5)
        #expect(plan.reminder)
    }

    @Test("align_15")
    func align15CurrentMessageId() {
        func lastId(_ currentId: String?) -> String? {
            let input = currentId.map {
                ContextAssembleInput(
                    purpose: .chat, window: window(200_000, maxOutput: 8192),
                    conversation: ContextConversation(id: "c1", useMemory: true),
                    history: [], current: "Hi", currentId: $0
                )
            } ?? ContextAssembleInput(
                purpose: .chat, window: window(200_000, maxOutput: 8192),
                conversation: ContextConversation(id: "c1", useMemory: true),
                history: [], current: "Hi"
            )
            return ContextAssembler.assemble(input).messages?.last?.id
        }
        #expect(lastId(nil) == "current")
        #expect(lastId("m42") == "m42")
    }

    @Test("align_16")
    func align16MemoryStringsFilteredByKnownValues() {
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .chat, window: window(200_000, maxOutput: 8192),
            conversation: ContextConversation(id: "c1", useMemory: true),
            memoryItems: [
                ContextMemoryItem(id: "ok", kind: "preference", content: "Known item."),
                ContextMemoryItem(id: "s", kind: "preference", content: "Unknown status.", status: "pendingReview"),
                ContextMemoryItem(id: "l", kind: "preference", content: "Unknown layer.", layer: "working"),
            ],
            history: [], current: "Hi"
        ))
        let system = plan.system ?? ""
        #expect(system.contains("<entry>Known item.</entry>"))
        #expect(!system.contains("Unknown status."))
        #expect(!system.contains("Unknown layer."))
        #expect(plan.segments.first { $0.kind == .memory }?.items == 1)
    }

    @Test("align_17")
    func align17EmptyTextAndBlankHostText() {
        let attachmentOnly = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .chat, window: window(200_000, maxOutput: 8192),
            conversation: ContextConversation(id: "c1", useMemory: true),
            history: [], current: "",
            currentAttachments: [ContextAttachmentRef(id: "f1", kind: .file)],
            dynamic: ContextDynamicInput(attachmentGuide: "  \n ")
        ))
        let last = attachmentOnly.messages?.last
        #expect(last?.blocks.isEmpty == true)
        #expect(last?.attachments.map(\.id) == ["f1"])
        #expect(attachmentOnly.budget.estimatedInput == 4)

        // Alignment 19: "empty body" means only the empty string; a body of whitespace only still produces a text block (as is, not trimmed).
        let whitespaceOnly = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .chat, window: window(200_000, maxOutput: 8192),
            conversation: ContextConversation(id: "c1", useMemory: true),
            history: [], current: "  ",
            currentAttachments: [ContextAttachmentRef(id: "f1", kind: .file)]
        ))
        let whitespaceBlocks = whitespaceOnly.messages?.last?.blocks ?? []
        #expect(whitespaceBlocks.map(\.kind) == [.text])
        #expect(whitespaceBlocks.first?.text == "  ")

        let toolLeg = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .toolLoopLeg, window: window(200_000, maxOutput: 8192),
            conversation: ContextConversation(id: "c1", useMemory: true, skillPrompt: "Research assistant."),
            toolSafety: " \n ", history: [], current: "Search."
        ))
        #expect(toolLeg.system == "Research assistant.")
        #expect(!toolLeg.segments.contains { $0.kind == .toolSafety })
    }

    private static let bigWindow = window(200_000, maxOutput: 8192)
    private static let plainConversation = ContextConversation(id: "c1", useMemory: true)

    @Test("align_20")
    func align20KeepAssistantIdPassesThrough() {
        let history = [message("u1", .user, "Q1"), message("a1", .assistant, "partial", .failed)]
        let kept = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .continue, window: Self.bigWindow, conversation: Self.plainConversation,
            history: history, keepAssistantId: "a1"
        ))
        #expect(kept.messages?.map(\.id) == ["u1", "a1", "current"])
        let dropped = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .continue, window: Self.bigWindow, conversation: Self.plainConversation, history: history
        ))
        #expect(dropped.messages?.map(\.id) == ["current"])
    }

    @Test("align_21")
    func align21NoCurrentNoAppendNoCount() {
        // 6 user messages (alternating) in the raw history, current omitted: nothing appended, counted as 6; with 5 it does not trigger.
        func plan(users: Int) -> ContextPlan {
            var history: [ContextMessage] = []
            for index in 1...users {
                history.append(message("u\(index)", .user, "Turn \(index)"))
                if index < users { history.append(message("a\(index)", .assistant, "Answer \(index)")) }
            }
            return ContextAssembler.assemble(ContextAssembleInput(
                purpose: .chat, window: Self.bigWindow,
                conversation: ContextConversation(id: "c1", useMemory: true, instructions: "Reply in French."),
                history: history
            ))
        }
        #expect(plan(users: 6).messages?.last?.id == "u6")
        #expect(plan(users: 6).reminder)
        #expect(plan(users: 5).messages?.count == 9)
        #expect(!plan(users: 5).reminder)
    }

    @Test("align_22")
    func align22RejectUsesLastSanitizedMessageAnyRole() {
        // On continue the last message is the fixed continuation sentence (short), and the long assistant before it does not count toward the refusal decision.
        let long = String(repeating: "a", count: 4000)
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .continue, window: window(1024, maxOutput: 128), conversation: Self.plainConversation,
            history: [message("u1", .user, "Q"), message("a1", .assistant, long)]
        ))
        #expect(plan.reject == nil)
        // The last message is an assistant (no current) and exceeds U: still refused.
        let assistantLast = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .chat, window: window(1024, maxOutput: 128), conversation: Self.plainConversation,
            history: [message("u1", .user, "Q"), message("a1", .assistant, long)]
        ))
        #expect(assistantLast.reject == .messageTooLong)
    }

    @Test("align_23")
    func align23ContinueDropsCurrentAttachments() {
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .continue, window: Self.bigWindow, conversation: Self.plainConversation,
            history: [message("u1", .user, "Q"), message("a1", .assistant, "A")],
            current: "ignored", currentAttachments: [ContextAttachmentRef(id: "f1", kind: .file)]
        ))
        let last = plan.messages?.last
        #expect(last?.blocks.map(\.text) == [ContextAssembler.continuePrompt])
        #expect(last?.attachments.isEmpty == true)
    }

    @Test("align_24")
    func align24BlankEntriesRemovedBeforeShrinkNotCounted() {
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .chat, window: window(4096, maxOutput: 512),
            conversation: ContextConversation(
                id: "c1", useMemory: true,
                pinnedNotes: [ContextPinnedNote(title: "Blank", text: "  \n")],
                knowledgeFiles: [
                    ContextKnowledgeFile(name: "big.md", text: String(repeating: "k", count: 4000)),
                    ContextKnowledgeFile(name: "blank.md", text: " "),
                ]
            ),
            memoryItems: [ContextMemoryItem(id: "m", kind: "fact", content: "\t")],
            history: [], current: "Go"
        ))
        #expect(plan.system == nil)
        #expect(plan.omitted.knowledge == 1)
        #expect(plan.omitted.notes == 0)
        #expect(plan.omitted.memory == 0)
    }

    @Test("align_25")
    func align25WhitespaceLatestKeepsBlankLineAndText() {
        let merged = ContextSanitizer.sanitize([
            message("u1", .user, "Look"),
            message("a1", .assistant, "", .failed),
            message("u2", .user, "  ", attachments: [ContextAttachmentRef(id: "img", kind: .image)]),
        ])
        let envelope = "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\nLook\n</oriveo-unanswered>"
        #expect(merged.map(\.text) == [envelope + "\n\n  "])
        let emptyLatest = ContextSanitizer.sanitize([
            message("u1", .user, "Look"),
            message("u2", .user, "", attachments: [ContextAttachmentRef(id: "img", kind: .image)]),
        ])
        #expect(emptyLatest.map(\.text) == [envelope])
    }

    @Test("align_26")
    func align26ImagePromptNullWithoutUserText() {
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .imageGeneration, window: Self.bigWindow, conversation: Self.plainConversation,
            history: [message("u1", .user, "  ", attachments: [ContextAttachmentRef(id: "f", kind: .file)]),
                      message("a1", .assistant, "Sure")],
            current: " \n "
        ))
        #expect(plan.imagePrompt == nil)
        #expect(plan.messages == nil)
    }
}

