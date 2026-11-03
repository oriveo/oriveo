import Foundation
import Testing
@testable import Oriveo

/// A realtime disclosure answer looks only at a single source; an overwritten older source or leftovers after an answer never apply.
@Suite("RealtimeDisclosureDispatch")
struct RealtimeDisclosureDispatchTests {
    private let capability = ChatCapabilitySelection()

    private func request(_ model: String = "gpt-realtime", conversationID: UUID? = nil) -> RealtimeModelDisclosureRequest {
        RealtimeModelDisclosureRequest(
            selection: RealtimeModelSelection(providerID: UUID(), providerKind: .openAI, model: model),
            conversationID: conversationID
        )
    }

    @Test func picker_accept_and_decline_only_resolve() {
        #expect(RealtimeDisclosureDispatch.action(origin: .picker, accepted: true) == .resolve(accepted: true))
        // Plain picker disclosure declined: only record the decline, do not open the voice path and do not run migration.
        #expect(RealtimeDisclosureDispatch.action(origin: .picker, accepted: false) == .resolve(accepted: false))
    }

    @Test func voice_start_accept_starts_voice_decline_does_not() {
        #expect(RealtimeDisclosureDispatch.action(origin: .voiceStart(capability), accepted: true)
            == .resolveThenStartVoice(capability))
        #expect(RealtimeDisclosureDispatch.action(origin: .voiceStart(nil), accepted: true) == .resolveThenStartVoice(nil))
        #expect(RealtimeDisclosureDispatch.action(origin: .voiceStart(capability), accepted: false) == .resolve(accepted: false))
    }

    @Test func typed_send_accept_sends_text_decline_keeps_it() {
        #expect(RealtimeDisclosureDispatch.action(origin: .typedSend("Hello"), accepted: true) == .resolveThenSendTyped("Hello"))
        #expect(RealtimeDisclosureDispatch.action(origin: .typedSend("Hello"), accepted: false) == .resolve(accepted: false))
    }

    @Test func migration_hands_answer_to_migration_with_its_capability() {
        #expect(RealtimeDisclosureDispatch.action(origin: .migration(capability), accepted: true)
            == .resolveMigration(accepted: true, capabilitySelection: capability))
        #expect(RealtimeDisclosureDispatch.action(origin: .migration(capability), accepted: false)
            == .resolveMigration(accepted: false, capabilitySelection: capability))
        #expect(RealtimeDisclosureDispatch.action(origin: .migration(nil), accepted: false)
            == .resolveMigration(accepted: false, capabilitySelection: nil))
    }

    @Test func overwritten_origin_no_longer_applies() throws {
        var pending = RealtimeDisclosurePending()
        let migration = request("gpt-realtime-mini")
        let picker = request()
        pending.present(migration, origin: .migration(capability))
        pending.present(picker, origin: .picker)
        let result = pending.take(accepted: false)
        let taken = try #require(result)
        #expect(taken.request == picker)
        // The older migration source was overwritten: a decline no longer opens the voice path by mistake.
        #expect(taken.action == .resolve(accepted: false))
    }

    @Test func answer_takes_origin_once_and_dismiss_after_answer_is_noop() throws {
        var pending = RealtimeDisclosurePending()
        let typed = request(conversationID: UUID())
        pending.present(typed, origin: .typedSend("Hello"))
        let result = pending.take(accepted: true)
        let taken = try #require(result)
        #expect(taken.request == typed)
        #expect(taken.action == .resolveThenSendTyped("Hello"))
        // onDismiss after onAnswer answers again: the origin was already taken, so no action.
        let again = pending.take(accepted: false)
        #expect(again == nil)
        #expect(pending.origin == nil)
        #expect(pending.request == nil)
    }

    @Test func dismiss_counts_as_decline() throws {
        var pending = RealtimeDisclosurePending()
        pending.present(request(), origin: .voiceStart(capability))
        // Dismissing the sheet counts as a decline: do not start the voice path.
        let result = pending.take(accepted: false)
        let taken = try #require(result)
        #expect(taken.action == .resolve(accepted: false))
        // The next plain picker disclosure is not affected by leftovers.
        pending.present(request(), origin: .picker)
        let next = pending.take(accepted: false)
        #expect(try #require(next).action == .resolve(accepted: false))
    }

    @Test func clear_drops_origin_without_action() {
        var pending = RealtimeDisclosurePending()
        pending.present(request(), origin: .migration(capability))
        pending.clear()
        let result = pending.take(accepted: false)
        #expect(result == nil)
    }
}
