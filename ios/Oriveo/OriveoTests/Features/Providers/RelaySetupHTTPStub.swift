import Foundation
@testable import Oriveo

/// A fake relay for the two-step add flow tests: each instance has its own host and requests are dispatched by host, so parallel suites never mix data.
/// The catalog is replayed by the key carried in the request; generation requests (any POST) are counted and their model ids recorded.
final class RelaySetupHTTPStub: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
    }

    let host: String
    private let lock = NSLock()
    private var catalogsBySecret: [String: Reply] = [:]
    private var generationReply = Reply(
        status: 200,
        body: #"{"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"length"}]}"#
    )
    private var requestLog: [String] = []
    private var generationLog: [String] = []

    init() {
        host = "relay-\(UUID().uuidString.prefix(8).lowercased()).test"
        RelaySetupHTTPStubProtocol.register(self)
    }

    var endpoint: String { "https://\(host)" }

    func catalog(secret: String, modelIDs: [String]) {
        let data = modelIDs.map { #"{"id":"\#($0)","object":"model","owned_by":"relay"}"# }.joined(separator: ",")
        lock.withLock { catalogsBySecret[secret] = Reply(status: 200, body: #"{"object":"list","data":[\#(data)]}"#) }
    }

    func catalog(secret: String, status: Int) {
        lock.withLock {
            catalogsBySecret[secret] = Reply(status: status, body: #"{"error":{"message":"rejected","type":"invalid_request_error"}}"#)
        }
    }

    func failGeneration(status: Int) {
        lock.withLock {
            generationReply = Reply(status: status, body: #"{"error":{"message":"upstream failed","type":"server_error"}}"#)
        }
    }

    /// All requests (in the form "GET /v1/models").
    var requests: [String] { lock.withLock { requestLog } }
    /// The model id of each generation request, in the order sent.
    var generationModels: [String] { lock.withLock { generationLog } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelaySetupHTTPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    fileprivate func reply(to request: URLRequest, body: Data?) -> Reply {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        lock.withLock { requestLog.append("\(method) \(path)") }
        if method == "POST" {
            let model = body
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["model"] as? String } ?? ""
            return lock.withLock {
                generationLog.append(model)
                return generationReply
            }
        }
        guard method == "GET", path == "/v1/models" else {
            return Reply(status: 404, body: "404 page not found")
        }
        let secret = Self.secret(in: request)
        return lock.withLock { catalogsBySecret[secret] } ?? Reply(status: 401, body: #"{"error":{"message":"missing key"}}"#)
    }

    private static func secret(in request: URLRequest) -> String {
        if let bearer = request.value(forHTTPHeaderField: "Authorization"), bearer.hasPrefix("Bearer ") {
            return String(bearer.dropFirst("Bearer ".count))
        }
        return request.value(forHTTPHeaderField: "x-api-key")
            ?? request.value(forHTTPHeaderField: "x-goog-api-key")
            ?? ""
    }
}

final class RelaySetupHTTPStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: RelaySetupHTTPStub] = [:]

    static func register(_ stub: RelaySetupHTTPStub) {
        lock.withLock { stubs[stub.host] = stub }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let stub = Self.lock.withLock({ Self.stubs[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = stub.reply(to: request, body: Self.bodyData(of: request))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": reply.status == 404 ? "text/plain" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension RelayQuickSetupFlow {
    /// For tests: discovery and the 1-token probe both go to the fake relay; family lookup sends no request.
    static func stubbed(_ stub: RelaySetupHTTPStub) -> RelayQuickSetupFlow {
        let session = RelaySetupHTTPStub.session()
        return RelayQuickSetupFlow(
            coordinator: CustomLLMSetupCoordinator(method: .relay),
            makeDiscoveryService: { RelayDiscoveryService(session: session, retryBackoff: []) },
            family: { _ in nil },
            cachedFamily: { _ in nil }
        )
    }
}
