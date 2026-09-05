import Foundation
import GRDB
import Observation


@MainActor
@Observable
final class CurrentConversationObservation {
    private(set) var summary: ConversationSummary?
    private(set) var hasLoadedInitialValue = false
    private(set) var initialLoadFailed = false
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var observedConversationID: UUID?

    func observe(conversationID: UUID, in dbPool: DatabasePool) {
        stop()
        observedConversationID = conversationID
        initialLoadFailed = false

        let observation = ValueObservation.tracking { db in
            try ConversationStore.fetchConversationSummary(db: db, id: conversationID)
        }

        cancellable = observation.start(
            in: dbPool,
            scheduling: .immediate,
            onError: { [weak self] error in
                #if DEBUG
                print("[CurrentConversationObservation] \(error)")
                #endif
                MainActor.assumeIsolated {
                    guard let strongSelf = self, strongSelf.observedConversationID == conversationID else { return }
                    guard strongSelf.hasLoadedInitialValue == false else { return }
                    strongSelf.initialLoadFailed = true
                }
            },
            onChange: { [weak self] summary in
                MainActor.assumeIsolated {
                    guard let strongSelf = self, strongSelf.observedConversationID == conversationID else { return }
                    strongSelf.initialLoadFailed = false
                    strongSelf.summary = summary
                    strongSelf.hasLoadedInitialValue = true
                }
            }
        )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        observedConversationID = nil
        initialLoadFailed = false
        hasLoadedInitialValue = false
        summary = nil
    }
}
