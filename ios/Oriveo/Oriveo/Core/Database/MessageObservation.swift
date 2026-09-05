import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class MessageObservation {
    private(set) var messages: [ChatMessage] = []
    private(set) var revision: UInt = 0
    private(set) var initialLoadFailed = false
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var observedConversationID: UUID?
    private let attachmentFileStoreOverride: AttachmentFileStore?

    init() {
        self.attachmentFileStoreOverride = nil
    }

    init(attachmentFileStore: AttachmentFileStore) {
        self.attachmentFileStoreOverride = attachmentFileStore
    }

    func observe(conversationID: UUID, in dbPool: DatabasePool) {
        stop()
        observedConversationID = conversationID
        initialLoadFailed = false
        let attachmentFileStore = attachmentFileStoreOverride
            ?? AttachmentFileStore(rootDirectory: AppSessionStore.filesDir)

        let observation = ValueObservation.tracking { db in
            try ConversationStore.fetchMessages(
                db: db,
                conversationID: conversationID,
                hydrateFilePayloads: false,
                attachmentFileStore: attachmentFileStore
            )
        }

        cancellable = observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                MainActor.assumeIsolated {
                    guard let strongSelf = self, strongSelf.observedConversationID == conversationID else { return }
                    guard strongSelf.messages.isEmpty, strongSelf.revision == 0 else { return }
                    strongSelf.initialLoadFailed = true
                }
            },
            onChange: { [weak self] messages in
                MainActor.assumeIsolated {
                    guard let strongSelf = self, strongSelf.observedConversationID == conversationID else { return }
                    strongSelf.initialLoadFailed = false
                    let changed = strongSelf.messages != messages
                    if changed {
                        strongSelf.revision &+= 1
                    }
                    strongSelf.messages = messages
                }
            }
        )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        observedConversationID = nil
        initialLoadFailed = false
        messages = []
        revision = 0
    }

    nonisolated deinit {}
}
