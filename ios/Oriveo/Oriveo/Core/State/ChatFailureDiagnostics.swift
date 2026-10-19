import Foundation

/// Per-send record of the failure scene. The error object only carries a semantic class, so the status code and the
/// upstream error body are lost at classification time; `BaseAPIService.mapHTTPError` and the in-stream error frame
/// record them here, and the sender's catch reads them (used for context-overflow recognition).
/// Same pattern as `RelayPreOutputRejection.Recorder` (TaskLocal, isolated per send task).
/// A later write overrides an earlier one: within one send task the final failure is the last attempt.
nonisolated final class ChatFailureDiagnostics: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var httpStatus: Int?
        /// The upstream error body text (first 32 KB of UTF-8), only for overflow recognition: never shown, logged or stored.
        var rawBody: String?
    }

    /// Byte limit kept for rawBody.
    static let rawBodyByteLimit = 32 * 1024

    static func truncatedRawBody(_ data: Data) -> String {
        String(decoding: data.prefix(rawBodyByteLimit), as: UTF8.self)
    }

    @TaskLocal static var current: ChatFailureDiagnostics?

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    private func replace(_ snapshot: Snapshot) {
        lock.lock(); defer { lock.unlock() }
        value = snapshot
    }

    /// The upstream answered non-2xx: record the status code and the body.
    static func recordHTTPFailure(statusCode: Int, body: Data) {
        current?.replace(Snapshot(httpStatus: statusCode, rawBody: truncatedRawBody(body)))
    }

    /// An error frame inside a 2xx stream / response.failed: there is no HTTP status, only the frame body.
    static func recordStreamErrorFrame(_ data: Data) {
        current?.replace(Snapshot(rawBody: truncatedRawBody(data)))
    }
}
