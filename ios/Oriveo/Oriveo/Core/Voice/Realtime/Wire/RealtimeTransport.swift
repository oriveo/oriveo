import Foundation

/// Wire entry for realtime voice sessions. Definition only; concrete transports
/// (OpenAI / xAI / Gemini Live) map server events to RealtimeSessionEvent later.
nonisolated protocol RealtimeTransport: Sendable {
    /// Which wire protocol this transport speaks.
    var kind: RealtimeTransportKind { get }

    /// Mono PCM16 uplink sample rate the wire expects; capture resamples the device rate straight to it
    /// (Gemini Live 16 kHz, others 24 kHz). `sendAudio` receives frames at this rate.
    var uplinkSampleRate: Double { get }

    /// Opens a realtime session seeded with the planned instructions and history,
    /// yielding unified events until the session ends.
    func openRealtimeSession(
        transport: RealtimeTransportInput
    ) -> AsyncThrowingStream<RealtimeSessionEvent, Error>
}
