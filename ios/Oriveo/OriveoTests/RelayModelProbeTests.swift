import Foundation
import Testing
@testable import Oriveo

/// Fake server: the catalog (GET .../models), the by-model view (GET /api/metadata/model-facts?view=by-model),
/// and the 1-token probe (POST to the generation endpoint) are all answered by it. A probe looks up "model@short-protocol" in a table; anything not listed gets 404.
private final class RelayProbeFakeServer: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int, Data)
        case sse(String)
        case html(String)
        case network
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Data?) -> Reply)?
    nonisolated(unsafe) private static var requests: [(URLRequest, Data?)] = []

    static func install(_ value: @escaping (URLRequest, Data?) -> Reply) {
        lock.withLock {
            handler = value
            requests = []
        }
    }

    static func captured() -> [(URLRequest, Data?)] {
        lock.withLock { requests }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayProbeFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        let reply: Reply = Self.lock.withLock {
            Self.requests.append((request, body))
            return Self.handler?(request, body) ?? .status(404, Data())
        }
        switch reply {
        case .network:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case let .sse(payload):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .html(page):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(page.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .status(code, data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4_096)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Relay 2.0 per-model probe orchestration (`shared/test-fixtures/relay/probe-orchestration.v1.json` and
/// `gateway-models.v1.json`). The catalog goes through the production `RelayDiscoveryService`, the family lookup through the production `MetadataClient`,
/// probes go through the production `OpenAIService.pingRelay` against the fake server, and write-back is asserted after a round trip through production Codable.
@Suite("Relay 2.0 - per-model probe orchestration", .serialized)
@MainActor
struct RelayModelProbeTests {

    // MARK: - Fixtures

    private static func fixture(_ name: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func orchestration() throws -> [String: Any] {
        try fixture("probe-orchestration.v1.json")
    }

    /// Short name -> wire protocol value (fixture `transports`).
    private static func transports() throws -> [String: RelayTransport] {
        let raw = try #require(try orchestration()["transports"] as? [String: String])
        return try raw.mapValues { try #require(RelayTransport(rawValue: $0)) }
    }

    private static func shortNames(_ candidates: [RelayTransport]) throws -> [String] {
        let table = try transports()
        return candidates.map { candidate in
            table.first { $0.value == candidate }?.key ?? "<\(candidate.rawValue)>"
        }
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// RL2-PROBE-06: without pressing the button there are 0 capability-test requests: the request bodies this fake server received must not contain
    /// the built-in image base64 of `capability-test.v1.json` (including the `\/`-escaped form) or the built-in tool name.
    private static func expectNoCapabilityTestRequests(_ label: String) throws {
        let builtins = try #require(try fixture("capability-test.v1.json")["builtins"] as? [String: Any])
        let image = try #require(builtins["imagePNGBase64"] as? String)
        let tool = try #require((builtins["tool"] as? [String: Any])?["name"] as? String)
        for (_, body) in RelayProbeFakeServer.captured() {
            let text = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            #expect(!text.contains(image), "\(label): sent the built-in test image")
            #expect(!text.contains(image.replacingOccurrences(of: "/", with: "\\/")), "\(label): sent the built-in test image")
            #expect(!text.contains(tool), "\(label): sent the built-in test tool")
        }
    }

    /// The (model, short protocol) of a probe request. The protocol is identified from the request path; a Gemini model is in the path.
    private static func probeKey(_ request: URLRequest, body: Data?) -> (model: String, short: String)? {
        guard request.httpMethod == "POST", let url = request.url else { return nil }
        let path = url.path
        let bodyModel = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["model"]
            as? String
        if path.hasSuffix("/chat/completions") { return bodyModel.map { ($0, "chat") } }
        if path.hasSuffix("/responses") { return bodyModel.map { ($0, "responses") } }
        if path.hasSuffix("/messages") { return bodyModel.map { ($0, "messages") } }
        if path.hasSuffix(":generateContent") {
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            return (String(last.dropLast(":generateContent".count)), "gemini")
        }
        return nil
    }

    /// Each outcome name in the fixture's `probeOutcomeRules` -> a fake-server response. An unknown name fails the case outright instead of silently becoming a 404.
    private static func reply(for outcome: String) -> RelayProbeFakeServer.Reply {
        switch outcome {
        case "ok": return .status(200, json(["id": "probe", "choices": [], "content": []]))
        case "http_400": return .status(400, json(["error": ["message": "bad request"]]))
        case "http_401": return .status(401, json(["error": ["message": "invalid api key"]]))
        case "http_403": return .status(403, json(["error": ["message": "\u{8BE5}\u{4EE4}\u{724C}\u{65E0}\u{6743}\u{8BBF}\u{95EE}\u{6A21}\u{578B}"]]))
        case "http_403_route":
            // Take the response body verbatim from the protocolFallbackCases entry that carries the registered phrase (upstream original text, slashes not escaped).
            let body = (try? fixture("negative-cache.v1.json"))
                .flatMap { $0["protocolFallbackCases"] as? [[String: Any]] }?
                .first { $0["caseId"] as? String == "status_403_with_route_phrase_tries_next_candidate" }
                .flatMap { $0["body"] as? String }
            if body == nil { Issue.record("negative-cache.v1.json is missing a 403 case carrying the registered phrase") }
            return .status(403, Data((body ?? "").utf8))
        case "http_404": return .status(404, json(["error": ["message": "not found"]]))
        case "http_405": return .status(405, json(["error": ["message": "method not allowed"]]))
        case "http_415": return .status(415, json(["error": ["message": "unsupported media type"]]))
        case "http_422": return .status(422, json(["error": ["message": "unprocessable"]]))
        case "http_429": return .status(429, json(["error": ["message": "rate limited"]]))
        case "http_5xx": return .status(503, json(["error": ["message": "upstream unavailable"]]))
        case "html_200": return .html("<!doctype html><html><head><title>Relay</title></head><body></body></html>")
        case "network": return .network
        default:
            Issue.record("fixture outcome name has no matching fake-server response: \(outcome)")
            return .status(404, json(["error": ["message": "not found"]]))
        }
    }

    /// The three groups of outcome names in the fixture's `probeOutcomeRules`.
    private static func outcomeRules() throws -> (pass: [String], routeRejected: [String], inconclusive: [String]) {
        let rules = try #require(try orchestration()["probeOutcomeRules"] as? [String: Any])
        return (
            try #require(rules["pass"] as? [String]),
            try #require(rules["routeRejected"] as? [String]),
            try #require(rules["inconclusive"] as? [String])
        )
    }

    // MARK: - RL2-PROBE-01

    @Test("RL2-PROBE-01 candidate order: the production catalog parse keeps supported_endpoint_types, and per model equals gateway-models expected.candidates")
    func rl2Probe01CandidatesFromGatewayEndpointTypes() async throws {
        // The rule table equals the fixture's candidateRules item by item.
        let rules = try #require(try Self.orchestration()["candidateRules"] as? [String: Any])
        let table = try Self.transports()
        let endpointMap = try #require(rules["endpointTypeToCandidate"] as? [String: String])
        #expect(RelayProbeCandidates.endpointTypeToCandidate == endpointMap.compactMapValues { table[$0] })
        let families = try #require(rules["familyCandidates"] as? [String: [String]])
        #expect(RelayProbeCandidates.familyCandidates == families.mapValues { $0.compactMap { table[$0] } })
        #expect(
            RelayProbeCandidates.defaultCandidates
                == (rules["defaultCandidates"] as? [String] ?? []).compactMap { table[$0] }
        )
        #expect(RelayProbeCandidates.maxCandidates == rules["maxCandidates"] as? Int)

        let gateway = try #require(
            ((try Self.fixture("gateway-models.v1.json")["gateways"] as? [String: Any])?["new_api"])
                as? [String: Any]
        )
        let record = try #require((gateway["records"] as? [[String: Any]])?.first)
        let body = try #require((record["response"] as? [String: Any])?["body"])
        let expected = try #require((gateway["expected"] as? [String: Any])?["candidates"] as? [String: [String]])

        let endpoint = "https://gateway-probe-01.example.com"
        RelayProbeFakeServer.install { request, _ in
            request.url?.path.hasSuffix("/models") == true ? .status(200, Self.json(body)) : .status(404, Data())
        }
        let result = try await RelayDiscoveryService(session: RelayProbeFakeServer.session(), retryBackoff: [])
            .discover(endpoint: endpoint, apiKey: "sk-test", modelHint: nil)
        let detection = try #require(result.detections.first)
        #expect(Set(detection.modelIDs) == Set(expected.keys))

        for (modelID, expect) in expected {
            let types = detection.endpointTypesByModel[modelID]
            // The per-connection in-memory cache holds the same values as this catalog result.
            #expect(RelayCatalogEndpointTypesCache.shared.endpointTypes(endpoint: endpoint, modelID: modelID) == types)
            var familyAsked = false
            let candidates = await RelayProbeCandidates.candidates(supportedEndpointTypes: types) {
                familyAsked = true
                return nil
            }
            #expect(try Self.shortNames(candidates) == expect, "\(modelID)")
            #expect(!familyAsked, "\(modelID): the family should not be queried when endpoint types have a result")
        }
    }

    // MARK: - RL2-PROBE-02

    @Test("RL2-PROBE-02 familyCases: the fake by-model service is queried via the production MetadataClient; normalization + last-segment fallback; when unavailable only chat is tried")
    func rl2Probe02FamilyCases() async throws {
        let contract = try Self.orchestration()
        let byModel = try #require(contract["byModelResponse"])
        let cases = try #require(contract["familyCases"] as? [[String: Any]])
        #expect(cases.count == 9)

        for item in cases {
            let caseId = item["caseId"] as? String ?? "<no id>"
            let modelID = try #require(item["modelId"] as? String)
            let unavailable = item["byModelUnavailable"] as? Bool ?? false
            RelayProbeFakeServer.install { request, _ in
                guard let url = request.url, url.path.hasSuffix("/api/metadata/model-facts"),
                      url.query?.contains("view=by-model") == true else { return .status(404, Data()) }
                return unavailable ? .status(503, Data()) : .status(200, Self.json(byModel))
            }
            let client = MetadataClient(session: RelayProbeFakeServer.session(), allowsNetworkRequestsInTests: true)
            await client.resetForTesting()

            let candidates = await RelayProbeCandidates.candidates(
                supportedEndpointTypes: item["supportedEndpointTypes"] as? [String]
            ) {
                await client.relayModelFamily(for: modelID)
            }
            #expect(try Self.shortNames(candidates) == item["expect"] as? [String], "\(caseId)")

            let viewRequests = RelayProbeFakeServer.captured().filter {
                $0.0.url?.path.hasSuffix("/api/metadata/model-facts") == true
            }
            let needsFamily = RelayProbeCandidates.fromEndpointTypes(item["supportedEndpointTypes"] as? [String]).isEmpty
            #expect(viewRequests.count == (needsFamily ? 1 : 0), "\(caseId): fetched lazily once, only when the family is needed")
        }

        // When endpoint types have a result, by-model is not fetched at all.
        RelayProbeFakeServer.install { _, _ in .status(200, Self.json(byModel)) }
        let client = MetadataClient(session: RelayProbeFakeServer.session(), allowsNetworkRequestsInTests: true)
        await client.resetForTesting()
        let typed = await RelayProbeCandidates.candidates(supportedEndpointTypes: ["openai-response", "openai"]) {
            await client.relayModelFamily(for: "claude-sonnet-4-5")
        }
        #expect(try Self.shortNames(typed) == ["responses", "chat"])
        #expect(RelayProbeFakeServer.captured().isEmpty)

        // After one fetch it is cached in memory, and a second model does not request again.
        _ = await client.relayModelFamily(for: "gpt-5")
        _ = await client.relayModelFamily(for: "gemini-2.5-pro")
        #expect(RelayProbeFakeServer.captured().count == 1)
    }

    // MARK: - RL2-PROBE-03

    // MARK: - RD2-ROUTE (fixture generationRouteCases: when only a generation route is detected, the detected protocol goes first, followed by candidateRules)

    private func runGenerationRoute(_ caseId: String) async throws {
        let contract = try Self.orchestration()
        let section = try #require(contract["generationRouteCases"] as? [String: Any])
        let cases = try #require(section["cases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["caseId"] as? String == caseId }, "fixture is missing \(caseId)")
        let routeName = try #require(item["route"] as? String)
        let route = try #require(try Self.transports()[routeName])
        let modelID = try #require(item["modelId"] as? String)
        let byModel = try #require(contract["byModelResponse"])
        RelayProbeFakeServer.install { request, _ in
            guard let url = request.url, url.path.hasSuffix("/api/metadata/model-facts") else { return .status(404, Data()) }
            return .status(200, Self.json(byModel))
        }
        let client = MetadataClient(session: RelayProbeFakeServer.session(), allowsNetworkRequestsInTests: true)
        await client.resetForTesting()
        let candidates = await RelayProbeCandidates.generationRouteCandidates(
            route: route,
            supportedEndpointTypes: nil,
            family: { await client.relayModelFamily(for: modelID) }
        )
        #expect(try Self.shortNames(candidates) == item["expect"] as? [String], "\(caseId)")
        #expect(candidates.count <= RelayProbeCandidates.maxCandidates)
    }

    @Test("RD2-ROUTE-unknown_family_route_then_default") func routeUnknownFamily() async throws {
        try await runGenerationRoute("unknown_family_route_then_default")
    }

    @Test("RD2-ROUTE-route_first_then_family_capped_at_two") func routeFirstThenFamily() async throws {
        try await runGenerationRoute("route_first_then_family_capped_at_two")
    }

    @Test("RD2-ROUTE-route_already_in_family_is_not_repeated") func routeAlreadyInFamily() async throws {
        try await runGenerationRoute("route_already_in_family_is_not_repeated")
    }

    @Test("RD2-ROUTE every caseId in the fixture has a same-named test; step 2 of adding saves the detected generation route and passes it into verification")
    func generationRouteCasesCoveredAndWired() throws {
        let section = try #require(try Self.orchestration()["generationRouteCases"] as? [String: Any])
        let ids = try #require(section["cases"] as? [[String: Any]]).compactMap { $0["caseId"] as? String }
        #expect(ids == [
            "unknown_family_route_then_default",
            "route_first_then_family_capped_at_two",
            "route_already_in_family_is_not_repeated",
        ])
        let source = try ProductionSource.read("Features/Providers/RelaySetupTwoStep.swift")
        #expect(source.contains("generationRoute: detected.flatMap { $0.detectionEvidence == .generationProbe ? $0.transport : nil }"))
        #expect(!source.contains("endpointTypes(for:"))
    }

    @Test("RL2-PROBE-03 add_* scenarios: production catalog -> production ping against the fake server -> write-back through a production Codable round trip")
    func rl2Probe03AddScenarios() async throws {
        let contract = try Self.orchestration()
        let scenarios = try #require(contract["scenarios"] as? [[String: Any]])
            .filter { $0["test"] as? String == "RL2-PROBE-03" }
        #expect(scenarios.compactMap { $0["caseId"] as? String } == [
            "add_probes_only_the_default_model",
            "add_moves_to_the_second_candidate_when_the_first_fails",
            "add_with_a_user_chosen_connection_protocol_verifies_on_it_and_pins_nothing",
            "add_with_every_candidate_failing_is_not_verified_and_pins_nothing",
            "add_stops_at_an_inconclusive_first_candidate_and_is_not_verified",
        ])
        let table = try Self.transports()

        for scenario in scenarios {
            let caseId = scenario["caseId"] as? String ?? "<no id>"
            let connection = try #require(scenario["connection"] as? [String: Any])
            let endpoint = try #require(connection["baseURL"] as? String)
            let rawTransport = try #require(connection["transport"] as? String)
            let connectionTransport = try #require(RelayTransport(rawValue: rawTransport))
            let models = try #require(scenario["models"] as? [[String: Any]])
            let defaultModel = try #require(scenario["defaultModel"] as? String)
            let pingTable = scenario["ping"] as? [String: String] ?? [:]
            let expect = try #require(scenario["expect"] as? [String: Any])

            let catalog: [String: Any] = [
                "object": "list",
                "data": models.map { model -> [String: Any] in
                    var entry: [String: Any] = ["id": model["id"] as Any, "object": "model"]
                    if let types = model["supportedEndpointTypes"] { entry["supported_endpoint_types"] = types }
                    return entry
                },
            ]
            RelayProbeFakeServer.install { request, body in
                if request.httpMethod == "GET", request.url?.path.hasSuffix("/models") == true {
                    return .status(200, Self.json(catalog))
                }
                guard let key = Self.probeKey(request, body: body) else { return .status(404, Data()) }
                return Self.reply(for: pingTable["\(key.model)@\(key.short)"] ?? "http_404")
            }

            // Production catalog discovery: obtains the detection (root address, auth, endpoint types). The fixture does not specify the catalog protocol:
            // when the user picked a protocol, the catalog also discovers under that protocol (same shape as when the address carries its own protocol); otherwise the hint-less Chat order applies.
            let session = RelayProbeFakeServer.session()
            let userChosen: RelayTransport? = connectionTransport == .auto ? nil : connectionTransport
            let discovery = try await RelayDiscoveryService(session: session, retryBackoff: [])
                .discover(endpoint: endpoint, apiKey: "sk-test", modelHint: userChosen == nil ? nil : defaultModel)
            let detection = try #require(discovery.detections.first, "\(caseId)")
            let requested = RelayAddVerification.connectionRequested(
                detection: detection,
                explicitTransport: userChosen ?? discovery.descriptor.explicitTransport,
                formAuthMode: .auto,
                securityMode: .remoteHTTPS,
                modelID: defaultModel
            )
            let requestsBeforeProbe = RelayProbeFakeServer.captured().count

            let service = OpenAIService(session: session)
            let result = try await RelayAddVerification.run(
                endpoint: endpoint,
                requested: requested,
                userChosenTransport: userChosen,
                modelID: defaultModel,
                supportedEndpointTypes: detection.endpointTypesByModel[defaultModel],
                family: { nil },
                ping: { routed, model in
                    _ = try await service.pingRelay(
                        apiKey: "sk-test", baseURL: endpoint, modelID: model, relayRequested: routed
                    )
                }
            )

            // The probe requests actually sent (production request objects) equal the fixture item by item; every other model gets 0 requests.
            let probes = RelayProbeFakeServer.captured().dropFirst(requestsBeforeProbe)
            let sent = probes.compactMap { Self.probeKey($0.0, body: $0.1) }.map { [$0.model, $0.short] }
            #expect(sent == expect["pings"] as? [[String]], "\(caseId)")
            #expect(probes.count == sent.count, "\(caseId): there should be no requests beyond the probes")
            #expect(result.verified == expect["verified"] as? Bool, "\(caseId)")
            try Self.expectNoCapabilityTestRequests("\(caseId) add")

            // Write back following the save flow: a registration-shaped provider + connection config + the default model's probe conclusion, then a round trip through production Codable.
            var provider = TestFactories.makeProvider(
                kind: .relay,
                models: models.map {
                    TestFactories.makeModel(id: $0["id"] as? String ?? "", isDefault: $0["id"] as? String == defaultModel)
                },
                baseURLText: endpoint
            )
            provider.relayRequested = requested
            if result.verified, let outcome = result.modelOutcome {
                RelayModelProbe.apply(outcome, modelID: defaultModel, to: &provider)
            }
            let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(provider))

            #expect(stored.relayRequested?.transport.rawValue == expect["connectionTransport"] as? String, "\(caseId)")
            #expect(
                stored.relayRequested?.resolvedAPIBaseURLs ?? [:]
                    == expect["resolvedAPIBaseURLs"] as? [String: String] ?? [:],
                "\(caseId)"
            )
            // Discovery root: only when the discovery protocol equals the connection's actual default (auto means Chat) is the legacy single-value field written.
            let actualDefault = userChosen ?? .openaiChatCompletions
            #expect(
                stored.relayRequested?.resolvedAPIBaseURL
                    == (detection.transport == actualDefault ? detection.apiBaseURL : nil),
                "\(caseId)"
            )

            let expectedModels = try #require(expect["models"] as? [String: [String: String]])
            for (modelID, fields) in expectedModels {
                let model = try #require(stored.models.first { $0.id == modelID }, "\(caseId) \(modelID)")
                #expect(model.relayTransport?.rawValue == fields["relayTransport"], "\(caseId) \(modelID)")
                #expect(
                    model.relayTransportSource?.rawValue == fields["relayTransportSource"],
                    "\(caseId) \(modelID)"
                )
            }

            // For the probe sent on a pass, the root address is the one written into resolvedAPIBaseURLs.
            if let outcome = result.modelOutcome,
               let passed = probes.last?.0.url?.absoluteString {
                #expect(passed.hasPrefix(outcome.apiRoot + "/"), "\(caseId): \(passed)")
                #expect(table.values.contains(outcome.transport))
            }
        }
    }

    // MARK: - Unit tests

    @Test("RL2-PROBE-03 probing one model: stop on pass; only a route-level rejection moves to the next, trying at most two candidates; any other failure stops immediately")
    func rl2Probe03ProbeOneModelStopsAtFirstPass() async throws {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "m")],
            baseURLText: "https://relay.example.com"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: .auto,
            authMode: .bearer,
            resolvedAPIBaseURLs: ["gemini_generate_content": "https://relay.example.com/g/v1beta"]
        )
        // Route-level rejection (the upstream HTTP failure is recorded into the current recorder by the production recording point): move to the next, at most two.
        var tried: [RelayTransport?] = []
        var failures: [Int?] = []
        let none = try await RelayModelProbe.probe(
            provider: provider,
            model: provider.models[0],
            candidates: [.anthropicMessages, .openaiResponses, .geminiGenerateContent],
            onFailure: { _, rejection in failures.append(rejection?.status) }
        ) { routed, _ in
            tried.append(RelayEndpointResolver.injectedTransport(routed))
            RelayPreOutputRejection.current?.record(status: 404, contentType: "application/json", body: Data())
            throw ProviderServiceError.upstream(statusCode: 404, detail: "not found")
        }
        #expect(none == nil)
        #expect(tried == [.anthropicMessages, .openaiResponses])
        #expect(failures == [404, 404])

        // No HTTP response (network error) = inconclusive: stop at the first candidate.
        tried = []
        let stopped = try await RelayModelProbe.probe(
            provider: provider,
            model: provider.models[0],
            candidates: [.anthropicMessages, .openaiResponses]
        ) { routed, _ in
            tried.append(RelayEndpointResolver.injectedTransport(routed))
            throw ProviderServiceError.network(detail: "down")
        }
        #expect(stopped == nil)
        #expect(tried == [.anthropicMessages])

        // The criterion for the three outcomes: a route-level rejection is the very decision function used for send-time protocol fallback.
        let phrase = try #require(RelayProtocolFallback.phrases.first)
        func rejection(_ status: Int, _ body: String = "") -> RelayPreOutputRejection {
            RelayPreOutputRejection(status: status, contentType: "application/json", body: Data(body.utf8))
        }
        for status in [404, 405, 415] {
            #expect(RelayModelProbe.classify(rejection(status)) == .routeRejected, "\(status)")
        }
        #expect(RelayModelProbe.classify(rejection(403, "{\"message\":\"\(phrase.uppercased())\"}")) == .routeRejected)
        for status in [400, 401, 403, 422, 429, 500, 502, 503] {
            #expect(RelayModelProbe.classify(rejection(status)) == .inconclusive, "\(status)")
        }
        #expect(RelayModelProbe.classify(nil) == .inconclusive)
        let probeSource = try ProductionSource.read("Core/Providers/RelayModelProbe.swift")
        #expect(probeSource.contains("RelayProtocolFallback.isRouteRejection(rejection)"))
        #expect(RelayModelProbe.classify(
            RelayPreOutputRejection(status: 200, contentType: "text/html", body: Data("<html></html>".utf8))
        ) == .routeRejected)
        #expect(!probeSource.contains("404"))

        let outcome = try await RelayModelProbe.probe(
            provider: provider,
            model: provider.models[0],
            candidates: [.geminiGenerateContent]
        ) { routed, _ in
            #expect(RelayEndpointResolver.injectedAPIRoot(routed) == "https://relay.example.com/g/v1beta")
        }
        let passed = try #require(outcome)
        #expect(passed == .init(transport: .geminiGenerateContent, apiRoot: "https://relay.example.com/g/v1beta"))

        RelayModelProbe.apply(
            .init(transport: .anthropicMessages, apiRoot: "https://relay.example.com/v1"),
            modelID: "m",
            to: &provider
        )
        #expect(provider.models[0].relayTransport == .anthropicMessages)
        #expect(provider.models[0].relayTransportSource == .reachable)
        #expect(provider.relayRequested?.transport == .auto)
        #expect(provider.relayRequested?.resolvedAPIBaseURLs == [
            "gemini_generate_content": "https://relay.example.com/g/v1beta",
            "anthropic_messages": "https://relay.example.com/v1",
        ])
    }

    @Test("Production probe: a 403 body whose registered phrase has its slash written as \\/ is still a route-level rejection and moves to the next candidate; a 403 without the phrase stops immediately")
    func d75ProbeTreatsEscapedSlashRoutePhraseAsRouteRejection() async throws {
        let endpoint = "https://relay.example.com"
        let model = TestFactories.makeModel(id: "escaped-slash-model", capabilities: [.text])
        let provider = Self.relayProvider(endpoint: endpoint, transport: .auto, models: [model], catalogModels: [model])
        let phrase = try #require(RelayProtocolFallback.phrases.first)
        // Foundation's JSON encoder writes `/` as `\/` by default: this body is the escaped form an upstream returns from raw JSON.
        let escaped = Self.json(["type": "error", "error": ["type": "permission_error", "message": "This group \(phrase)"]])
        #expect(String(decoding: escaped, as: UTF8.self).contains(#"\/v1\/messages"#))
        let service = OpenAIService(session: RelayProbeFakeServer.session())
        let passed = Self.json(["id": "probe", "choices": [], "content": []])

        func probe(messagesReply: Data) async throws -> (outcome: RelayModelProbe.Outcome?, tried: [String], statuses: [Int?]) {
            RelayProbeFakeServer.install { request, _ in
                (request.url?.path ?? "").hasSuffix("/messages") ? .status(403, messagesReply) : .status(200, passed)
            }
            var statuses: [Int?] = []
            let outcome = try await RelayModelProbe.probe(
                provider: provider,
                model: model,
                candidates: [.anthropicMessages, .openaiChatCompletions],
                onFailure: { _, rejection in statuses.append(rejection?.status) }
            ) { routed, modelID in
                _ = try await service.pingRelay(
                    apiKey: provider.apiKey, baseURL: endpoint, modelID: modelID, relayRequested: routed
                )
            }
            let tried = RelayProbeFakeServer.captured().compactMap { $0.0.url?.lastPathComponent }
            return (outcome, tried, statuses)
        }

        let switched = try await probe(messagesReply: escaped)
        #expect(switched.statuses == [403])
        #expect(switched.tried == ["messages", "completions"], "\(switched.tried)")
        #expect(switched.outcome?.transport == .openaiChatCompletions)

        // Same status code, but the body has no registered phrase (also with escaped slashes): a key / account problem, so the same key is not used to send the next candidate.
        let stopped = try await probe(
            messagesReply: Self.json(["error": ["message": "token has no access to /v1/messages"]])
        )
        #expect(stopped.statuses == [403])
        #expect(stopped.tried == ["messages"], "\(stopped.tried)")
        #expect(stopped.outcome == nil)
    }

    // MARK: - Probe = the chat request reduced to a one-sentence conversation

    /// Two requests captured at the HTTP seam for the same connection and the same model: the production probe (`pingRelay`) and a real chat send
    /// (`AppState.sendMessage`, with a single user message).
    private static func probeAndChatRequests(
        _ transport: RelayTransport
    ) async throws -> (probe: (URLRequest, [String: Any]), chat: (URLRequest, [String: Any])) {
        let endpoint = "https://relay.example.com"
        let modelID = "shape-model"
        let model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        var provider = relayProvider(endpoint: endpoint, transport: transport, models: [model], catalogModels: [model])
        // Turn on identity / storage / cache fields so the same-shape constraint can bite on them.
        provider.relayRequested?.authMode = .auto
        provider.relayRequested?.disableResponseStorage = true
        provider.relayRequested?.codexCompatIdentity = true
        provider.relayRequested?.serviceTier = "priority"
        // Stale connection-level thinking level is invalidated at read time: leave it in to prove it enters neither the probe nor the chat.
        provider.relayRequested?.reasoningEffort = .low
        let session = RelayProbeFakeServer.session()
        func object(_ data: Data?) throws -> [String: Any] {
            let body = try #require(data)
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }

        RelayProbeFakeServer.install { _, _ in .status(200, json(["id": "probe", "choices": [], "content": []])) }
        _ = try await OpenAIService(session: session).pingRelay(
            apiKey: provider.apiKey, baseURL: endpoint, modelID: modelID,
            relayRequested: RelayEndpointResolver.routedRequested(provider: provider, model: model)
        )
        let probes = RelayProbeFakeServer.captured()
        #expect(probes.count == 1, "\(transport.rawValue): the probe sends exactly one request")
        let probe = try #require(probes.first)

        // The chat request comes from the real send chain (ChatManager -> production builder), with the capability-evidence context present;
        // this turn picks a non-auto thinking level: chat then carries a thinking field, so the "probe does not carry it" assertion has something to catch.
        var selection = ChatCapabilitySelection()
        selection.reasoningMode = .deep
        RelayProbeFakeServer.install { request, _ in .sse(sseBody(for: request)) }
        let state = makeState()
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .relay, modelID: modelID
        )
        state.upsertConversationProjection(conversation)
        _ = await state.sendMessage("ping", in: conversation.id, capabilitySelection: selection)
        let deadline = ContinuousClock.now + .seconds(10)
        func settled() -> Bool {
            guard let last = state.conversations.first(where: { $0.id == conversation.id })?.messages.last,
                  last.role == .assistant else { return false }
            return [.delivered, .failed].contains(last.state)
        }
        while !settled(), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let chat = try #require(
            RelayProbeFakeServer.captured().first { $0.0.httpMethod == "POST" },
            "\(transport.rawValue): the chat request did not reach the HTTP seam"
        )
        return ((probe.0, try object(probe.1)), (chat.0, try object(chat.1)))
    }

    /// Top-level request-body keys that belong to "content / generation parameters": conversation content, system prompt, streaming, tools, thinking, sampling parameters, output cap.
    /// Keys present in chat but not in the probe may fall only here; identity / storage / cache fields are not on the list, so a missing one fails.
    private static let contentAndGenerationKeys: Set<String> = [
        "messages", "input", "contents",
        "system", "instructions", "systemInstruction",
        "stream", "stream_options",
        "tools", "tool_choice", "parallel_tool_calls",
        "reasoning", "reasoning_effort", "thinking", "output_config",
        "temperature", "top_p", "top_k",
        "max_tokens", "max_completion_tokens", "max_output_tokens", "generationConfig",
    ]

    private static let probedTransports: [RelayTransport] = [
        .openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent,
    ]

    @Test("Probe and chat share one shape: the request header name sets are equal across the four protocols, and extra top-level body keys in chat fall only within the content / generation-parameter allowlist")
    func d75ProbeHasTheSameShapeAsChat() async throws {
        for transport in Self.probedTransports {
            let (probe, chat) = try await Self.probeAndChatRequests(transport)
            let label = transport.rawValue
            func headerNames(_ request: URLRequest) -> Set<String> {
                Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
            }
            #expect(headerNames(probe.0) == headerNames(chat.0), "\(label)")
            #expect(probe.0.httpMethod == chat.0.httpMethod, "\(label)")
            #expect(probe.0.url?.host == chat.0.url?.host, "\(label)")

            let probeKeys = Set(probe.1.keys), chatKeys = Set(chat.1.keys)
            #expect(chatKeys.subtracting(probeKeys).isSubset(of: Self.contentAndGenerationKeys),
                    "\(label): in chat but not in probe \(chatKeys.subtracting(probeKeys).sorted())")
            #expect(probeKeys.subtracting(chatKeys).isSubset(of: Self.contentAndGenerationKeys),
                    "\(label): in probe but not in chat \(probeKeys.subtracting(chatKeys).sorted())")
            // Fields present on both sides that are not content / generation parameters (model, storage, cache key, ...) are equal value by value.
            for key in probeKeys.intersection(chatKeys).subtracting(Self.contentAndGenerationKeys) {
                #expect(
                    (probe.1[key] as? NSObject) == (chat.1[key] as? NSObject),
                    "\(label) \(key): probe \(String(describing: probe.1[key])) chat \(String(describing: chat.1[key]))"
                )
            }
            // The probe does not stream and carries no tools or thinking fields (even when chat picked a non-auto thinking level this turn).
            #expect(probe.1["stream"] == nil, "\(label)")
            for key in Self.toolAndReasoningKeys {
                #expect(probe.1[key] == nil, "\(label) \(key)")
            }
            #expect((probe.1["generationConfig"] as? [String: Any])?["thinkingConfig"] == nil, "\(label)")
        }
        // The assertion is not vacuous: the same connection's chat request really carries this turn's thinking level (not the stored low) and the default tools.
        let chatCompletions = try await Self.probeAndChatRequests(.openaiChatCompletions).chat.1
        #expect(chatCompletions["reasoning_effort"] as? String == "high")
        let responses = try await Self.probeAndChatRequests(.openaiResponses).chat.1
        #expect(responses["reasoning"] != nil)
        #expect(responses["tools"] != nil)
        // The probe still carries identity / storage / cache fields.
        let responsesProbe = try await Self.probeAndChatRequests(.openaiResponses).probe.1
        #expect(responsesProbe["store"] as? Bool == false)
        #expect(responsesProbe["service_tier"] as? String == "priority")
        #expect(responsesProbe["prompt_cache_key"] as? String == responses["prompt_cache_key"] as? String)
        #expect(responsesProbe["prompt_cache_key"] != nil)
    }

    private static let toolAndReasoningKeys = [
        "tools", "tool_choice", "parallel_tool_calls",
        "reasoning", "reasoning_effort", "thinking", "output_config", "thinkingConfig",
    ]

    @Test("Responses probe output cap is 16 while the other protocols stay at 1 (fixture probeRequestRules)")
    func d75ResponsesProbeOutputCapIs16() async throws {
        let rules = try #require(try Self.orchestration()["probeRequestRules"] as? [String: Any])
        let responsesCap = try #require(rules["responsesMaxOutputTokens"] as? Int)
        let otherCap = try #require(rules["otherProtocolsMaxTokens"] as? Int)
        #expect(responsesCap == 16)
        #expect(RelayModelProbe.responsesMaxOutputTokens == responsesCap)
        #expect(RelayModelProbe.otherProtocolsMaxTokens == otherCap)

        let responses = try await Self.probeAndChatRequests(.openaiResponses).probe.1
        #expect(responses["max_output_tokens"] as? Int == responsesCap)
        let chat = try await Self.probeAndChatRequests(.openaiChatCompletions).probe.1
        #expect([chat["max_tokens"] as? Int, chat["max_completion_tokens"] as? Int].compactMap { $0 } == [otherCap])
        let messages = try await Self.probeAndChatRequests(.anthropicMessages).probe.1
        #expect(messages["max_tokens"] as? Int == otherCap)
        let gemini = try await Self.probeAndChatRequests(.geminiGenerateContent).probe.1
        #expect((gemini["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == otherCap)
    }

    @Test("User-selected connection protocol: a model with no protocol of its own follows the connection, and send-time protocol fallback has no other candidate")
    func d75UserChosenConnectionHasNoFallbackCandidate() throws {
        let plain = TestFactories.makeModel(id: "plain", capabilities: [.text])
        var pinned = plain
        pinned.relayTransport = .openaiResponses
        pinned.relayTransportSource = .reachable
        var userSet = plain
        userSet.relayTransport = .anthropicMessages
        userSet.relayTransportSource = .user
        func provider(_ transport: RelayTransport) -> Provider {
            Self.relayProvider(endpoint: "https://relay.example.com", transport: transport, models: [], catalogModels: [])
        }
        for transport in Self.probedTransports {
            #expect(RelayProbeCandidates.followsUserChosenConnection(provider: provider(transport), model: plain))
            #expect(!RelayProbeCandidates.followsUserChosenConnection(provider: provider(transport), model: pinned))
            #expect(!RelayProbeCandidates.followsUserChosenConnection(provider: provider(transport), model: userSet))
        }
        #expect(!RelayProbeCandidates.followsUserChosenConnection(provider: provider(.auto), model: plain))
        var noConfig = provider(.auto)
        noConfig.relayRequested = nil
        #expect(!RelayProbeCandidates.followsUserChosenConnection(provider: noConfig, model: plain))

        // The send path blocks with it before looking up candidates; fallback and probing both call only this one route-level rejection criterion.
        let chat = try ProductionSource.read("Core/State/ChatManager.swift")
        #expect(chat.contains("guard !RelayProbeCandidates.followsUserChosenConnection(provider: provider, model: model) else { return nil }"))
        let manager = try ProductionSource.read("Core/State/ProviderManager.swift")
        #expect(manager.contains("!RelayProbeCandidates.followsUserChosenConnection(provider: provider, model: model) else { return }"))
    }

    // MARK: - R5a

    @Test("RL2-PROBE-03 Codex dedicated line without a catalog: generation route discovery uses the default model -> recorded as one pass, with no extra ping; a sentinel-discovered one does not count")
    func rl2Probe03GenerationRouteWithDefaultModelCountsAsPass() async throws {
        let endpoint = "https://codex-only.example.com"
        let defaultModel = "codex-renamed-by-gateway"
        RelayProbeFakeServer.install { request, body in
            guard let key = Self.probeKey(request, body: body),
                  key.short == "responses", key.model == defaultModel else { return .status(404, Data()) }
            return .status(200, Self.json(["id": "resp", "output": []]))
        }
        let session = RelayProbeFakeServer.session()
        let discovery = try await RelayDiscoveryService(session: session, retryBackoff: [])
            .discover(endpoint: endpoint, apiKey: "sk-test", modelHint: defaultModel)
        let detection = try #require(discovery.detections.first)
        #expect(detection.detectionEvidence == .generationProbe)
        #expect(detection.transport == .openaiResponses)
        #expect(detection.modelIDs.isEmpty)

        let pass = try #require(RelayAddVerification.generationRoutePass(detection: detection, modelID: defaultModel))
        #expect(RelayAddVerification.generationRoutePass(detection: detection, modelID: "other-model") == nil)
        let requested = RelayAddVerification.connectionRequested(
            detection: detection,
            explicitTransport: nil,
            formAuthMode: .auto,
            securityMode: .remoteHTTPS,
            modelID: defaultModel
        )
        let requestsBefore = RelayProbeFakeServer.captured().count
        var pinged = 0
        let result = try await RelayAddVerification.run(
            endpoint: endpoint,
            requested: requested,
            userChosenTransport: nil,
            modelID: defaultModel,
            supportedEndpointTypes: nil,
            generationRoutePass: pass,
            family: { nil },
            ping: { _, _ in pinged += 1 }
        )
        #expect(result.verified)
        #expect(pinged == 0)
        #expect(RelayProbeFakeServer.captured().count == requestsBefore)

        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: defaultModel, isDefault: true)],
            baseURLText: endpoint
        )
        provider.relayRequested = requested
        RelayModelProbe.apply(try #require(result.modelOutcome), modelID: defaultModel, to: &provider)
        let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(provider))
        let model = try #require(stored.models.first)
        #expect(model.relayTransport == .openaiResponses)
        #expect(model.relayTransportSource == .reachable)
        #expect(stored.relayRequested?.transport == .auto)
        #expect(stored.relayRequested?.resolvedAPIBaseURL == nil)
        #expect(stored.relayRequested?.resolvedAPIBaseURLs == ["openai_responses": detection.apiBaseURL])

        // Real send route (production routedRequested + pingRelay): the Responses request carries the Codex identity headers and store=false.
        let service = OpenAIService(session: session)
        _ = try await service.pingRelay(
            apiKey: "sk-test",
            baseURL: endpoint,
            modelID: defaultModel,
            relayRequested: RelayEndpointResolver.routedRequested(provider: stored, model: model)
        )
        let sent = try #require(RelayProbeFakeServer.captured().last)
        #expect(sent.0.url?.absoluteString == detection.apiBaseURL + "/responses")
        #expect(sent.0.value(forHTTPHeaderField: "Originator") != nil)
        #expect(sent.0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(sent.1.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        #expect(body["store"] as? Bool == false)

        // A route discovered through the sentinel model does not count as a pass: there is no pass, so the default model is probed per the candidate rules.
        let sentinel = try await RelayDiscoveryService(session: session, retryBackoff: [])
            .discover(endpoint: endpoint, apiKey: "sk-test", modelHint: nil)
        if let sentinelDetection = sentinel.detections.first {
            #expect(RelayAddVerification.generationRoutePass(detection: sentinelDetection, modelID: defaultModel) == nil)
        }
    }

    @Test("RL2-PROBE-03 auto connection: auth stores the form value, only disableResponseStorage is written, and the discovery root lands in the field matching the connection's actual default")
    func rl2Probe03AutoConnectionRequestedShape() {
        let messagesCatalog = RelayDetectedConfiguration(
            transport: .anthropicMessages,
            authMode: .xApiKey,
            apiBaseURL: "https://relay.example.com/v1",
            modelIDs: ["claude"],
            endpointEvidence: .defaultVersion,
            generationVerified: false
        )
        let auto = RelayAddVerification.connectionRequested(
            detection: messagesCatalog, explicitTransport: nil, formAuthMode: .auto,
            securityMode: .remoteHTTPS, modelID: "claude"
        )
        #expect(auto.transport == .auto)
        #expect(auto.authMode == .auto)
        #expect(auto.disableResponseStorage == true)
        #expect(auto.codexCompatIdentity == nil)
        #expect(auto.resolvedAPIBaseURL == nil)
        #expect(auto.resolvedAPIBaseURLs == ["anthropic_messages": "https://relay.example.com/v1"])

        let chosen = RelayAddVerification.connectionRequested(
            detection: messagesCatalog, explicitTransport: .anthropicMessages, formAuthMode: .auto,
            securityMode: .remoteHTTPS, modelID: "claude"
        )
        #expect(chosen.transport == .anthropicMessages)
        #expect(chosen.authMode == .xApiKey)
        #expect(chosen.resolvedAPIBaseURL == "https://relay.example.com/v1")
        #expect(chosen.resolvedAPIBaseURLs == nil)
        #expect(chosen.disableResponseStorage == nil)
    }

    // MARK: - RL2-PROBE-04 / RL2-PROBE-05

    private static func catalogBody(_ models: [[String: Any]]) -> Data {
        json([
            "object": "list",
            "data": models.map { model -> [String: Any] in
                var entry: [String: Any] = ["id": model["id"] as Any, "object": "model"]
                if let types = model["supportedEndpointTypes"] { entry["supported_endpoint_types"] = types }
                return entry
            },
        ])
    }

    /// The catalog GET answers with the fixture catalog, the probe POST looks up the ping table by "model@short-protocol", and everything else gets 404.
    private static func installCatalogAndPings(models: [[String: Any]], pings: [String: String]) {
        let catalog = catalogBody(models)
        RelayProbeFakeServer.install { request, body in
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/models") == true {
                return .status(200, catalog)
            }
            guard let key = probeKey(request, body: body) else { return .status(404, Data()) }
            return reply(for: pings["\(key.model)@\(key.short)"] ?? "http_404")
        }
    }

    private static func sentProbes() -> [[String]] {
        RelayProbeFakeServer.captured()
            .compactMap { probeKey($0.0, body: $0.1) }
            .map { [$0.model, $0.short] }
    }

    private static func relayModel(_ fields: [String: Any], isDefault: Bool) throws -> AIModel {
        let id = try #require(fields["id"] as? String)
        var model = TestFactories.makeModel(id: id, capabilities: [.text], isDefault: isDefault)
        if let raw = fields["relayTransport"] as? String {
            model.relayTransport = try #require(RelayTransport(rawValue: raw))
            model.relayTransportSource = try #require(
                RelayTransportSource(rawValue: fields["relayTransportSource"] as? String ?? "")
            )
        }
        if let overrides = fields["relayCapabilityOverrides"] {
            model.relayCapabilityOverrides = try JSONDecoder().decode(
                RelayCapabilityOverrides.self,
                from: JSONSerialization.data(withJSONObject: overrides)
            )
        }
        return model
    }

    private static func relayProvider(
        id: UUID = UUID(),
        endpoint: String,
        transport: RelayTransport,
        models: [AIModel],
        catalogModels: [AIModel]
    ) -> Provider {
        Provider(
            id: id,
            kind: .relay,
            status: .connected,
            models: models,
            catalogModels: catalogModels,
            apiKey: "sk-test",
            apiKeyPreview: "...test",
            baseURLText: endpoint,
            relayRequested: RelayRequestedConfig(transport: transport, authMode: .bearer, securityMode: .remoteHTTPS)
        )
    }

    private static func makeState() -> AppState {
        AppState(
            seedDemoData: false,
            sessionUID: "relay-probe-\(UUID().uuidString)",
            providerSession: RelayProbeFakeServer.session()
        )
    }

    /// Model fields equal the fixture expectations item by item (a field the expectation does not list must be empty).
    private static func expectModelFields(
        _ model: AIModel,
        _ expected: [String: Any],
        _ label: String
    ) throws {
        #expect(model.relayTransport?.rawValue == expected["relayTransport"] as? String, "\(label)")
        #expect(model.relayTransportSource?.rawValue == expected["relayTransportSource"] as? String, "\(label)")
        if let overrides = expected["relayCapabilityOverrides"] {
            let decoded = try JSONDecoder().decode(
                RelayCapabilityOverrides.self,
                from: JSONSerialization.data(withJSONObject: overrides)
            )
            #expect(model.relayCapabilityOverrides == decoded, "\(label)")
        }
    }

    @Test("RL2-PROBE-04 catalog refresh is parsed from the production raw text and records supported_endpoint_types into the probe candidate cache")
    func rl2Probe04CatalogRefreshRecordsEndpointTypes() async throws {
        let endpoint = "https://refresh-\(UUID().uuidString.prefix(8)).example.com/v1"
        let models: [[String: Any]] = [
            ["id": "o3-pro", "supportedEndpointTypes": ["openai-response"]],
            ["id": "gpt-4o-mini"],
        ]
        Self.installCatalogAndPings(models: models, pings: [:])
        let state = Self.makeState()
        let provider = Self.relayProvider(
            endpoint: endpoint,
            transport: .openaiChatCompletions,
            models: [TestFactories.makeModel(id: "gpt-4o-mini", capabilities: [.text], isDefault: true)],
            catalogModels: []
        )
        state.providers = [provider]

        #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id))
        #expect(RelayCatalogEndpointTypesCache.shared.endpointTypes(endpoint: endpoint, modelID: "o3-pro") == ["openai-response"])
        #expect(RelayCatalogEndpointTypesCache.shared.endpointTypes(endpoint: endpoint, modelID: "gpt-4o-mini") == nil)
        #expect(Self.sentProbes().isEmpty, "refreshing the catalog sends no probe")
    }

    @Test("RL2-PROBE-04 enable_* scenarios: production enable -> production ping against the fake server -> write-back through a production Codable round trip")
    func rl2Probe04EnableScenarios() async throws {
        let contract = try Self.orchestration()
        let scenarios = try #require(contract["scenarios"] as? [[String: Any]])
            .filter { ($0["caseId"] as? String)?.hasPrefix("enable_") == true }
        #expect(scenarios.compactMap { $0["caseId"] as? String } == [
            "enable_probes_the_enabled_model_and_stores_reachable",
            "enable_with_every_candidate_failing_still_enables_and_follows_the_connection",
            "enable_on_a_user_chosen_connection_protocol_sends_no_probe_and_pins_nothing",
            "enable_stops_at_an_inconclusive_first_candidate_and_pins_nothing",
            "enable_moves_on_after_a_route_level_403",
        ])
        let inconclusive = try Self.outcomeRules().inconclusive
        #expect(inconclusive.count == 7)

        // For the "inconclusive" scenarios, run once for each outcome in inconclusive per the fixture $comment; for the route-level 403 scenarios, additionally run once for
        // each outcome in routeRejected (including html_200), all of which continue to the next candidate; other scenarios run once.
        let routeRejected = try Self.outcomeRules().routeRejected
        #expect(routeRejected == ["http_404", "http_405", "http_415", "http_403_route", "html_200"])
        #expect(!inconclusive.contains("html_200"))
        var runs: [(label: String, scenario: [String: Any], pings: [String: String])] = []
        for scenario in scenarios {
            let caseId = scenario["caseId"] as? String ?? "<no id>"
            let pings = scenario["ping"] as? [String: String] ?? [:]
            let variants: (placeholder: String, outcomes: [String])? = switch caseId {
            case "enable_stops_at_an_inconclusive_first_candidate_and_pins_nothing": ("http_429", inconclusive)
            case "enable_moves_on_after_a_route_level_403": ("http_403_route", routeRejected)
            default: nil
            }
            guard let variants else {
                runs.append((caseId, scenario, pings))
                continue
            }
            let replaced = try #require(pings.first { $0.value == variants.placeholder }?.key, "\(caseId)")
            for outcome in variants.outcomes {
                var table = pings
                table[replaced] = outcome
                runs.append(("\(caseId)[\(outcome)]", scenario, table))
            }
        }
        #expect(runs.count == scenarios.count - 2 + inconclusive.count + routeRejected.count)
        #expect(runs.contains { $0.label == "enable_moves_on_after_a_route_level_403[html_200]" })

        for (caseId, scenario, pings) in runs {
            let connection = try #require(scenario["connection"] as? [String: Any])
            let endpoint = try #require(connection["baseURL"] as? String)
            let transport = try #require(RelayTransport(rawValue: connection["transport"] as? String ?? ""))
            let models = try #require(scenario["models"] as? [[String: Any]])
            let enable = try #require(scenario["enable"] as? String)
            let expect = try #require(scenario["expect"] as? [String: Any])
            // The catalog also has an already-enabled anchor model: a refresh keeps the existing selection and does not auto-enable the fixture model.
            let served = models + [["id": "anchor-model"]]
            Self.installCatalogAndPings(models: served, pings: pings)

            let anchor = TestFactories.makeModel(id: "anchor-model", capabilities: [.text], isDefault: true)
            let state = Self.makeState()
            let provider = Self.relayProvider(
                endpoint: endpoint, transport: transport, models: [anchor], catalogModels: [anchor]
            )
            state.providers = [provider]
            RelayCatalogEndpointTypesCache.shared.removeAll()
            #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id), "\(caseId)")
            #expect(state.provider(for: provider.id)?.models.map(\.id) == ["anchor-model"], "\(caseId)")
            Self.installCatalogAndPings(models: served, pings: pings)

            let result = state.enableModel(modelID: enable, for: provider.id, lazilyVerifiesRelayTransport: true)
            #expect(result != .notFound && result != .alreadyEnabled, "\(caseId)")
            // Enable first, probe afterwards: the model is already in the enabled list before the probe returns.
            #expect(state.provider(for: provider.id)?.models.contains { $0.id == enable } == true, "\(caseId)")
            await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

            #expect(Self.sentProbes() == expect["pings"] as? [[String]], "\(caseId)")
            try Self.expectNoCapabilityTestRequests("\(caseId) enable")
            let current = try #require(state.provider(for: provider.id))
            let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(current))
            #expect(
                Set(stored.models.map(\.id)).subtracting(["anchor-model"])
                    == Set(expect["enabled"] as? [String] ?? []),
                "\(caseId)"
            )
            #expect(stored.relayRequested?.transport.rawValue == expect["connectionTransport"] as? String, "\(caseId)")
            #expect(
                stored.relayRequested?.resolvedAPIBaseURLs ?? [:]
                    == expect["resolvedAPIBaseURLs"] as? [String: String] ?? [:],
                "\(caseId)"
            )
            let expectedModels = try #require(expect["models"] as? [String: [String: Any]])
            for (modelID, fields) in expectedModels {
                let model = try #require(stored.models.first { $0.id == modelID }, "\(caseId) \(modelID)")
                try Self.expectModelFields(model, fields, "\(caseId) \(modelID)")
            }
            // If it did not pass and a request was sent, the in-session "unreachable - view reason" is still there; with no request sent there is no session state.
            let probeState = state.relayModelProbeStates[provider.id]?[enable]
            let pinned = (expectedModels[enable]?["relayTransport"] as? String) != nil
            if pinned || Self.sentProbes().isEmpty {
                #expect(probeState == nil, "\(caseId)")
            } else if case .failed = probeState {
            } else {
                Issue.record("\(caseId): a failed probe should leave an unreachable reason, got \(String(describing: probeState))")
            }
        }
    }

    @Test("RL2-PROBE-04 probe only when a single model is enabled, the Relay is not a local engine and the model has no protocol; restore actions do not probe (connections are all auto, each gate applies on its own)")
    func rl2Probe04EnableProbeGates() async throws {
        let endpoint = "https://relay.example.com/v1"
        let models: [[String: Any]] = [["id": "o3-pro", "supportedEndpointTypes": ["openai-response"]]]
        Self.installCatalogAndPings(models: models, pings: ["o3-pro@responses": "ok"])
        let anchor = TestFactories.makeModel(id: "anchor-model", capabilities: [.text], isDefault: true)
        let target = TestFactories.makeModel(id: "o3-pro", capabilities: [.text], isDefault: false)

        // Restore actions such as undoing a deletion (default arguments) do not probe.
        do {
            let state = Self.makeState()
            let provider = Self.relayProvider(
                endpoint: endpoint, transport: .auto, models: [anchor], catalogModels: [anchor, target]
            )
            state.providers = [provider]
            #expect(state.enableModel(modelID: "o3-pro", for: provider.id) == .added(modelName: target.name))
            await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)
            #expect(Self.sentProbes().isEmpty)
        }
        // A model that already has a protocol (from any source) is not probed again.
        do {
            Self.installCatalogAndPings(models: models, pings: ["o3-pro@responses": "ok"])
            var pinned = target
            pinned.relayTransport = .openaiChatCompletions
            pinned.relayTransportSource = .user
            let state = Self.makeState()
            let provider = Self.relayProvider(
                endpoint: endpoint, transport: .auto, models: [anchor], catalogModels: [anchor, pinned]
            )
            state.providers = [provider]
            _ = state.enableModel(modelID: "o3-pro", for: provider.id, lazilyVerifiesRelayTransport: true)
            await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)
            #expect(Self.sentProbes().isEmpty)
            #expect(state.provider(for: provider.id)?.models.first { $0.id == "o3-pro" }?.relayTransportSource == .user)
        }
        // A local engine (non-empty engineProfile) is not probed.
        do {
            Self.installCatalogAndPings(models: models, pings: ["o3-pro@responses": "ok"])
            let state = Self.makeState()
            var provider = Self.relayProvider(
                endpoint: endpoint, transport: .auto, models: [anchor], catalogModels: [anchor, target]
            )
            provider.relayRequested?.engineProfile = "ollama"
            state.providers = [provider]
            _ = state.enableModel(modelID: "o3-pro", for: provider.id, lazilyVerifiesRelayTransport: true)
            await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)
            #expect(Self.sentProbes().isEmpty)
        }
    }

    @Test("RL2-PROBE-04 two models enabled one after another on the same connection, both probes passing: both land as reachable, and both appear in the per-protocol root address table")
    func rl2Probe04TwoSequentialEnablesBothLand() async throws {
        let endpoint = "https://relay.example.com/v1"
        let models: [[String: Any]] = [
            ["id": "o3-pro", "supportedEndpointTypes": ["openai-response"]],
            ["id": "claude-sonnet-4-5", "supportedEndpointTypes": ["anthropic"]],
        ]
        Self.installCatalogAndPings(
            models: models,
            pings: ["o3-pro@responses": "ok", "claude-sonnet-4-5@messages": "ok"]
        )
        RelayCatalogEndpointTypesCache.shared.record(
            endpoint: endpoint,
            endpointTypesByModel: ["o3-pro": ["openai-response"], "claude-sonnet-4-5": ["anthropic"]]
        )
        let anchor = TestFactories.makeModel(id: "anchor-model", capabilities: [.text], isDefault: true)
        let catalog = [anchor] + models.map {
            TestFactories.makeModel(id: $0["id"] as? String ?? "", capabilities: [.text], isDefault: false)
        }
        let state = Self.makeState()
        let provider = Self.relayProvider(
            endpoint: endpoint, transport: .auto, models: [anchor], catalogModels: catalog
        )
        state.providers = [provider]

        // The second enable happens before the first probe writes back: the one that wrote back first changed the per-protocol root address table, and the later one must not be lost.
        _ = state.enableModel(modelID: "o3-pro", for: provider.id, lazilyVerifiesRelayTransport: true)
        _ = state.enableModel(modelID: "claude-sonnet-4-5", for: provider.id, lazilyVerifiesRelayTransport: true)
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(Set(Self.sentProbes()) == [["o3-pro", "responses"], ["claude-sonnet-4-5", "messages"]])
        let current = try #require(state.provider(for: provider.id))
        let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(current))
        let o3 = try #require(stored.models.first { $0.id == "o3-pro" })
        let claude = try #require(stored.models.first { $0.id == "claude-sonnet-4-5" })
        #expect(o3.relayTransport == .openaiResponses)
        #expect(o3.relayTransportSource == .reachable)
        #expect(claude.relayTransport == .anthropicMessages)
        #expect(claude.relayTransportSource == .reachable)
        #expect(stored.relayRequested?.resolvedAPIBaseURLs == [
            "openai_responses": endpoint,
            "anthropic_messages": endpoint,
        ])
        #expect(stored.relayRequested?.transport == .auto)
    }

    private static func sseBody(for request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/responses") {
            return """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"ok"}

            event: response.completed
            data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":1}}}

            data: [DONE]


            """
        }
        if path.hasSuffix("/messages") {
            return """
            event: content_block_start
            data: {"index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"index":0,"delta":{"type":"text_delta","text":"ok"}}

            event: message_stop
            data: {}


            """
        }
        return """
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]


        """
    }

    @Test("RL2-PROBE-04 a_delivered_send_upgrades_reachable_to_observed: only a delivered send on the production send chain upgrades to observed")
    func rl2Probe04DeliveredSendUpgradesReachable() async throws {
        let contract = try Self.orchestration()
        let scenario = try #require(
            (contract["scenarios"] as? [[String: Any]])?
                .first { $0["caseId"] as? String == "a_delivered_send_upgrades_reachable_to_observed" }
        )
        let entries = try #require(scenario["before"] as? [[String: Any]])
        #expect(entries.count == 4)

        for entry in entries {
            let id = try #require(entry["id"] as? String)
            let delivered = entry["outcome"] as? String == "delivered"
            RelayProbeFakeServer.install { request, _ in
                guard request.httpMethod == "POST" else { return .status(404, Data()) }
                return delivered
                    ? .sse(Self.sseBody(for: request))
                    : .status(400, Self.json(["error": ["message": "bad request"]]))
            }
            let model = try Self.relayModel(entry, isDefault: true)
            let state = Self.makeState()
            let provider = Self.relayProvider(
                endpoint: "https://relay.example.com/v1",
                transport: .openaiChatCompletions,
                models: [model],
                catalogModels: [model]
            )
            state.providers = [provider]
            let conversation = TestFactories.makeConversation(
                providerID: provider.id, providerKind: .relay, modelID: id
            )
            state.upsertConversationProjection(conversation)

            _ = await state.sendMessage("Hello", in: conversation.id)
            let deadline = ContinuousClock.now + .seconds(10)
            func finalState() -> ChatMessageState? {
                guard let last = state.conversations.first(where: { $0.id == conversation.id })?.messages.last,
                      last.role == .assistant else { return nil }
                return [.delivered, .failed].contains(last.state) ? last.state : nil
            }
            while finalState() == nil, ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(finalState() == (delivered ? .delivered : .failed), "\(id)")
            #expect(!RelayProbeFakeServer.captured().isEmpty, "\(id): the send chain sent no request")

            let current = try #require(state.provider(for: provider.id))
            let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(current))
            let after = try #require(entry["after"] as? [String: Any])
            try Self.expectModelFields(try #require(stored.models.first { $0.id == id }), after, id)
            try Self.expectModelFields(try #require(stored.catalogModels.first { $0.id == id }), after, "\(id) catalog")
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test("RL2-PROBE-05 redetect_*: clear reachable and this connection's negative cache, refresh the catalog, re-probe enabled models that have no protocol after clearing in enable order; strong sources are untouched")
    func rl2Probe05Redetect() async throws {
        let contract = try Self.orchestration()
        let scenarios = try #require(contract["scenarios"] as? [[String: Any]])
            .filter { ($0["caseId"] as? String)?.hasPrefix("redetect_") == true }
        #expect(scenarios.compactMap { $0["caseId"] as? String } == [
            "redetect_clears_reachable_and_negative_cache_and_keeps_stronger_sources",
            "redetect_on_a_user_chosen_connection_protocol_clears_reachable_and_sends_no_probe",
        ])
        for scenario in scenarios {
            try await Self.runRedetect(scenario)
        }
    }

    private static func runRedetect(_ scenario: [String: Any]) async throws {
        let caseId = scenario["caseId"] as? String ?? "<no id>"
        let connection = try #require(scenario["connection"] as? [String: Any])
        let endpoint = try #require(connection["baseURL"] as? String)
        let transport = try #require(RelayTransport(rawValue: connection["transport"] as? String ?? ""))
        let entries = try #require(scenario["models"] as? [[String: Any]])
        let defaultModel = scenario["defaultModel"] as? String
        let expect = try #require(scenario["expect"] as? [String: Any])
        Self.installCatalogAndPings(models: entries, pings: scenario["ping"] as? [String: String] ?? [:])

        // defaultModel is legacy isDefault data; it is written into the model as-is to prove redetect does not look at it.
        let models = try entries.map { try Self.relayModel($0, isDefault: $0["id"] as? String == defaultModel) }
        let state = Self.makeState()
        let provider = Self.relayProvider(endpoint: endpoint, transport: transport, models: models, catalogModels: models)
        state.providers = [provider]

        // This connection has one entry in each of the two negative caches (the other connection's entries must not be cleared).
        let otherConnection = UUID()
        #expect(ToolCallMemoryStore.shared.record(
            connectionID: provider.id, modelID: "gpt-4o-mini", toolCall: false, reason: .toolsRejected4xx
        ))
        #expect(ToolCallMemoryStore.shared.record(
            connectionID: otherConnection, modelID: "gpt-4o-mini", toolCall: false, reason: .toolsRejected4xx
        ))
        func rejectionIdentity(_ connectionID: UUID) -> CapabilityEvidenceRequestIdentity {
            CapabilityEvidenceRequestIdentity(query: .init(
                partitionID: "u1", connectionInstanceID: connectionID.uuidString, connectionGeneration: "cg1",
                credentialEpoch: "ce1", providerKind: ProviderKind.relay.rawValue,
                authMode: ProviderAuthMode.apiKey.rawValue, modelID: "gpt-4o-mini",
                canonicalModelID: "gpt-4o-mini", effectiveTransport: "openai_chat_completions",
                endpointFingerprint: "ep", metadataRevision: "m1", generationRevision: "g1",
                now: Int64(Date().timeIntervalSince1970 * 1_000), hasExplicitValue: true
            ), runtimeRevision: "r1")
        }
        func rejections(_ connectionID: UUID) -> Int {
            UnsupportedParamCache.shared.capabilityRejectedCandidates(
                providerKind: .relay, modelID: "gpt-4o-mini", endpointFingerprint: "ep",
                identity: rejectionIdentity(connectionID)
            ).count
        }
        for connectionID in [provider.id, otherConnection] {
            UnsupportedParamCache.shared.markCapabilityRejected(
                providerKind: .relay, modelID: "gpt-4o-mini", source: .providerRecipe, owner: "tools",
                recipeRef: "fixture.redetect.v1", setting: "/tools", capabilityKey: "tool_call", endpointFingerprint: "ep",
                identity: rejectionIdentity(connectionID)
            )
        }
        #expect(rejections(provider.id) == 1)
        defer {
            ToolCallMemoryStore.shared.clear(connectionID: otherConnection)
            UnsupportedParamCache.shared.clearCapabilityRejections(connectionID: otherConnection.uuidString)
        }

        await state.providerManager.redetectRelayModels(providerID: provider.id)

        #expect(Self.sentProbes() == expect["pings"] as? [[String]], "\(caseId)")
        try Self.expectNoCapabilityTestRequests("\(caseId) redetect")
        let negative = (ToolCallMemoryStore.shared.lookup(connectionID: provider.id, modelID: "gpt-4o-mini") == nil ? 0 : 1)
            + rejections(provider.id)
        // Scenarios where the fixture omits this item also clear this connection's negative cache (redetect cleanup ignores the connection protocol).
        #expect(negative == expect["negativeCacheEntriesForConnection"] as? Int ?? 0, "\(caseId)")
        #expect(ToolCallMemoryStore.shared.lookup(connectionID: otherConnection, modelID: "gpt-4o-mini") != nil)
        #expect(rejections(otherConnection) == 1)

        let current = try #require(state.provider(for: provider.id))
        let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(current))
        #expect(stored.models.map(\.id) == expect["enabled"] as? [String], "\(caseId)")
        #expect(stored.relayRequested?.transport.rawValue == expect["connectionTransport"] as? String, "\(caseId)")
        let expectedModels = try #require(expect["models"] as? [String: [String: Any]])
        for (modelID, fields) in expectedModels {
            let model = try #require(stored.models.first { $0.id == modelID }, "\(caseId) \(modelID)")
            try Self.expectModelFields(model, fields, "\(caseId) \(modelID)")
        }
    }

    @Test("RD1-REDETECT-01 three enabled models (A source user, B source reachable, C no protocol) -> redetect probes B and C but not A; probed even if none is the default")
    func RD1_REDETECT_01_probesEveryEnabledModelWithoutTransport() async throws {
        let endpoint = "https://relay.example.com/v1"
        let entries: [[String: Any]] = [
            ["id": "model-a", "supportedEndpointTypes": ["openai"],
             "relayTransport": "gemini_generate_content", "relayTransportSource": "user"],
            ["id": "model-b", "supportedEndpointTypes": ["openai"],
             "relayTransport": "openai_chat_completions", "relayTransportSource": "reachable"],
            ["id": "model-c", "supportedEndpointTypes": ["openai"]],
        ]
        Self.installCatalogAndPings(models: entries, pings: ["model-b@chat": "ok", "model-c@chat": "ok"])
        let models = try entries.map { try Self.relayModel($0, isDefault: false) }
        let state = Self.makeState()
        let provider = Self.relayProvider(
            endpoint: endpoint, transport: .auto, models: models, catalogModels: models
        )
        state.providers = [provider]

        await state.providerManager.redetectRelayModels(providerID: provider.id)

        #expect(Self.sentProbes() == [["model-b", "chat"], ["model-c", "chat"]])
        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.models.map(\.id) == ["model-a", "model-b", "model-c"])
        let modelA = try #require(stored.models.first { $0.id == "model-a" })
        #expect(modelA.relayTransport == .geminiGenerateContent)
        #expect(modelA.relayTransportSource == .user)
        for id in ["model-b", "model-c"] {
            let model = try #require(stored.models.first { $0.id == id })
            #expect(model.relayTransport == .openaiChatCompletions, "\(id)")
            #expect(model.relayTransportSource == .reachable, "\(id)")
        }
        #expect(stored.models.allSatisfy { !$0.isDefault })
    }
}
