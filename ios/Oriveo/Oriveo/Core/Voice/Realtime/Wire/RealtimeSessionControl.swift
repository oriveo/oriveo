import Foundation

/// Client-side control of an open realtime session.
/// Calls are fire-and-forget; send failures end the session stream with an error.
nonisolated protocol RealtimeSessionControl: Sendable {
    /// PCM16 little-endian mono bytes at the transport's `uplinkSampleRate`; dropped until the session is ready.
    func sendAudio(_ pcm16: Data)
    /// One typed user turn to the same realtime model (E-514). The GA transport drops it until the session is ready;
    /// Gemini Live queues it behind buffered audio and sends it once the (re)connection is ready.
    func sendText(_ text: String)
    /// Barge-in truncate of the playing assistant item; no-op when the codec yields nothing.
    func truncate(itemId: String?, contentIndex: Int, playedMs: Double)
    /// Ends the session stream without an error and closes the socket.
    func close()
    /// Milliseconds of uplink audio enqueued and not yet sent; nil when the transport has no such reading (E-515).
    var uplinkBacklogMs: Double? { get }
    /// Output route changed mid-session (E-602); transports without a route-dependent setting ignore it.
    func updateOutputRoute(_ route: VoiceConversationLogic.Route)
}

extension RealtimeSessionControl {
    var uplinkBacklogMs: Double? { nil }
    func updateOutputRoute(_ route: VoiceConversationLogic.Route) {}
}

/// Connection parameters for a GA realtime endpoint. Descriptions never include the api key.
nonisolated struct RealtimeEndpoint: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    let host: String
    let apiKey: String
    let model: String
    let path: String
    let voice: String
    let inputTranscriptionModel: String?
    /// Host recognition language in BCP-47 (the configured recognition language, or the UI language when empty); nil = do not hint the transcription language.
    let language: String?

    init(host: String, apiKey: String, model: String, path: String, voice: String, inputTranscriptionModel: String? = nil,
         language: String? = nil) {
        self.host = host
        self.apiKey = apiKey
        self.model = model
        self.path = path
        self.voice = voice
        self.inputTranscriptionModel = inputTranscriptionModel
        self.language = language
    }

    var description: String {
        "RealtimeEndpoint(host: \(host), path: \(path), model: \(model), voice: \(voice), "
            + "inputTranscriptionModel: \(inputTranscriptionModel ?? "nil"), language: \(language ?? "nil"))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [
            "host": host, "path": path, "model": model, "voice": voice,
            "inputTranscriptionModel": inputTranscriptionModel as Any,
            "language": language as Any,
        ])
    }
}

/// Output route sampled each time a realtime connection opens (first open, reopen, resume).
typealias RealtimeRouteProvider = @Sendable () -> VoiceConversationLogic.Route

/// Builds the realtime transport for a wire kind. `resumeHandle` only applies to gemini_live
/// (reopening within the same fingerprint); GA kinds ignore it. `route` is sampled whenever a
/// connection opens: GA once per transport (every reopen builds a new one), gemini_live before
/// each setup (first open and every resume).
nonisolated enum RealtimeTransportFactory {
    static func make(
        kind: RealtimeTransportKind,
        endpoint: RealtimeEndpoint,
        resumeHandle: String? = nil,
        route: @escaping RealtimeRouteProvider = { .speaker }
    ) -> (any RealtimeTransport & RealtimeSessionControl)? {
        switch kind {
        case .openaiRealtime, .xaiRealtime:
            GARealtimeTransport(kind: kind, endpoint: endpoint, route: route)
        case .geminiLive:
            GeminiLiveSessionControl(endpoint: endpoint, resumeHandle: resumeHandle, route: route)
        }
    }
}
