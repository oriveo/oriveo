import Foundation
import Testing
@testable import Oriveo

/// Fake upstream for the edit page's 1-token verification: when `passes` is true it returns the minimal success body of a llama.cpp native completion, otherwise 500.
private final class LocalEngineEditVerificationProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var passes = true
    nonisolated(unsafe) static var requested: [String] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requested.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
        let status = Self.passes ? 200 : 500
        let body = Self.passes
            ? Data(#"{"content":"ok","stop":true}"#.utf8)
            : Data(#"{"error":{"message":"boom"}}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Edit and thinking rows of a local connection (the `edit` / `thinking` / `channels` sections of `shared/test-fixtures/local-engine/engine-expectations.v1.json`).
/// Driven by caseId; thinking assertions come from the production projection of `ModelOptionCapabilityShape.resolve`,
/// and edit assertions come from the data plane of the edit page's save path and the production 1-token verification.
@Suite("Relay 2.0 · local connection edit and thinking rows", .serialized)
@MainActor
struct LocalEngineEditAndThinkingContractTests {
    typealias Shape = ModelOptionCapabilityShape
    private static var retainedStates: [AppState] = []

    // MARK: - Fixtures

    private func expectations() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("local-engine")
                .appendingPathComponent("engine-expectations.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func channelWire(_ channel: String, channels: [String: Any]) throws -> String {
        try #require(channels[channel] as? String)
    }

    // MARK: - RL2-ENGINE-04 thinking

    private func thinkingKind(_ shape: Shape) -> String {
        switch shape {
        case .toggle(let toggle) where toggle.target == .chatTemplateThinking:
            return "toggle"
        case .notice(let notice) where notice.status == L10n.tr("Needs manual setup", table: .chat):
            return "nonChatNotice"
        case .notice(let notice) where notice.status == L10n.tr("Uses the model’s default", table: .chat):
            return "usesModelDefaultNotice"
        case .disclosure(let disclosure)
            where disclosure.status == L10n.tr("This model has no thinking mode", table: .chat):
            return "unsupported"
        default:
            return "other: \(shape)"
        }
    }

    /// The same set of facts as the model options panel: presentation state, resolved protocol and write-path table, handed to production `resolve`.
    private func thinkingShape(provider: Provider, model: AIModel) -> Shape {
        let transport = CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
            provider: provider, model: model, resolvedFinalTransport: nil
        )
        return Shape.resolve(.init(
            capability: .reasoning,
            presentation: CapabilityControlPresentationResolver.presentation(
                provider: provider, model: model, capability: "reasoning"
            ),
            connection: .custom,
            isWritable: true,
            supportsChatTemplate: ChatTemplateThinkingSwitch.applies(toTransport: transport),
            localEngineThinking: Shape.localEngineThinking(provider: provider, model: model)
        ))
    }

    private func thinkingFixture(
        engineProfile: String?, transport: String, declaredThinking: Bool?
    ) throws -> (Provider, AIModel) {
        let wire = try #require(RelayTransport(rawValue: transport))
        var model = TestFactories.makeModel(id: "local-model", capabilities: [.text], isDefault: true)
        if let declaredThinking { model.engineDeclaration = EngineDeclaration(thinking: declaredThinking) }
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], baseURLText: "http://127.0.0.1:8080"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: wire,
            authMode: .none,
            securityMode: .localHTTP,
            engineProfile: engineProfile
        )
        return (provider, model)
    }

    @Test("RL2-ENGINE-04 thinking: each thinking.cases entry produces its shape from engineProfile x channel write-path table")
    func rl2Engine04ThinkingCases() throws {
        let root = try expectations()
        let channels = try #require(root["channels"] as? [String: Any])
        let thinking = try #require(root["thinking"] as? [String: Any])
        let cases = try #require(thinking["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let caseId = try #require(item["caseId"] as? String)
            let channel = try #require(item["channel"] as? String)
            let (provider, model) = try thinkingFixture(
                engineProfile: item["engineProfile"] as? String,
                transport: try channelWire(channel, channels: channels),
                declaredThinking: item["declaredThinking"] as? Bool
            )
            let shape = thinkingShape(provider: provider, model: model)
            #expect(thinkingKind(shape) == (item["expect"] as? String), "\(caseId)")
        }
    }

    @Test("RL2-ENGINE-04 when the catalog gives a presentation state other than unknown, a local connection is still judged by the write-path table first")
    func rl2Engine04TableWinsOverCatalogPresentation() throws {
        let (provider, model) = try thinkingFixture(
            engineProfile: "ollama", transport: "openai_chat_completions", declaredThinking: true
        )
        let local = Shape.localEngineThinking(provider: provider, model: model)
        let presentations: [CapabilityControlPresentation] = [.automaticAvailable, .customOnly, .unsupported]
        for presentation in presentations {
            let shape = Shape.resolve(.init(
                capability: .reasoning,
                presentation: presentation,
                connection: .custom,
                isWritable: true,
                supportsChatTemplate: true,
                localEngineThinking: local
            ))
            #expect(thinkingKind(shape) == "usesModelDefaultNotice", "\(presentation)")
        }
    }

    @Test("RL2-ENGINE-04 write-path table: writable <=> the chat-template toggle appears, otherwise it does not")
    func rl2Engine04WritePaths() throws {
        let root = try expectations()
        let channels = try #require(root["channels"] as? [String: Any])
        let paths = try #require((root["thinking"] as? [String: Any])?["writePaths"] as? [[String: Any]])
        #expect(!paths.isEmpty)
        for row in paths {
            let engine = try #require(row["engineProfile"] as? String)
            let channel = try #require(row["channel"] as? String)
            let (provider, model) = try thinkingFixture(
                engineProfile: engine, transport: try channelWire(channel, channels: channels), declaredThinking: nil
            )
            let writable = try #require(row["writable"] as? Bool)
            #expect(
                (Shape.localEngineThinking(provider: provider, model: model) == .chatTemplateToggle) == writable,
                "\(engine)/\(channel)"
            )
            #expect((thinkingKind(thinkingShape(provider: provider, model: model)) == "toggle") == writable,
                    "\(engine)/\(channel)")
        }
    }

    // MARK: - RL2-ENGINE-03 edit

    @Test("RL2-ENGINE-03 channel candidates: only from channels.byEngine, no picker when there is a single one; non-local connections have no candidates")
    func rl2Engine03ChannelCandidates() throws {
        let root = try expectations()
        let channels = try #require(root["channels"] as? [String: Any])
        let byEngine = try #require(channels["byEngine"] as? [String: [String]])
        #expect(!byEngine.isEmpty)
        for (engine, expected) in byEngine {
            let wires = try expected.map { try channelWire($0, channels: channels) }
            #expect(LocalEngineChannelCandidates.candidates(engineProfile: engine).map(\.rawValue) == wires, "\(engine)")
            #expect(LocalEngineChannelCandidates.showsSelector(engineProfile: engine) == (wires.count > 1), "\(engine)")
            // The production data source for the edit page's protocol menu: a local connection offers only that engine's channel set.
            #expect(LocalEngineChannelCandidates.transportOptions(engineProfile: engine).map(\.rawValue) == wires, "\(engine)")
        }
        #expect(LocalEngineChannelCandidates.candidates(engineProfile: nil).isEmpty)
        #expect(!LocalEngineChannelCandidates.showsSelector(engineProfile: nil))
        #expect(LocalEngineChannelCandidates.transportOptions(engineProfile: nil) == RelayTransport.allUICases)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalEngineEditVerificationProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeState() -> AppState {
        let state = AppState(
            sessionUID: "local-engine-edit-tests-\(UUID().uuidString)",
            providerSession: makeSession()
        )
        state.providers = []
        state.conversations = []
        Self.retainedStates.append(state)
        return state
    }

    private func editFixtureProvider(_ connection: [String: Any]) throws -> Provider {
        let requested = try #require(connection["relayRequested"] as? [String: Any])
        let transportRaw = try #require(requested["transport"] as? String)
        let securityRaw = try #require(requested["securityMode"] as? String)
        let transport = try #require(RelayTransport(rawValue: transportRaw))
        let securityMode = try #require(RelayConnectionSecurityMode(rawValue: securityRaw))
        let baseURL = try #require(connection["baseURL"] as? String)
        let model = TestFactories.makeModel(id: "local-model", capabilities: [.text], isDefault: true)
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], apiKey: "old-key", baseURLText: baseURL
        )
        provider.relayKind = .custom
        provider.relayRequested = RelayRequestedConfig(
            transport: transport,
            authMode: .bearer,
            securityMode: securityMode,
            modelID: "local-model",
            engineProfile: try #require(requested["engineProfile"] as? String),
            certificateFingerprint: try #require(requested["certificateFingerprint"] as? String)
        )
        return provider
    }

    private func engineFields(_ requested: RelayRequestedConfig?) -> [String?] {
        [requested?.engineProfile, requested?.securityMode.rawValue, requested?.certificateFingerprint]
    }

    @Test("RL2-ENGINE-03 edit: each edit.cases entry, engineProfile / securityMode / certificate fingerprint are kept as is; changing the channel re-verifies, and on failure the user's value is still saved and marked unverified")
    func rl2Engine03EditCases() async throws {
        let root = try expectations()
        let edit = try #require(root["edit"] as? [String: Any])
        let connection = try #require(edit["connection"] as? [String: Any])
        let cases = try #require(edit["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        let saved = try editFixtureProvider(connection)
        let originalEngineFields = engineFields(saved.relayRequested)

        for item in cases {
            let caseId = try #require(item["caseId"] as? String)
            let change = try #require(item["change"] as? [String: Any])
            let expect = try #require(item["expect"] as? [String: Any])

            if let newKey = change["apiKey"] as? String {
                // Replacing the key goes through production `updateAPIKey` (the edit page's "replace key" entry), not the editor.
                LocalEngineEditVerificationProtocol.passes = false
                let state = makeState()
                state.providers = [saved]
                _ = try? await state.providerManager.updateAPIKey(providerID: saved.id, newKey: newKey)
                let stored = try #require(state.provider(for: saved.id))
                #expect(stored.apiKey == newKey, "\(caseId)")
                #expect(engineFields(stored.relayRequested) == originalEngineFields, "\(caseId)")
                continue
            }

            var editor = RelayEditView.Editor(from: saved)
            if let baseURL = change["baseURL"] as? String { editor.endpoint = baseURL }
            if let transport = change["transport"] as? String {
                editor.transport = try #require(RelayTransport(rawValue: transport))
            }
            if change["relayKind"] != nil {
                // The edit-connection page has no type layer: this platform offers no "other type" to switch to, and relayKind is only a display value derived from the channel at save time.
                // What remains of this case is "engine fields are unchanged after saving", asserted as usual below.
                #expect(RelayEditSavePolicy.savedRelayKind(editor: editor) == RelayKind(transport: editor.transport), "\(caseId)")
            }
            let normalized = try #require(RelayEndpointPolicy.normalize(editor.endpoint, securityMode: editor.securityMode))
            let requested = RelayEditSavePolicy.savedRequested(
                editor: editor, provider: saved, normalizedEndpoint: normalized
            )
            #expect(engineFields(requested) == originalEngineFields, "\(caseId)")

            guard expect["verifiesDefaultModel"] as? Bool == true else { continue }
            #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: editor) == .validateAndSave, "\(caseId)")
            var candidate = saved
            candidate.baseURLText = normalized
            candidate.relayRequested = requested
            LocalEngineEditVerificationProtocol.passes = item["verification"] as? String == "passes"
            let state = makeState()
            var verified = true
            do {
                try await state.providerManager.verifyRelayGeneration(candidate)
            } catch {
                verified = false
            }
            candidate = RelayEditSavePolicy.recordingVerification(candidate, verified: verified)
            #expect(candidate.relayRequested?.transport.rawValue == expect["transport"] as? String, "\(caseId)")
            #expect(engineFields(candidate.relayRequested) == originalEngineFields, "\(caseId)")
            let expectedVerified = try #require(expect["verified"] as? Bool)
            #expect(verified == expectedVerified, "\(caseId)")
            #expect(
                candidate.status == (expectedVerified
                    ? .connected
                    : .issue(ProviderIssueMessage.unverifiedConnectionKey)),
                "\(caseId)"
            )
        }
    }
}
