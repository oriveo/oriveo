import Combine
import UIKit

@MainActor
final class ChatStreamingCoordinator {
    private let displayClock: StreamingDisplayClock
    private var publisher: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher()
    private var reasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never> =
        Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher()
    private var textProvider: () -> String = { "" }
    private var reasoningSnapshotProvider: () -> ReasoningStreamSnapshot? = { nil }

    init(displayClock: StreamingDisplayClock) {
        self.displayClock = displayClock
    }

    func bind(
        publisher: AnyPublisher<Void, Never>,
        reasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never>,
        textProvider: @escaping () -> String,
        reasoningSnapshotProvider: @escaping () -> ReasoningStreamSnapshot?
    ) {
        self.publisher = publisher
        self.reasoningPublisher = reasoningPublisher
        self.textProvider = textProvider
        self.reasoningSnapshotProvider = reasoningSnapshotProvider
    }

    func attachStreaming(to cell: AssistantMessageCell) {
        cell.displayClock = displayClock
        cell.startStreamingSubscription(
            publisher: publisher,
            reasoningPublisher: reasoningPublisher,
            textProvider: textProvider,
            reasoningSnapshotProvider: reasoningSnapshotProvider
        )
    }
}
