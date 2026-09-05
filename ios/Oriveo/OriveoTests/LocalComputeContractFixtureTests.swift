import Foundation
import Testing
@testable import Oriveo

@Suite("Local compute phase-0 contract fixtures", .serialized)
struct LocalComputeContractFixtureTests {
    @Test("generation contract freezes seven groups and four transport goldens")
    func generationContractLoads() throws {
        let contract: GenerationContract = try decodeFixture(
            ["shared", "model-contracts", "generation_parameter_contract.v1.json"]
        )
        #expect(contract.version == 1)
        #expect(contract.schema.groups == [
            "budget", "reasoning", "sampling", "repetition", "reproducibility",
            "output_contract", "engine_runtime"
        ])
        #expect(contract.schema.support.count == 8)
        #expect(contract.schema.overrideStates == ["inherit", "value", "omit"])
        #expect(contract.cases.count == 12)
        #expect(Set(contract.cases.map(\.intent.transport)).count == 4)
    }

    @Test("local classifier fixture drives the production endpoint policy red proof")
    func localClassifierRedProof() throws {
        let contract: AddressContract = try decodeFixture(
            ["shared", "test-fixtures", "relay", "local-address-classifier.v1.json"]
        )
        #expect(contract.version == 1)
        #expect(contract.cases.count == 20)

        for item in contract.cases {
            let result = RelayEndpointPolicy.classify(
                item.input,
                securityMode: RelayConnectionSecurityMode(rawValue: item.securityMode) ?? .remoteHTTPS,
                resolvedIPs: item.resolvedIPs ?? [],
                recheckResolvedIPs: item.recheckResolvedIPs,
                redirects: item.redirects ?? [],
                credentials: item.credentials.map {
                    RelayEndpointPolicy.Credentials(
                        authMode: $0.authMode.flatMap(RelayAuthMode.init(rawValue:)),
                        hasKey: $0.hasKey ?? false,
                        sensitiveHeaders: $0.sensitiveHeaders ?? []
                    )
                }
            )
            #expect(
                result.allowed == item.expect.allowed,
                "\(item.caseId) must follow \(item.expect.reason)"
            )
            #expect(result.reason == item.expect.reason)
            if let expected = item.expect.normalized {
                #expect(result.normalized == expected, "\(item.caseId) normalized URL drifted")
            }
        }
    }

    @Test("local engine scenario fixture is consumable without an engine")
    func localEngineScenariosLoad() throws {
        let fixture: EngineScenarios = try decodeFixture(
            ["shared", "test-fixtures", "local-engine", "scenarios.v1.json"]
        )
        #expect(fixture.version == 1)
        #expect(fixture.scenarios.count == 15)
        #expect(Set(fixture.scenarios.map(\.engine))
            .isSuperset(of: ["llamacpp", "ollama", "lmstudio", "vllm", "openwebui"]))
    }

    @Test("Local Compute Manual Candidate Uses Explicit Security Mode")
    func localComputeManualCandidateUsesExplicitSecurityMode() {
        let endpoint = "http://192.168.1.20:3000"
        let httpsCandidate = LocalComputeSetupView.manualCandidate(
            endpoint: endpoint,
            selectedSecurityMode: .remoteHTTPS
        )
        let localCandidate = LocalComputeSetupView.manualCandidate(
            endpoint: endpoint,
            selectedSecurityMode: .localHTTP
        )

        #expect(httpsCandidate.endpoint == endpoint)
        #expect(httpsCandidate.securityMode == .remoteHTTPS)
        #expect(localCandidate.securityMode == .localHTTP)
        #expect(LocalEngineConnector.supports(securityMode: httpsCandidate.securityMode))
    }

    @Test("Weak Pairing Payload Requires Shared Confirmation")
    func weakPairingPayloadRequiresSharedConfirmation() {
        let decision = LocalComputeSetupView.pairingSecurityDecision(
            endpoint: "http://192.168.1.20:11434",
            payloadMode: .localHTTP,
            candidates: [LocalPairingCandidate(
                endpoint: "http://192.168.1.20:11434",
                securityMode: .localHTTP
            )],
            fingerprint: nil
        )

        #expect(decision.appliedMode == nil)
        #expect(decision.candidates.isEmpty)
        #expect(decision.allowsImmediateConnect == false)
        #expect(decision.requiresExplicitWeakConfirmation)
    }

    @Test("Paired TOFUDrops Weak Fallback Candidates")
    func pairedTOFUDropsWeakFallbackCandidates() {
        let tofu = LocalPairingCandidate(
            endpoint: "https://192.168.1.20:11434",
            securityMode: .tofuHTTPS
        )
        let local = LocalPairingCandidate(
            endpoint: "http://192.168.1.20:11434",
            securityMode: .localHTTP
        )
        let vpn = LocalPairingCandidate(
            endpoint: "http://machine.tailnet.ts.net:11434",
            securityMode: .privateVPN
        )
        let decision = LocalComputeSetupView.pairingSecurityDecision(
            endpoint: tofu.endpoint,
            payloadMode: .tofuHTTPS,
            candidates: [local, tofu, vpn],
            fingerprint: String(repeating: "a", count: 64)
        )

        #expect(decision.appliedMode == .tofuHTTPS)
        #expect(decision.candidates == [tofu])
        #expect(decision.keepsFingerprint)
        #expect(decision.allowsImmediateConnect)
    }

    @Test("Paired Fingerprint Without TOFUCandidate Does Not Auto Connect")
    func pairedFingerprintWithoutTOFUCandidateDoesNotAutoConnect() {
        let decision = LocalComputeSetupView.pairingSecurityDecision(
            endpoint: "https://192.168.1.20:11434",
            payloadMode: .tofuHTTPS,
            candidates: [LocalPairingCandidate(
                endpoint: "http://192.168.1.20:11434",
                securityMode: .localHTTP
            )],
            fingerprint: String(repeating: "b", count: 64)
        )

        #expect(decision.appliedMode == .tofuHTTPS)
        #expect(decision.candidates.isEmpty)
        #expect(decision.allowsImmediateConnect == false)
    }

    @Test("Open Web UICleartext Credential Is Rejected")
    func openWebUICleartextCredentialIsRejected() async {
        let connectionError = await #expect(throws: LocalEngineConnectionError.self) {
            _ = try await LocalEngineConnector.connect(
                engine: .openwebui,
                endpoint: "http://192.168.1.20:3000",
                securityMode: .localHTTP,
                apiKey: "owui-key"
            )
        }
        #expect(connectionError == .cleartextCredentials)
        #expect(connectionError?.errorDescription == L10n.tr(
            "An unencrypted connection can't carry a key. Change the address and connection type to Public HTTPS.",
            table: .providers
        ))

        let discoveryError = await #expect(throws: LocalEngineConnectionError.self) {
            _ = try await LocalEngineConnector.verifyCandidate(
                engine: .openwebui,
                endpoint: "http://192.168.1.20:3000",
                securityMode: .localHTTP,
                apiKey: "owui-key"
            )
        }
        #expect(discoveryError == .cleartextCredentials)
    }

    private func decodeFixture<T: Decodable>(_ components: [String]) throws -> T {
        let path = try fixtureURL(components)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: path))
    }

    private func fixtureURL(_ components: [String]) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = components.reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private struct GenerationContract: Decodable {
        let version: Int
        let schema: GenerationSchema
        let cases: [GenerationCase]
    }

    private struct GenerationSchema: Decodable {
        let support: [String]
        let overrideStates: [String]
        let groups: [String]
    }

    private struct GenerationCase: Decodable {
        let intent: GenerationIntent
    }

    private struct GenerationIntent: Decodable {
        let transport: String
    }

    private struct AddressContract: Decodable {
        let version: Int
        let cases: [AddressCase]
    }

    private struct AddressCase: Decodable {
        let caseId: String
        let input: String
        let securityMode: String
        let resolvedIPs: [String]?
        let recheckResolvedIPs: [String]?
        let redirects: [String]?
        let credentials: AddressCredentials?
        let expect: AddressExpectation
    }

    private struct AddressCredentials: Decodable {
        let authMode: String?
        let hasKey: Bool?
        let sensitiveHeaders: [String]?
    }

    private struct AddressExpectation: Decodable {
        let allowed: Bool
        let reason: String
        let normalized: String?
    }

    private struct EngineScenarios: Decodable {
        let version: Int
        let scenarios: [EngineScenario]
    }

    private struct EngineScenario: Decodable {
        let engine: String
    }
}
