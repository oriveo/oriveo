import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// URLProtocol stub for DeepSeek search: replies with the transport-golden deepseek.normal golden sample and counts requests. No network.
private final class DeepSeekGoldenProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var count = 0

    static func reset(body: Data) {
        lock.withLock {
            self.body = body
            count = 0
        }
    }

    static var requestCount: Int { lock.withLock { count } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekGoldenProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data = Self.lock.withLock {
            Self.count += 1
            return Self.body
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Production-path evidence for external search execution wiring: a DeepSeek response golden sample replaces HTTP, then the real executor →
/// SearchTurn composition entry → web_search entry / pre-search [D] → sources and facts landing on the message.
@Suite("External search execution wiring (DeepSeek golden sample)", .serialized)
@MainActor
struct ExternalSearchTurnIntegrationTests {
    private static let goldenPath = "shared/search-contracts/transport-golden.v1.json"
    private static let contractPath = "shared/search-contracts/search_catalog_contract.v1.json"

    private static func goldenCase(_ id: String) throws -> SearchJSON {
        let cases = try #require(try SearchContractSupport.load(goldenPath)["cases"]?.arrayValue)
        return try #require(cases.first { $0["caseId"]?.stringValue == id })
    }

    private static func context(path: WebSearchRoute.Path) throws -> ExternalSearchServiceContext {
        let catalog = try #require(try SearchContractSupport.load(contractPath)["catalog"])
        let entry = try #require(SearchContractSupport.service("deepseek", in: catalog))
        return ExternalSearchServiceContext(
            path: path,
            service: SearchTurnService(id: "stored-deepseek", name: "DeepSeek", protocolID: "catalog", custom: false),
            telemetryServiceID: "deepseek",
            otherServices: [],
            target: .preset(entry: entry, regionId: "cn", boundHost: "api.deepseek.com", withdrawn: false, key: "sk-test-0000"),
            resultCount: 5,
            toolCall: .supported
        )
    }

    private static func plan(path: WebSearchRoute.Path, userText: String) throws -> SearchTurnPlan {
        try SearchTurn.planSearchTurn(SearchTurnPlanInput(
            path: path,
            service: SearchTurnService(id: "stored-deepseek", name: "DeepSeek", protocolID: "catalog", custom: false),
            toolCall: .supported,
            userText: userText,
            windowTokens: 128_000,
            today: "2026-10-27"
        ))
    }

    private static func libraryBatch() -> [SearchCitationBatch] {
        [SearchCitationBatch(source: "library", items: [SearchCitationItem(libraryKey: "doc-a", url: nil)])]
    }

    private static func goldenResultCount() throws -> Int {
        try #require(try goldenCase("deepseek.normal")["expect"]?["results"]?.arrayValue?.count)
    }

    @Test("Tool path: the web_search executor returns an <oriveo-web envelope, ids follow the library numbering; persisted source numbers match, facts are observed")
    func toolPathDeliversEnvelopeAndPersistsSources() async throws {
        DeepSeekGoldenProtocol.reset(body: try #require(try Self.goldenCase("deepseek.normal")["body"]).encodedData())
        let plan = try Self.plan(path: .externalTool, userText: "Oriveo web search")
        #expect(plan.requestHasWebSearchTool)
        let tool = try #require(plan.webSearchTool)
        var events: [SearchTelemetryEvent] = []
        let turn = ExternalSearchTurn(
            plan: plan, context: try Self.context(path: .externalTool), windowTokens: 128_000, rhoHi: 0.5,
            priorBatches: Self.libraryBatch(), retrievedAt: "2026-10-27T00:00:00Z",
            requester: SearchExecutor(session: DeepSeekGoldenProtocol.session())
        )
        turn.onTelemetry = { events.append($0) }
        var activities: [SearchActivity?] = []
        turn.onActivity = { activities.append($0) }
        let entry = ExternalWebSearchToolEntry(tool: tool) { query, count in
            await turn.search(query: query, count: count)
        }
        #expect(entry.definition?.function.name == "web_search")

        let outcome = try await entry.execute(
            ToolLoopToolCall(id: "call-1", function: .init(name: "web_search", arguments: #"{"query":"Oriveo web search"}"#)),
            context: ToolExecutionContext(callID: "call-1", stepNumber: 1, legIndex: 0)
        )

        #expect(DeepSeekGoldenProtocol.requestCount == 1)
        #expect(outcome.content.hasPrefix("<oriveo-web"))
        #expect(outcome.content.contains(#"id="2""#))
        #expect(!outcome.content.contains(#"id="1""#))
        #expect(activities.first??.serviceName == "DeepSeek")
        #expect(activities.last! == nil)
        guard case .searchExecuted(let props)? = events.first else {
            Issue.record("expected search_executed, got \(events)")
            return
        }
        #expect(props.service == "deepseek")
        #expect(props.path == "tool")

        let finish = turn.finish(stopped: false)
        var message = TestFactories.makeMessage(role: .assistant, text: "Answer [2]")
        message.citations = [Citation(url: "https://library.example/doc-a", index: 1, source: "library")]
        ChatManager.applyExternalSearchFinish(finish, serviceID: turn.context.service.id, to: &message)

        let web = (message.citations ?? []).filter { $0.source == "external_search" }
        let expected = try Self.goldenResultCount()
        #expect(web.count == expected)
        #expect(web.map(\.index) == Array(2..<(2 + expected)).map { Optional($0) })
        #expect(web.allSatisfy { $0.serviceId == "stored-deepseek" && $0.query == "Oriveo web search" })
        #expect((message.citations ?? []).contains { $0.source == "library" && $0.index == 1 })
        let record = try #require(message.capabilityExecution?.externalSearch)
        #expect(record.facts.state == "observed")
        #expect(record.facts.evidenceKind == "external_search_result")
        #expect(record.facts.sourceCount == expected)
        #expect(record.errorCard == nil)

        // Persist and read back: facts that exist only from external search (no recipe owner) are kept too; the compact history record is derived from the persisted sources.
        let encoded = RecordMappers.encodeCapabilityExecution(message.capabilityExecution)
        #expect(RecordMappers.decodeCapabilityExecution(encoded)?.externalSearch == record)
        let history = ChatRequestBuilder.contextMessage(message)
        #expect(history.text.hasPrefix("Answer [2]\n\nWeb searches used for this reply"))
    }

    @Test("Pre-search: the user's verbatim text is the query, and the <oriveo-web segment follows <oriveo-library> into [D]")
    func presearchLandsAfterLibraryInDynamicBlock() async throws {
        DeepSeekGoldenProtocol.reset(body: try #require(try Self.goldenCase("deepseek.normal")["body"]).encodedData())
        let plan = try Self.plan(path: .externalPresearch, userText: "Oriveo web search")
        #expect(plan.presearch?.query == "Oriveo web search")
        #expect(!plan.requestHasWebSearchTool)
        let turn = ExternalSearchTurn(
            plan: plan, context: try Self.context(path: .externalPresearch), windowTokens: 128_000, rhoHi: 0.5,
            priorBatches: Self.libraryBatch(), retrievedAt: "2026-10-27T00:00:00Z",
            requester: SearchExecutor(session: DeepSeekGoldenProtocol.session())
        )
        turn.onTelemetry = { _ in }
        let content = try #require(await turn.presearch())
        #expect(content.hasPrefix("<oriveo-web"))
        #expect(content.contains(#"id="2""#))

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [TestFactories.makeMessage(role: .user, text: "Oriveo web search")],
            preferences: ChatRequestPreferencesSnapshot(), skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        .withLibrary([ContextLibraryEntry(citation: 1, title: "Plan", text: "Alpha")])
        .withWeb(content)
        let dynamic = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly).planned.dynamicText
        let library = try #require(dynamic.range(of: "</oriveo-library>"))
        let web = try #require(dynamic.range(of: "<oriveo-web"))
        #expect(library.upperBound <= web.lowerBound)
        #expect(dynamic.contains(content))

        let record = ExternalSearchMessageRecord(finish: turn.finish(stopped: false), serviceID: "stored-deepseek")
        #expect(record.facts.state == "observed")
    }
}
