import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Conversation instructions go into the production request's system; from the 6th user message on, <oriveo-reminder> is appended at the end,
/// and when the remote switch context_reminder_enabled is false only the reminder is turned off. Assertions read the production request body captured by URLProtocol.
extension ContextPipelineTests {

    private static let instructions = "Write only in Arabic."

    private static var instructionsSystem: String {
        ContextAssembler.instructionsHeader + "\n" + instructions
    }

    /// Five delivered question-answer rounds; sending one more makes the 6th user message.
    private static func fiveTurns() -> [ChatMessage] {
        (1...5).flatMap { turn in
            [
                TestFactories.makeMessage(role: .user, text: "Turn \(turn)"),
                TestFactories.makeMessage(role: .assistant, text: "Answer \(turn)"),
            ]
        }
    }

    private func loadReminderFlag(_ enabled: Bool) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "providers": {},
          "runtimeConfig": { "featureFlags": { "\(ChatRequestBuilder.reminderRemoteFlagKey)": \(enabled) } }
        }
        """)
    }

    @Test func pipeline_instructions_in_system() async throws {
        let fixture = makeFixture(messages: [], useMemory: false, instructions: Self.instructions)
        let body = try await capture { _ = await fixture.state.sendMessage("Hello", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        #expect(messages.first?.role == "system")
        #expect(messages.first?.text == Self.instructionsSystem)
        #expect(messages.last?.text == "Hello")
    }

    @Test func pipeline_reminder_after_six_user_messages() async throws {
        try await loadReminderFlag(true)
        let fixture = makeFixture(messages: Self.fiveTurns(), useMemory: false, instructions: Self.instructions)
        let body = try await capture { _ = await fixture.state.sendMessage("Turn 6", in: fixture.conversationID) }
        await MetadataClient.shared.resetForTesting()
        let messages = Self.wireMessages(body)
        #expect(messages.first?.text == Self.instructionsSystem)
        let last = try #require(messages.last)
        #expect(last.role == "user")
        #expect(last.text.hasPrefix("Turn 6\n\n<oriveo-reminder>"))
        #expect(last.text.hasSuffix("\n\(Self.instructions)\n</oriveo-reminder>"))
    }

    @Test func pipeline_reminder_disabled_by_remote_flag() async throws {
        try await loadReminderFlag(false)
        let fixture = makeFixture(messages: Self.fiveTurns(), useMemory: false, instructions: Self.instructions)
        let body = try await capture { _ = await fixture.state.sendMessage("Turn 6", in: fixture.conversationID) }
        await MetadataClient.shared.resetForTesting()
        let messages = Self.wireMessages(body)
        #expect(messages.first?.role == "system")
        #expect(messages.first?.text == Self.instructionsSystem)
        #expect(!messages.contains { $0.text.contains("<oriveo-reminder>") })
        #expect(messages.last?.text == "Turn 6")
    }
}
