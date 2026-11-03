import Foundation

/// Glues a GA realtime transport to RealtimeAudioIO.
/// Mic frames go up after ready, assistant audio is played as it streams, barge-in truncates
/// the playing item at the played milliseconds. Events pass through unchanged; no persistence, no UI.
final class RealtimeConversationDriver {
    private let connection: any RealtimeTransport & RealtimeSessionControl
    private let audio: any RealtimeAudioIO
    /// Assistant item currently fed to the player (barge-in truncate target).
    private var playingItemId: String?
    /// Item truncated by barge-in; its late audio deltas are dropped until another item or turn done.
    private var truncatedItemId: String?
    /// Barge-in hit while no assistant item id was known (Gemini): drop all assistant audio
    /// until interrupted or turn done.
    private var droppingUnidentifiedAudio = false
    /// Audio is started once per run, even if the server sends ready more than once.
    private var audioStarted = false
    /// Set before the controller closes a still-live connection to reopen: the ending stream must not
    /// stop the audio that the next driver keeps using.
    private var retired = false
    /// E-514: false = on ready only playback starts (typing mode, mic stays off); startCapture() adds it later.
    private var captureOnReady: Bool
    /// Audio has been started for this run (playback-only or full).
    private var audioRunning = false
    /// The mic is captured and frames go up.
    private var capturing = false

    init(
        connection: any RealtimeTransport & RealtimeSessionControl,
        audio: any RealtimeAudioIO,
        captureOnReady: Bool = true
    ) {
        self.connection = connection
        self.audio = audio
        self.captureOnReady = captureOnReady
    }

    /// Typing mode back to voice: add mic capture in place, without reopening the connection.
    /// Before ready (or while preparing) the run simply starts with capture. Reconfiguring the engine stops the
    /// playing reply, so it is cut as a barge-in first (truncated at the played ms). A capture failure ends the
    /// run like a system interruption.
    func startCapture() {
        guard !capturing else { return }
        captureOnReady = true
        guard audioRunning, !retired else { return }
        interruptPlayback()
        do {
            try audio.startRealtimeCapture(uplinkSampleRate: connection.uplinkSampleRate, onFrame: uplinkSender())
            capturing = true
        } catch {
            interruptBySystem()
        }
    }

    /// Called on the audio thread: must not inherit main-actor isolation.
    private func uplinkSender() -> @Sendable (Data) -> Void {
        let connection = connection
        return { @Sendable frame in connection.sendAudio(frame) }
    }

    /// The controller is replacing this run's live connection: from now on the run touches no audio.
    func retire() {
        retired = true
    }

    func run(plan: PlannedRealtimeSession) -> AsyncThrowingStream<RealtimeSessionEvent, Error> {
        let transport = plan.transportInput()
        let upstream = connection.openRealtimeSession(transport: transport)
        let (stream, continuation) = AsyncThrowingStream<RealtimeSessionEvent, Error>.makeStream()
        let pump = Task { [self] in
            do {
                for try await event in upstream {
                    if retired { break }
                    try await handle(event)
                    continuation.yield(event)
                }
                if !retired { audio.stopRealtime() }
                continuation.finish()
            } catch let expired as GeminiLiveTransportError where expired.isSessionExpired {
                // an expired session may be reopened by the controller, so the audio
                // keeps running; the controller stops it once the conversation really ends.
                continuation.finish(throwing: expired)
            } catch {
                if !retired { audio.stopRealtime() }
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }

    private func handle(_ event: RealtimeSessionEvent) async throws {
        switch event {
        case .ready:
            guard !audioStarted else { return }
            audioStarted = true
            let connection = connection
            do {
                // Prepare the audio session off the main thread before the engine starts (once per run).
                try await audio.prepareSession()
                // Ended while preparing: no mic. A retired run leaves the shared audio to the next driver.
                guard !retired, !Task.isCancelled else {
                    if !retired { audio.stopRealtime() }
                    return
                }
                if captureOnReady {
                    try audio.startRealtime(
                        uplinkSampleRate: connection.uplinkSampleRate,
                        onFrame: uplinkSender(),
                        onInterruption: { [weak self] in self?.interruptBySystem() }
                    )
                    capturing = true
                } else {
                    try audio.startRealtimePlayback(onInterruption: { [weak self] in self?.interruptBySystem() })
                }
                audioRunning = true
            } catch {
                connection.close()
                throw error
            }
        case let .assistantAudio(itemId, _, base64, _):
            if droppingUnidentifiedAudio { return }
            if let truncated = truncatedItemId {
                if itemId == truncated { return }
                truncatedItemId = nil
            }
            guard let pcm16 = Data(base64Encoded: base64) else { return }
            audio.enqueue(pcm16: pcm16, itemId: itemId ?? "")
            playingItemId = itemId
        case .userSpeechStarted:
            interruptPlayback()
        case .assistantTurnDone:
            truncatedItemId = nil
            droppingUnidentifiedAudio = false
        case .interrupted:
            audio.stopRealtimePlayback()
            droppingUnidentifiedAudio = false
        case .sessionEnded:
            audio.stopRealtime()
        default:
            break
        }
    }

    /// Barge-in (server speech start or user tap): no-op unless playing. Reads played ms, stops playback,
    /// truncates only when the item id is known, then drops that item's (or all unidentified) late audio.
    func interruptPlayback() {
        guard audio.isPlaying else { return }
        let item = playingItemId
        let playedMs = audio.playedMs(itemId: item ?? "")
        audio.stopRealtimePlayback()
        if let item {
            connection.truncate(itemId: item, contentIndex: 0, playedMs: Double(playedMs))
            truncatedItemId = item
        } else {
            droppingUnidentifiedAudio = true
        }
    }

    /// System interruption / lost audio focus: close at once, no recovery.
    private func interruptBySystem() {
        connection.close()
        audio.stopRealtime()
    }
}
