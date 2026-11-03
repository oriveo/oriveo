import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Session state changes always run on a dedicated serial queue, never on the main thread; order matches submission order.
@Suite("Audio session coordinator", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AudioSessionCoordinatorTests {

    @Test("await activation from main: configure and activate both run off the main thread, in order")
    func test_activateFromMain_runsOffMainInOrder() async throws {
        let recorder = SessionOpRecorder()
        let coordinator = AudioSessionCoordinator(apply: recorder.apply)
        let config = AudioSessionCoordinator.Configuration(category: .playback, mode: .spokenAudio)

        #expect(Thread.isMainThread)
        try await coordinator.activate(config)

        #expect(recorder.operations == [.configure(config), .activate])
        #expect(recorder.anyOnMain == false)
    }

    @Test("deactivate does not block the caller and runs before the following activation")
    func test_deactivateThenActivate_keepsOrder() async throws {
        let recorder = SessionOpRecorder()
        let coordinator = AudioSessionCoordinator(apply: recorder.apply)

        coordinator.deactivate(notifyOthers: true)
        try await coordinator.activate(nil)

        #expect(recorder.operations == [.deactivate(notifyOthers: true), .activate])
        #expect(recorder.anyOnMain == false)
    }

    @Test("first operation throws: the error reaches the caller and later operations do not run")
    func test_performStopsAtFirstError() async {
        let recorder = SessionOpRecorder(failOn: .activate)
        let coordinator = AudioSessionCoordinator(apply: recorder.apply)

        await #expect(throws: SessionOpRecorder.Failure.self) {
            try await coordinator.perform([.activate, .preferIOBufferDuration(0.02)])
        }
        #expect(recorder.operations == [.activate])
    }

    @Test("blocking perform from a background thread returns only after it completes on the session queue")
    func test_performBlocking_fromBackground() async throws {
        let recorder = SessionOpRecorder()
        let coordinator = AudioSessionCoordinator(apply: recorder.apply)

        try await Task.detached {
            try coordinator.performBlocking([.activate])
        }.value

        #expect(recorder.operations == [.activate])
        #expect(recorder.anyOnMain == false)
    }
}

/// Records session operations and the executing thread; each voice test injects `AudioSessionCoordinator(apply: recorder.apply)` and shares it.
nonisolated final class SessionOpRecorder: @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var _records: [(op: AudioSessionCoordinator.Operation, onMain: Bool)] = []
    private let failOn: AudioSessionCoordinator.Operation?

    init(failOn: AudioSessionCoordinator.Operation? = nil) { self.failOn = failOn }

    var operations: [AudioSessionCoordinator.Operation] { lock.withLock { _records.map(\.op) } }
    var anyOnMain: Bool { lock.withLock { _records.contains { $0.onMain } } }

    var apply: @Sendable (AudioSessionCoordinator.Operation) throws -> Void {
        { [self] op in
            lock.withLock { _records.append((op, Thread.isMainThread)) }
            if op == failOn { throw Failure() }
        }
    }
}
