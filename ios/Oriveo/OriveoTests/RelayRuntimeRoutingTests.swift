import Foundation
import Testing
@testable import Oriveo

/// Fixture-driven tests for the pure routing functions a relay send goes through.
///
/// **Single source of truth**: `test-fixtures/relay/routing-fixtures.json` (shared across clients).
/// This file does not hard-code cases. It decodes the fixture JSON and asserts each case
/// against `RelayRuntimeSupport` pure functions.
///
/// Drift guard: Android / Web implement the same functions and read the same fixture.
/// Changing a rule without updating the fixture breaks every client's tests and forces a sync.
///
/// Adding a rule:
/// 1. Append a case (with a unique id) to `routing-fixtures.json`
/// 2. Update the pure-func implementations on all three clients together
/// 3. Land only after all three clients re-run green
@Suite("Relay runtime routing")
struct RelayRuntimeRoutingTests {

    // MARK: - Fixture loader

    // Not private — types referenced from `@Test func` parameters must be at least as visible as the method (internal here).
    nonisolated struct Fixture: Decodable, Sendable {
        let version: Int
        let imageRoute: ImageRouteSection
        let codexIdentityHeaders: CodexHeadersSection
        let shouldForceStream: ForceStreamSection
        let isDedicatedImageModel: DedicatedImageModelSection
        let pickChatDriverModelID: PickChatDriverSection

        nonisolated struct ImageRouteSection: Decodable, Sendable { let cases: [Case]
            nonisolated struct Case: Decodable, Sendable { let id: String; let transport: String; let expected: String }
        }
        nonisolated struct CodexHeadersSection: Decodable, Sendable { let cases: [Case]
            nonisolated struct Case: Decodable, Sendable {
                let id: String
                let transport: String
                let requiresCodexUA: Bool
                let requiresOriginator: Bool
                let requiresSessionID: Bool
                let requiresOpenAIBeta: Bool
            }
        }
        nonisolated struct ForceStreamSection: Decodable, Sendable { let cases: [Case]
            nonisolated struct Case: Decodable, Sendable { let id: String; let transport: String; let capabilities: [String]; let expected: Bool }
        }
        nonisolated struct DedicatedImageModelSection: Decodable, Sendable { let cases: [Case]
            nonisolated struct Case: Decodable, Sendable { let id: String; let modelID: String; let expected: Bool }
        }
        nonisolated struct PickChatDriverSection: Decodable, Sendable { let cases: [Case]
            nonisolated struct Case: Decodable, Sendable {
                let id: String
                let note: String?
                /// iOS runs a case only when platform is nil or "ios"
                /// (some cases use platform-specific ID namespaces and are not cross-client).
                let platform: String?
                let currentModelID: String
                let models: [ModelFixture]
                let expectedSuccess: String?
                let expectedError: String?
            }
            nonisolated struct ModelFixture: Decodable, Sendable {
                let id: String
                let capabilities: [String]
                let available: Bool
                let isDefault: Bool
            }
        }
    }

    nonisolated static let fixture: Fixture = {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var fixtureURL: URL?
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("relay")
                .appendingPathComponent("routing-fixtures.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                fixtureURL = candidate
                break
            }
            cursor.deleteLastPathComponent()
        }
        guard let fixtureURL else {
            fatalError("Failed to locate test-fixtures/relay/routing-fixtures.json by walking up from \(#filePath)")
        }
        do {
            let data = try Data(contentsOf: fixtureURL)
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            fatalError("Failed to load routing-fixtures.json from \(fixtureURL.path): \(error)")
        }
    }()

    // MARK: - Enum mapping helpers

    private static func transport(_ raw: String) -> RelayTransport? {
        RelayTransport(rawValue: raw)
    }

    private static func route(_ raw: String) -> RelayRuntimeSupport.ImageRoute? {
        RelayRuntimeSupport.ImageRoute(rawValue: raw)
    }

    private static func capability(_ raw: String) -> ModelCapability? {
        // Fixture uses "imageGen" / "text"; ModelCapability.rawValue for .imageGen is "imageGeneration".
        if raw == "imageGen" { return .imageGen }
        return ModelCapability(rawValue: raw)
    }

    private static func capabilities(_ raws: [String]) -> Set<ModelCapability> {
        Set(raws.compactMap { capability($0) })
    }

    // MARK: - Fixture version lock

    @Test("fixture version = 1 (bump requires a three-client sync)")
    func fixtureVersionLocked() {
        #expect(Self.fixture.version == 1)
    }

    // MARK: - imageRoute (IR-01..05)

    @Test("imageRoute fixture cases", arguments: Self.fixture.imageRoute.cases)
    func imageRouteMatchesFixture(_ c: Fixture.ImageRouteSection.Case) {
        guard let t = Self.transport(c.transport),
              let expected = Self.route(c.expected) else {
            Issue.record("fixture \(c.id): cannot parse transport=\(c.transport) or expected=\(c.expected)")
            return
        }
        #expect(
            RelayRuntimeSupport.imageRoute(for: t) == expected,
            "fixture \(c.id): transport=\(c.transport) → expected=\(c.expected)"
        )
    }

    // MARK: - codexIdentityHeaders (CI-01..05)

    @Test("codexIdentityHeaders fixture cases", arguments: Self.fixture.codexIdentityHeaders.cases)
    func codexHeadersMatchesFixture(_ c: Fixture.CodexHeadersSection.Case) {
        guard let t = Self.transport(c.transport) else {
            Issue.record("fixture \(c.id): cannot parse transport=\(c.transport)")
            return
        }
        let headers = RelayRuntimeSupport.codexIdentityHeaders(for: t)
        let hasCodexUA = headers["User-Agent"]?.hasPrefix("codex_cli_rs/") ?? false
        let hasOriginator = headers["Originator"] == "codex_cli_rs"
        let hasSessionID = (headers["session_id"]?.isEmpty == false)
        let hasOpenAIBeta = headers["OpenAI-Beta"] == "responses=experimental"
        #expect(hasCodexUA == c.requiresCodexUA, "fixture \(c.id): UA expected=\(c.requiresCodexUA)")
        #expect(hasOriginator == c.requiresOriginator, "fixture \(c.id): Originator expected=\(c.requiresOriginator)")
        #expect(hasSessionID == c.requiresSessionID, "fixture \(c.id): session_id expected=\(c.requiresSessionID)")
        #expect(hasOpenAIBeta == c.requiresOpenAIBeta, "fixture \(c.id): OpenAI-Beta expected=\(c.requiresOpenAIBeta)")
    }

    @Test("session_id is a fresh UUID on every call (defeats proxy cache coalescing)")
    func codexHeadersSessionIDIsPerCall() {
        let a = RelayRuntimeSupport.codexIdentityHeaders(for: .openaiResponses)["session_id"]
        let b = RelayRuntimeSupport.codexIdentityHeaders(for: .openaiResponses)["session_id"]
        #expect(a != nil && b != nil)
        #expect(a != b, "two calls must return different session_id UUIDs")
        // Basic UUID shape check
        #expect(a?.count == 36)
        #expect(a?.contains("-") == true)
    }

    // MARK: - shouldForceStream (FS-01..06)

    @Test("shouldForceStream fixture cases", arguments: Self.fixture.shouldForceStream.cases)
    func forceStreamMatchesFixture(_ c: Fixture.ForceStreamSection.Case) {
        guard let t = Self.transport(c.transport) else {
            Issue.record("fixture \(c.id): cannot parse transport=\(c.transport)")
            return
        }
        let caps = Self.capabilities(c.capabilities)
        #expect(
            RelayRuntimeSupport.shouldForceStream(transport: t, capabilities: caps) == c.expected,
            "fixture \(c.id): transport=\(c.transport) caps=\(c.capabilities) → expected=\(c.expected)"
        )
    }

    // MARK: - isDedicatedImageModel (DI-01..07)

    @Test("isDedicatedImageModel fixture cases", arguments: Self.fixture.isDedicatedImageModel.cases)
    func isDedicatedImageModelMatchesFixture(_ c: Fixture.DedicatedImageModelSection.Case) {
        #expect(
            RelayRuntimeSupport.isDedicatedImageModel(c.modelID) == c.expected,
            "fixture \(c.id): modelID=\(c.modelID) → expected=\(c.expected)"
        )
    }

    // MARK: - pickChatDriverModelID

    @Test("pickChatDriverModelID fixture cases", arguments: Self.fixture.pickChatDriverModelID.cases)
    func pickChatDriverMatchesFixture(_ c: Fixture.PickChatDriverSection.Case) {
        // Cross-client fixture cases tagged platform="ios" (iOS ID namespace prefix) run only on iOS.
        if let p = c.platform, p != "ios" { return }
        let models = c.models.map { m in
            AIModel(
                id: m.id,
                name: m.id,
                capabilities: m.capabilities.compactMap { Self.capability($0) },
                reasoningModeAvailable: false,
                isAvailable: m.available,
                isDefault: m.isDefault,
                priceTier: ""
            )
        }
        let provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: models,
            catalogModels: [],
            apiKey: "",
            apiKeyPreview: "",
            baseURLText: "https://example.com/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiResponses)
        )
        guard let current = models.first(where: { $0.id == c.currentModelID }) else {
            Issue.record("fixture \(c.id): currentModelID=\(c.currentModelID) is not in the models list")
            return
        }
        let result = RelayRuntimeSupport.pickChatDriverModelID(in: provider, currentModel: current)
        switch (result, c.expectedSuccess, c.expectedError) {
        case let (.success(id), expected?, nil):
            #expect(id == expected, "fixture \(c.id): success expected=\(expected) actual=\(id)")
        case let (.failure(err), nil, expectedError?):
            let matches: Bool
            switch (err, expectedError) {
            case (.missingChatDriverModel, "missingChatDriverModel"): matches = true
            default: matches = false
            }
            #expect(matches, "fixture \(c.id): error expected=\(expectedError) actual=\(err)")
        default:
            Issue.record("fixture \(c.id): result does not match expectation result=\(result) success=\(c.expectedSuccess ?? "nil") error=\(c.expectedError ?? "nil")")
        }
    }

    // MARK: - Extra: Codex UA string shape (spec lock, not fixture-driven)

    @Test("codexCliUserAgent shape lock: prefix codex_cli_rs/ + iOS + arm64")
    func codexUAShape() {
        let ua = RelayRuntimeSupport.codexCliUserAgent
        #expect(ua.hasPrefix("codex_cli_rs/"))
        #expect(ua.contains("iOS"))
        #expect(ua.contains("arm64"))
    }
}

// `RelayRuntimeSupport.ImageRoute` is already `String` rawRepresentable (synthesized); fixture decode needs no extra bridge.
