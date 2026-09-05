import Combine
import Foundation
import QuartzCore

@MainActor
final class AssistantStreamingController {
    private var bodyCancellable: AnyCancellable?
    private var reasoningCancellable: AnyCancellable?

    private var activeMessageID: UUID?
    private var activeSendTaskID: UUID?
    private var receivedReasoningRevision: UInt64 = 0
    private var hasReasoning = false

    private var pendingReasoningDelta = ""
    private var pendingReasoningRevision: UInt64?
    private var pendingReasoningWorkItem: DispatchWorkItem?
    private var lastReasoningApplyTime: CFTimeInterval = 0
    private var generation: UInt = 0

    private var reasoningSnapshotProvider: (() -> ReasoningStreamSnapshot?)?
    private var isBoundProvider: (() -> Bool)?
    private var applyReasoningSnapshot: ((ReasoningStreamSnapshot?) -> Void)?
    private var applyReasoningDelta: ((ReasoningStreamDelta) -> Void)?

    private static let reasoningThrottleInterval: CFTimeInterval = 0.08

    var isSubscribed: Bool {
        bodyCancellable != nil || reasoningCancellable != nil
    }

    #if DEBUG
    var _testScheduledReasoningWorkItemCount = 0
    var _testReasoningSnapshotReadCount = 0
    var _testPendingReasoningUTF8Count: Int { pendingReasoningDelta.utf8.count }
    #endif

    func start(
        publisher: AnyPublisher<Void, Never>,
        reasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never>,
        textProvider: @escaping () -> String,
        reasoningSnapshotProvider: @escaping () -> ReasoningStreamSnapshot?,
        isBound: @escaping () -> Bool,
        enqueueText: @escaping (String) -> Void,
        applyInitialText: @escaping (String) -> Void,
        applyInitialReasoning: @escaping (ReasoningStreamSnapshot?) -> Void,
        hideTypingIfNeeded: @escaping () -> Void,
        applyReasoning: @escaping (ReasoningStreamDelta) -> Void
    ) {
        if isSubscribed, isBound() {
            return
        }

        let initialSnapshot = readSnapshot(using: reasoningSnapshotProvider)
        cancel()
        self.reasoningSnapshotProvider = reasoningSnapshotProvider
        self.isBoundProvider = isBound
        self.applyReasoningSnapshot = applyInitialReasoning
        self.applyReasoningDelta = applyReasoning

        applyInitialText(textProvider())
        adopt(snapshot: initialSnapshot)
        applyInitialReasoning(initialSnapshot)

        bodyCancellable = publisher.sink { [weak self] in
            guard self != nil, isBound() else { return }
            enqueueText(textProvider())
        }
        reasoningCancellable = reasoningPublisher.sink { [weak self] delta in
            guard let self, isBound() else { return }
            self.handleReasoningDelta(delta, hideTypingIfNeeded: hideTypingIfNeeded)
        }
    }

    func cancel() {
        bodyCancellable?.cancel()
        reasoningCancellable?.cancel()
        bodyCancellable = nil
        reasoningCancellable = nil
        generation &+= 1
        resetReasoning()
        reasoningSnapshotProvider = nil
        isBoundProvider = nil
        applyReasoningSnapshot = nil
        applyReasoningDelta = nil
    }

    func resetReasoning() {
        activeMessageID = nil
        activeSendTaskID = nil
        receivedReasoningRevision = 0
        hasReasoning = false
        pendingReasoningDelta.removeAll(keepingCapacity: false)
        pendingReasoningRevision = nil
        pendingReasoningWorkItem?.cancel()
        pendingReasoningWorkItem = nil
        lastReasoningApplyTime = 0
    }

    func isReasoningEmpty() -> Bool {
        !hasReasoning
    }

    func synchronizeReasoning() {
        guard let provider = reasoningSnapshotProvider,
              isBoundProvider?() == true else { return }
        let snapshot = readSnapshot(using: provider)
        guard snapshot?.messageID == activeMessageID,
              snapshot?.sendTaskID == activeSendTaskID else { return }
        replaceWithSnapshot(snapshot)
    }

    private func handleReasoningDelta(
        _ delta: ReasoningStreamDelta,
        hideTypingIfNeeded: @escaping () -> Void
    ) {
        guard delta.messageID == activeMessageID,
              delta.sendTaskID == activeSendTaskID else { return }

        if delta.revision <= receivedReasoningRevision {
            return
        }
        guard delta.revision == receivedReasoningRevision &+ 1 else {
            synchronizeReasoning()
            return
        }

        receivedReasoningRevision = delta.revision
        if !hasReasoning {
            hasReasoning = true
            hideTypingIfNeeded()
        }
        pendingReasoningDelta.append(delta.delta)
        pendingReasoningRevision = delta.revision

        guard pendingReasoningWorkItem == nil else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastReasoningApplyTime
        if elapsed >= Self.reasoningThrottleInterval {
            lastReasoningApplyTime = now
            flushPendingReasoningDelta()
            return
        }

        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.pendingReasoningWorkItem = nil
            guard self.isBoundProvider?() == true else {
                self.pendingReasoningDelta.removeAll(keepingCapacity: false)
                self.pendingReasoningRevision = nil
                return
            }
            self.lastReasoningApplyTime = CACurrentMediaTime()
            self.flushPendingReasoningDelta()
        }
        pendingReasoningWorkItem = work
        #if DEBUG
        _testScheduledReasoningWorkItemCount += 1
        #endif
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (Self.reasoningThrottleInterval - elapsed),
            execute: work
        )
    }

    private func flushPendingReasoningDelta() {
        guard let messageID = activeMessageID,
              let sendTaskID = activeSendTaskID,
              let revision = pendingReasoningRevision else { return }
        let delta = ReasoningStreamDelta(
            messageID: messageID,
            sendTaskID: sendTaskID,
            revision: revision,
            delta: pendingReasoningDelta
        )
        pendingReasoningDelta.removeAll(keepingCapacity: true)
        pendingReasoningRevision = nil
        applyReasoningDelta?(delta)
    }

    private func replaceWithSnapshot(_ snapshot: ReasoningStreamSnapshot?) {
        pendingReasoningWorkItem?.cancel()
        pendingReasoningWorkItem = nil
        pendingReasoningDelta.removeAll(keepingCapacity: true)
        pendingReasoningRevision = nil
        adopt(snapshot: snapshot)
        lastReasoningApplyTime = CACurrentMediaTime()
        applyReasoningSnapshot?(snapshot)
    }

    private func adopt(snapshot: ReasoningStreamSnapshot?) {
        activeMessageID = snapshot?.messageID
        activeSendTaskID = snapshot?.sendTaskID
        receivedReasoningRevision = snapshot?.revision ?? 0
        hasReasoning = snapshot?.text.contains(where: { !$0.isWhitespace }) == true
    }

    private func readSnapshot(
        using provider: () -> ReasoningStreamSnapshot?
    ) -> ReasoningStreamSnapshot? {
        #if DEBUG
        _testReasoningSnapshotReadCount += 1
        #endif
        return provider()
    }
}
