import Foundation

/// Text fallback after the upstream rejects a native file block (only for routes whose mode is `.alwaysWithTextFallback`).
///
/// Subscription and Relay routes use the same native routing as official direct routes, but there is no
/// guarantee the other end accepts file blocks. When a request carried native file blocks and the upstream
/// answered 400 / 404 / 413 / 415 / 422 before producing any output, the route is temporarily treated as
/// having no native file blocks, the delivery decision is run again, and the request is resent once. If the
/// resend is accepted, the process remembers that this protocol on this connection does not take file blocks
/// and goes straight to text from then on, saving a round trip. If the resend also fails (including text that
/// does not fit), or none of the native files in the rejected request has extracted text (scanned documents),
/// there is no fallback and the first error is thrown. Only the status code is inspected, never the error message.
nonisolated enum NativeFileFallback {

    /// The connection and route of one send. With a nil `connectionID` (a call without connection context) the fallback still happens, it is just not remembered.
    struct Scope: Sendable {
        let transport: AttachmentTransport
        let connectionID: UUID?

        /// The three protocols on a Relay that carry native file blocks.
        static func relayScope(_ transport: RelayTransport, connectionID: UUID?) -> Scope {
            Scope(
                transport: AttachmentTransportResolver.relay(transport),
                connectionID: connectionID
            )
        }

        static func codexSubscriptionScope(connectionID: UUID?) -> Scope {
            Scope(
                transport: .codexSubscription,
                connectionID: connectionID
            )
        }
    }

    static let fallbackStatusCodes: Set<Int> = [400, 404, 413, 415, 422]

    /// Record of one request attempt: which native files were carried, registered at build time, and the status code if the upstream rejects it.
    final class Attempt: @unchecked Sendable {
        let sendsTextOnly: Bool
        private let lock = NSLock()
        private var nativeFileCount = 0
        private var nativeFilesWithTextCount = 0
        private var rejectedStatusCode: Int?

        init(sendsTextOnly: Bool) { self.sendsTextOnly = sendsTextOnly }

        func recordNativeFiles(_ files: [Attachment]) {
            lock.lock(); defer { lock.unlock() }
            nativeFileCount += files.count
            nativeFilesWithTextCount += files.filter(NativeFileFallback.hasExtractedText).count
        }

        func recordRejection(statusCode: Int) {
            lock.lock(); defer { lock.unlock() }
            if rejectedStatusCode == nil { rejectedStatusCode = statusCode }
        }

        /// Whether this rejection is worth resending as text: the status code is in the fallback set and at least one of the native files sent has extracted text.
        var shouldRetryAsText: Bool {
            lock.lock(); defer { lock.unlock() }
            guard !sendsTextOnly, let rejectedStatusCode else { return false }
            return NativeFileFallback.fallbackStatusCodes.contains(rejectedStatusCode)
                && nativeFilesWithTextCount > 0
        }
    }

    @TaskLocal static var currentAttempt: Attempt?

    // MARK: - Memory (in process)

    private struct ConnectionKey: Hashable {
        let connectionID: UUID
        let transport: AttachmentTransport
    }

    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var textOnlyConnections: Set<ConnectionKey> = []

    static func isKnownTextOnly(connectionID: UUID?, transport: AttachmentTransport) -> Bool {
        guard let connectionID else { return false }
        memoryLock.lock(); defer { memoryLock.unlock() }
        return textOnlyConnections.contains(ConnectionKey(connectionID: connectionID, transport: transport))
    }

    private static func rememberTextOnly(_ scope: Scope) {
        guard let connectionID = scope.connectionID else { return }
        memoryLock.lock(); defer { memoryLock.unlock() }
        textOnlyConnections.insert(ConnectionKey(connectionID: connectionID, transport: scope.transport))
    }

    #if DEBUG
    static func resetMemoryForTesting() {
        memoryLock.lock(); defer { memoryLock.unlock() }
        textOnlyConnections.removeAll()
    }
    #endif

    /// For the pre-send check: when this connection is known not to accept file blocks, make the delivery decision as a text route.
    static func withKnownConnectionState<T>(
        connectionID: UUID?, transport: AttachmentTransport, _ body: () -> T
    ) -> T {
        guard isKnownTextOnly(connectionID: connectionID, transport: transport) else { return body() }
        return $currentAttempt.withValue(Attempt(sendsTextOnly: true), operation: body)
    }

    // MARK: - Delivery decision side

    /// The mode actually in effect for this route right now: `.off` while a text resend is under way or when this connection is known not to accept file blocks.
    static func effectiveMode(of profile: AttachmentTransportProfile) -> NativeFileMode {
        let mode = profile.effectiveNativeFiles
        guard mode == .alwaysWithTextFallback else { return mode }
        return currentAttempt?.sendsTextOnly == true ? .off : mode
    }

    static func hasExtractedText(_ attachment: Attachment) -> Bool {
        attachment.extractionErrorCode == nil && attachment.base64Data?.isEmpty == false
    }

    // MARK: - Sending side

    /// Wraps the "build the request, send it and get the response headers" step. `send` may be called twice and must rebuild the request each time.
    static func run<T>(_ scope: Scope, send: () async throws -> T) async throws -> T {
        guard scope.transport.profile.effectiveNativeFiles == .alwaysWithTextFallback,
              currentAttempt == nil else {
            return try await send()
        }
        if isKnownTextOnly(connectionID: scope.connectionID, transport: scope.transport) {
            return try await $currentAttempt.withValue(Attempt(sendsTextOnly: true)) { try await send() }
        }
        let first = Attempt(sendsTextOnly: false)
        do {
            return try await $currentAttempt.withValue(first) { try await send() }
        } catch let firstError {
            guard first.shouldRetryAsText, !Task.isCancelled else { throw firstError }
            let result: T
            do {
                result = try await $currentAttempt.withValue(Attempt(sendsTextOnly: true)) { try await send() }
            } catch {
                // Even as text it did not go out (the upstream still refuses, or the text does not fit): the problem is not the file block, so show the first error.
                throw firstError
            }
            rememberTextOnly(scope)
            return result
        }
    }
}
