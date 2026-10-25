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

    init(connection: any RealtimeTransport & RealtimeSessionControl, audio: any RealtimeAudioIO) {
        self.connection = connection
        self.audio = audio
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
                    try handle(event)
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

    private func handle(_ event: RealtimeSessionEvent) throws {
        switch event {
        case .ready:
            guard !audioStarted else { return }
            audioStarted = true
            let connection = connection
            do {
                try audio.startRealtime(
                    uplinkSampleRate: connection.uplinkSampleRate,
                    // Called on the audio thread: must not inherit main-actor isolation.
                    onFrame: { @Sendable frame in connection.sendAudio(frame) },
                    onInterruption: { [weak self] in self?.interruptBySystem() }
                )
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
