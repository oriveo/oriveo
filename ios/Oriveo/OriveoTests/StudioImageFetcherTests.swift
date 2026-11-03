import Foundation
import Testing
@testable import Oriveo

/// URL image download policy and failure kinds from
/// `shared/model-contracts/image_response_samples.v1/index.json` (contractId
/// "image_response_samples.v1"): fetchPolicy constants and every fetchCases entry by name,
/// against a scripted URLProtocol.
@Suite("StudioImageFetcherTests")
struct StudioImageFetcherTests {
    private static func decodeCase(_ name: String) throws -> Data {
        let cases = try StudioImageResponseContractTests.group("decodeCases")
        let match = try #require(cases.first { $0["name"] as? String == name })
        let b64 = try #require(match["b64"] as? String)
        return try #require(Data(base64Encoded: b64))
    }

    @Test("fetchPolicy: constants equal the fixture, session uses the resource timeout")
    func fetchPolicy() throws {
        let index = try StudioImageResponseContractTests.index()
        let policy = try #require(index["fetchPolicy"] as? [String: Any])
        #expect(StudioImageFetcher.Policy.maxBytes == policy["maxBytes"] as? Int)
        #expect(StudioImageFetcher.Policy.timeoutSeconds == policy["timeoutSeconds"] as? Double)
        #expect(StudioImageFetcher.Policy.schemes == policy["schemes"] as? [String])
        #expect(StudioImageFetcher.Policy.checkContentType == policy["checkContentType"] as? Bool)
        #expect(StudioImageFetcher.Policy.redirects == policy["redirects"] as? String)

        #expect(StudioImageFetcher().maxBytes == StudioImageFetcher.Policy.maxBytes)
        #expect(StudioImageFetcher.defaultSession.configuration.timeoutIntervalForResource == StudioImageFetcher.Policy.timeoutSeconds)
        let custom = StudioImageFetcher.makeSession(configuration: .ephemeral, timeoutSeconds: 7)
        #expect(custom.configuration.timeoutIntervalForResource == 7)
    }

    @Test("fetchCases: every fixture case by name", .timeLimit(.minutes(1)))
    func fetchCases() async throws {
        let cases = try StudioImageResponseContractTests.group("fetchCases")
        #expect(cases.count == 9)
        let png = try Self.decodeCase("png_rgba_3x2")
        let html = try Self.decodeCase("not_an_image_html")
        let smallLimit = 1024
        let stubbed = StudioImageFetcher(session: StudioImageFetchStubProtocol.session())
        let limited = StudioImageFetcher(session: StudioImageFetchStubProtocol.session(), maxBytes: smallLimit)
        // Short resource timeout so the stalled stub hits the real session timeout quickly.
        let shortTimeout = StudioImageFetcher(session: StudioImageFetchStubProtocol.session(timeoutSeconds: 0.5))

        for testCase in cases {
            let name = try #require(testCase["name"] as? String)
            let expect = try #require(testCase["expect"] as? [String: Any])
            let base = "https://img.test/\(name)"
            var fetcher = stubbed
            var urls = [base]
            switch name {
            case "fetch_ok_png":
                StudioImageFetchStubProtocol.register(base, .body(status: 200, headers: ["Content-Type": "image/png"], data: png))
            case "fetch_ok_octet_stream_content_type":
                StudioImageFetchStubProtocol.register(
                    base, .body(status: 200, headers: ["Content-Type": "application/octet-stream"], data: png)
                )
            case "fetch_http_404":
                StudioImageFetchStubProtocol.register(base, .body(status: 404, headers: ["Content-Type": "image/png"], data: png))
            case "fetch_connection_error":
                StudioImageFetchStubProtocol.register(base, .failBeforeResponse(.cannotConnectToHost))
            case "fetch_timeout":
                fetcher = shortTimeout
                StudioImageFetchStubProtocol.register(base, .stallAfterResponse)
            case "fetch_content_length_over_limit":
                // The body itself is a valid png within the cap: only the declared length can reject it.
                fetcher = limited
                StudioImageFetchStubProtocol.register(
                    base,
                    .body(status: 200, headers: ["Content-Length": "\(smallLimit + 1)"], data: png)
                )
            case "fetch_body_over_limit_without_length":
                fetcher = limited
                StudioImageFetchStubProtocol.register(
                    base, .body(status: 200, headers: [:], data: png + Data(count: smallLimit + 1 - png.count), chunks: 4)
                )
            case "fetch_body_not_an_image":
                StudioImageFetchStubProtocol.register(base, .body(status: 200, headers: ["Content-Type": "image/png"], data: html))
            case "fetch_non_http_scheme":
                urls = ["ftp://img.test/\(name).png", "file:///tmp/\(name).png"]
                for url in urls {
                    StudioImageFetchStubProtocol.register(url, .body(status: 200, headers: [:], data: png))
                }
            default:
                Issue.record("unhandled fetch case \(name)")
                continue
            }

            for url in urls {
                let result = await fetcher.fetch(try #require(URL(string: url)))
                if expect["ok"] as? Bool == true {
                    let info = try #require(try? result.get(), "\(name) should succeed, got \(result)")
                    #expect(info.mime == expect["mime"] as? String, "\(name) mime")
                    #expect(info.width == expect["width"] as? Int, "\(name) width")
                    #expect(info.height == expect["height"] as? Int, "\(name) height")
                    #expect(info.bytes == png, "\(name) bytes")
                } else {
                    let wanted = try #require(StudioImageResponse.Failure(rawValue: expect["failure"] as? String ?? ""))
                    #expect(result == .failure(wanted), "\(name) \(url)")
                }
            }
            if name == "fetch_non_http_scheme" {
                for url in urls {
                    #expect(StudioImageFetchStubProtocol.hitCount(url) == 0, "\(url) must not be requested")
                }
            } else {
                #expect(StudioImageFetchStubProtocol.hitCount(base) == 1, "\(name) requested once")
            }
        }

        let viaMaterialize = await StudioImageResponse.materialize(
            .init(kind: .url, mime: nil, value: "https://img.test/fetch_ok_png", revisedPrompt: nil),
            fetcher: stubbed
        )
        #expect(viaMaterialize == .success(.init(bytes: png, mime: "image/png", width: 3, height: 2)))
    }
}

/// Scripted image host keyed by absolute URL, so cases never share a reply.
private final class StudioImageFetchStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case body(status: Int, headers: [String: String], data: Data, chunks: Int = 1)
        case failBeforeResponse(URLError.Code)
        /// Sends the response head, then neither body nor completion.
        case stallAfterResponse
    }

    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var hits: [String: Int] = [:]
    private static let lock = NSLock()

    static func register(_ url: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        replies[url] = reply
        hits[url] = 0
    }

    static func hitCount(_ url: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return hits[url] ?? 0
    }

    static func session(timeoutSeconds: TimeInterval = StudioImageFetcher.Policy.timeoutSeconds) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudioImageFetchStubProtocol.self]
        return StudioImageFetcher.makeSession(configuration: configuration, timeoutSeconds: timeoutSeconds)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://img.invalid")!
        let reply: Reply? = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.hits[url.absoluteString, default: 0] += 1
            return Self.replies[url.absoluteString]
        }()
        let response = { (status: Int, headers: [String: String]) in
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        switch reply {
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        case let .failBeforeResponse(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .stallAfterResponse:
            client?.urlProtocol(self, didReceive: response(200, ["Content-Type": "image/png"]), cacheStoragePolicy: .notAllowed)
        case let .body(status, headers, data, chunks):
            client?.urlProtocol(self, didReceive: response(status, headers), cacheStoragePolicy: .notAllowed)
            let size = max(1, (data.count + chunks - 1) / max(1, chunks))
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + size)
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
