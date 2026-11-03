import Foundation

/// Downloads a URL image right away in a foreground URLSession: http / https only, size cap,
/// whole-download timeout, no Content-Type check, platform default redirects. The body must
/// decode as png / jpeg / webp. Background transfer is a separate path.
///
/// Policy: `fetchPolicy` in `shared/model-contracts/image_response_samples.v1/index.json`.
nonisolated struct StudioImageFetcher: Sendable {
    nonisolated enum Policy {
        static let maxBytes = 31_457_280
        static let timeoutSeconds: TimeInterval = 60
        static let schemes: [String] = ["http", "https"]
        /// Some hosts send images as application/octet-stream: the decoded header decides.
        static let checkContentType = false
        static let redirects = "platform default"
    }

    static let defaultSession: URLSession = makeSession()

    /// `timeoutSeconds` bounds the whole download (resource timeout), not just idle time.
    static func makeSession(
        configuration: URLSessionConfiguration = .default,
        timeoutSeconds: TimeInterval = Policy.timeoutSeconds
    ) -> URLSession {
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        configuration.timeoutIntervalForResource = timeoutSeconds
        return URLSession(configuration: configuration)
    }

    let session: URLSession
    let maxBytes: Int

    init(session: URLSession = StudioImageFetcher.defaultSession, maxBytes: Int = Policy.maxBytes) {
        self.session = session
        self.maxBytes = maxBytes
    }

    private struct TooLarge: Error {}

    /// Non-http(s) URLs and bodies over the cap or not an image → decode_failed; non-2xx and
    /// transport errors → network; transport timeout → timeout.
    func fetch(_ url: URL) async -> Result<StudioImageResponse.Materialized, StudioImageResponse.Failure> {
        guard let scheme = url.scheme?.lowercased(), Policy.schemes.contains(scheme) else {
            return .failure(.decodeFailed)
        }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failure(.network)
            }
            if http.expectedContentLength > Int64(maxBytes) { return .failure(.decodeFailed) }
            let body = try await readBody(bytes, expected: http.expectedContentLength)
            return StudioImageResponse.materialized(body)
        } catch is TooLarge {
            return .failure(.decodeFailed)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.network)
        }
    }

    /// Reads the body into memory, stopping as soon as it passes `maxBytes`.
    private func readBody(_ bytes: URLSession.AsyncBytes, expected: Int64) async throws -> Data {
        var buffer: [UInt8] = []
        if expected > 0 { buffer.reserveCapacity(Int(min(expected, Int64(maxBytes)))) }
        for try await byte in bytes {
            guard buffer.count < maxBytes else { throw TooLarge() }
            buffer.append(byte)
        }
        return Data(buffer)
    }
}
