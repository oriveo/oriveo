import Foundation

/// Client-side control of an open realtime session.
/// Calls are fire-and-forget; send failures end the session stream with an error.
nonisolated protocol RealtimeSessionControl: Sendable {
    /// PCM16 little-endian mono bytes at the transport's `uplinkSampleRate`; dropped until the session is ready.
    func sendAudio(_ pcm16: Data)
    /// Barge-in truncate of the playing assistant item; no-op when the codec yields nothing.
    func truncate(itemId: String?, contentIndex: Int, playedMs: Double)
    /// Ends the session stream without an error and closes the socket.
    func close()
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

    init(host: String, apiKey: String, model: String, path: String, voice: String, inputTranscriptionModel: String? = nil) {
        self.host = host
        self.apiKey = apiKey
        self.model = model
        self.path = path
        self.voice = voice
        self.inputTranscriptionModel = inputTranscriptionModel
    }

    var description: String {
        "RealtimeEndpoint(host: \(host), path: \(path), model: \(model), voice: \(voice), "
            + "inputTranscriptionModel: \(inputTranscriptionModel ?? "nil"))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [
            "host": host, "path": path, "model": model, "voice": voice,
            "inputTranscriptionModel": inputTranscriptionModel as Any,
        ])
    }
}

/// Builds the realtime transport for a wire kind. `resumeHandle` only applies to gemini_live
/// (reopening within the same fingerprint); GA kinds ignore it.
nonisolated enum RealtimeTransportFactory {
    static func make(
        kind: RealtimeTransportKind,
        endpoint: RealtimeEndpoint,
        resumeHandle: String? = nil
    ) -> (any RealtimeTransport & RealtimeSessionControl)? {
        switch kind {
        case .openaiRealtime, .xaiRealtime:
            GARealtimeTransport(kind: kind, endpoint: endpoint)
        case .geminiLive:
            GeminiLiveSessionControl(endpoint: endpoint, resumeHandle: resumeHandle)
        }
    }
}
