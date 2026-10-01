import Combine
import UIKit

@MainActor
final class ChatStreamingCoordinator {
    private let displayClock: StreamingDisplayClock
    private var publisher: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher()
    private var reasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never> =
        Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher()
    private var activityPublisher: AnyPublisher<StreamActivityState, Never> =
        Empty<StreamActivityState, Never>().eraseToAnyPublisher()
    private var textProvider: () -> String = { "" }
    private var reasoningSnapshotProvider: () -> ReasoningStreamSnapshot? = { nil }
    private var activityProvider: () -> StreamActivityState? = { nil }

    init(displayClock: StreamingDisplayClock) {
        self.displayClock = displayClock
    }

    func bind(
        publisher: AnyPublisher<Void, Never>,
        reasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never>,
        textProvider: @escaping () -> String,
        reasoningSnapshotProvider: @escaping () -> ReasoningStreamSnapshot?,
        activityPublisher: AnyPublisher<StreamActivityState, Never> =
            Empty<StreamActivityState, Never>().eraseToAnyPublisher(),
        activityProvider: @escaping () -> StreamActivityState? = { nil }
    ) {
        self.publisher = publisher
        self.reasoningPublisher = reasoningPublisher
        self.textProvider = textProvider
        self.reasoningSnapshotProvider = reasoningSnapshotProvider
        self.activityPublisher = activityPublisher
        self.activityProvider = activityProvider
    }

    func attachStreaming(to cell: AssistantMessageCell) {
        cell.displayClock = displayClock
        cell.startStreamingSubscription(
            publisher: publisher,
            reasoningPublisher: reasoningPublisher,
            textProvider: textProvider,
            reasoningSnapshotProvider: reasoningSnapshotProvider,
            activityPublisher: activityPublisher,
            activityProvider: activityProvider
        )
    }
}
