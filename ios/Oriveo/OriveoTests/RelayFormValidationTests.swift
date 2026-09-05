import Foundation
import Testing
@testable import Oriveo

@Suite("Relay form validation")
struct RelayFormValidationTests {


    @Test("Field Layout Matches Fixture")
    func fieldLayoutMatchesFixture() throws {
        let contract = try loadContract()
        #expect(contract.version == 1)
        #expect(contract.form.fields.count == RelayFormValidation.fields.count)

        for (index, expected) in contract.form.fields.enumerated() {
            let actual = RelayFormValidation.fields[index]
            #expect(
                actual.field.rawValue == expected.field,
                "Field \(index) should be \(expected.field), got \(actual.field.rawValue) — layout order is shared by both flows and must not diverge"
            )
            #expect(actual.group.rawValue == expected.group)
            #expect(actual.labelKey == expected.labelEN)
            #expect(actual.placeholder == expected.placeholder)
            #expect(actual.revalidation.rawValue == expected.revalidation)
        }
    }

    @Test("Security Mode Has Visible Label")
    func securityModeHasVisibleLabel() throws {
        let definition = try #require(RelayFormValidation.definition(for: .securityMode))
        #expect(definition.labelKey == "Connection security")
        for definition in RelayFormValidation.fields {
            #expect(definition.labelKey?.isEmpty == false)
        }
    }

    @Test("Tofu Is Not Selectable But Keeps An Honest Summary")
    func tofuIsNotSelectableButKeepsAnHonestSummary() {
        #expect(RelaySecurityModeSelection.selectableModes == [.remoteHTTPS, .localHTTP, .privateVPN])
        #expect(RelaySecurityModeSelection.selectableModes.contains(.tofuHTTPS) == false)
        #expect(RelaySecurityModeSummaryRow.title(for: .tofuHTTPS) == L10n.tr("Paired HTTPS", table: .providers))
        #expect(RelaySecurityModeSummaryRow.title(for: .tofuHTTPS) != RelaySecurityModeSummaryRow.title(for: .remoteHTTPS))
    }

    @Test("Scheme Writeback And Encrypted Negative Path")
    func schemeWritebackAndEncryptedNegativePath() async {
        let assessment = await RelaySecurityModeSelection.assess(endpoint: "https://192.168.1.20:1234")
        #expect(assessment.localHTTPAllowed == false)
        #expect(assessment.privateVPNAllowed == false)
        #expect(assessment.denialReason == "encrypted_endpoint")
        #expect(RelaySecurityModeSelection.normalizedEndpoint(
            "192.168.1.20:1234",
            securityMode: .localHTTP
        ) == "http://192.168.1.20:1234")

        let remoteWriteback = RelaySecurityModeSelection.endpointWriteback(
            "relay.example.com/v1",
            securityMode: .remoteHTTPS
        )
        #expect(remoteWriteback?.endpoint == "https://relay.example.com/v1")
        #expect(remoteWriteback?.didChange == true)
    }

    @Test("Reconnect Persistence Gate Rejects Stale Work")
    func reconnectPersistenceGateRejectsStaleWork() {
        let remote = RelayRequestedConfig(securityMode: .remoteHTTPS)
        let local = RelayRequestedConfig(securityMode: .localHTTP)

        #expect(RelaySecurityModeSelection.allowsReconnectPersistence(
            expectedGeneration: 7,
            currentGeneration: 7,
            expectedMode: .remoteHTTPS,
            currentRequested: remote
        ))
        #expect(RelaySecurityModeSelection.allowsReconnectPersistence(
            expectedGeneration: 6,
            currentGeneration: 7,
            expectedMode: .remoteHTTPS,
            currentRequested: remote
        ) == false)
        #expect(RelaySecurityModeSelection.allowsReconnectPersistence(
            expectedGeneration: 7,
            currentGeneration: 7,
            expectedMode: .remoteHTTPS,
            currentRequested: local
        ) == false)
    }

    @Test("Persisted Security Baseline Preserves Advanced Original")
    func persistedSecurityBaselinePreservesAdvancedOriginal() {
        var baseline = RelayEditView.Editor.empty
        baseline.endpoint = "relay.example.com"
        baseline.transport = .anthropicMessages
        baseline.modelID = "saved-model"
        baseline.customUserAgent = "saved-agent"
        baseline.headers = [RelayKeyValue(key: "Authorization", value: "saved")]

        let updated = baseline.applyingPersistedSecurityBaseline(
            endpoint: "http://192.168.1.20:1234",
            securityMode: .localHTTP,
            clearsCredentialTables: true
        )

        #expect(updated.endpoint == "http://192.168.1.20:1234")
        #expect(updated.securityMode == .localHTTP)
        #expect(updated.authMode == .none)
        #expect(updated.headers.isEmpty)
        #expect(updated.transport == .anthropicMessages)
        #expect(updated.modelID == "saved-model")
        #expect(updated.customUserAgent == "saved-agent")
    }

    @Test("Security Mode Transition Keeps Unsaved Advanced Draft Out Of Persistence")
    func securityModeTransitionKeepsUnsavedAdvancedDraftOutOfPersistence() {
        let saved = RelayRequestedConfig(
            transport: .anthropicMessages,
            authMode: .none,
            securityMode: .remoteHTTPS,
            modelID: "saved-model",
            reasoningEffort: .high,
            serviceTier: "saved-tier",
            stream: true,
            headers: [RelayKeyValue(key: "X-Ordinary", value: "saved")],
            queryParams: [RelayKeyValue(key: "api_key", value: "saved-secret")],
            customUserAgent: "saved-agent",
            resolvedAPIBaseURL: "https://relay.example.com/v1"
        )

        let result = RelaySecurityModeSelection.persistedTransition(
            savedRequested: saved,
            storedAPIKey: "",
            draftAuthMode: .none,
            draftHeaders: [RelayKeyValue(key: "X-Draft", value: "must-not-persist")],
            draftQueryParams: [],
            nextMode: .localHTTP
        )

        #expect(result.clearsStoredAPIKey)
        #expect(result.clearsCredentialTables)
        #expect(result.requested.securityMode == .localHTTP)
        #expect(result.requested.authMode == .none)
        #expect(result.requested.headers == nil)
        #expect(result.requested.queryParams == nil)
        #expect(result.requested.resolvedAPIBaseURL == nil)
        #expect(result.requested.transport == saved.transport)
        #expect(result.requested.modelID == saved.modelID)
        #expect(result.requested.reasoningEffort == saved.reasoningEffort)
        #expect(result.requested.serviceTier == saved.serviceTier)
        #expect(result.requested.stream == saved.stream)
        #expect(result.requested.customUserAgent == saved.customUserAgent)
    }

    @Test("Remote Security Mode Transition Preserves Saved Credential Configuration")
    func remoteSecurityModeTransitionPreservesSavedCredentialConfiguration() {
        let saved = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .none,
            securityMode: .localHTTP,
            headers: [RelayKeyValue(key: "X-Ordinary", value: "saved")],
            queryParams: [RelayKeyValue(key: "region", value: "sg")],
            resolvedAPIBaseURL: "http://192.168.1.20:1234/v1"
        )

        let result = RelaySecurityModeSelection.persistedTransition(
            savedRequested: saved,
            storedAPIKey: "",
            draftAuthMode: .bearer,
            draftHeaders: [RelayKeyValue(key: "Authorization", value: "draft-secret")],
            draftQueryParams: [],
            nextMode: .remoteHTTPS
        )

        #expect(result.clearsStoredAPIKey == false)
        #expect(result.clearsCredentialTables == false)
        #expect(result.requested.securityMode == .remoteHTTPS)
        #expect(result.requested.authMode == saved.authMode)
        #expect(result.requested.headers == saved.headers)
        #expect(result.requested.queryParams == saved.queryParams)
        #expect(result.requested.resolvedAPIBaseURL == nil)
    }

    @Test("Issue Messages Are Resolvable")
    func issueMessagesAreResolvable() {
        for code in [
            RelayFormValidation.IssueCode.endpointRequired,
            .endpointRejected,
            .cleartextCredentials,
            .securityModeSchemeMismatch,
            .credentialRequired,
            .credentialInvalidCharacters,
        ] {
            #expect(code.messageKey.isEmpty == false)
            #expect(code.localizedMessage.isEmpty == false)
        }
        #expect(RelayFormValidation.IssueCode.endpointRequired.isSilentRequirement)
        #expect(RelayFormValidation.IssueCode.credentialRequired.isSilentRequirement)
        #expect(RelayFormValidation.IssueCode.endpointRejected.isSilentRequirement == false)
        #expect(RelayFormValidation.IssueCode.securityModeSchemeMismatch.isSilentRequirement == false)
    }


    @Test("Fixture Cases Drive Validation")
    func fixtureCasesDriveValidation() throws {
        let contract = try loadContract()
        #expect(contract.cases.count == 15)

        for item in contract.cases {
            let draft = try productionDraft(item.draft)
            let mode: RelayCredentialPolicy.FormMode = item.mode == "edit" ? .edit : .create
            let issues = RelayFormValidation.validate(draft, mode: mode)

            #expect(
                issues.isEmpty == item.expect.valid,
                "\(item.caseId) expected valid=\(item.expect.valid), got issues=\(issues.map(\.code.rawValue))"
            )
            #expect(
                issues.map(\.field.rawValue) == item.expect.issues.map(\.field),
                "\(item.caseId) issue field ownership drifted"
            )
            #expect(
                issues.map(\.code.rawValue) == item.expect.issues.map(\.code),
                "\(item.caseId) issue code drifted"
            )
            for (actual, expected) in zip(issues, item.expect.issues) {
                if let detail = expected.detail {
                    #expect(actual.detail == detail)
                }
            }
        }
    }

    @Test("Credential Matrix Is Fully Covered")
    func credentialMatrixIsFullyCovered() throws {
        let contract = try loadContract()
        let states = contract.credentialMatrix.map(\.state)
        #expect(states.count == 4)
        for state in states {
            let modes = contract.cases.filter { $0.matrixState == state }.map(\.mode).sorted()
            #expect(modes == ["create", "edit"], "Matrix state \(state) missing create/edit coverage: \(modes)")
        }
    }


    @Test("Credential Gate Is Delegated")
    func credentialGateIsDelegated() {
        let bearer = RelayKindDefaults.makeRequested(for: .openaiCompatible)
        let keyless = RelayKindDefaults.makeRequested(
            for: .custom,
            preserving: RelayRequestedConfig(authMode: RelayAuthMode.none)
        )

        let bearerDraft = RelayFormDraft(requested: bearer, endpoint: "https://relay.example.com/v1")
        let keylessDraft = RelayFormDraft(requested: keyless, endpoint: "https://relay.example.com/v1")

        #expect(RelayFormValidation.validate(bearerDraft, mode: .create).map(\.code) == [.credentialRequired])
        #expect(RelayFormValidation.validate(keylessDraft, mode: .create).isEmpty)
        #expect(RelayFormValidation.validate(bearerDraft, mode: .edit).isEmpty)
    }

    @Test("Endpoint Gate Matches Save Path")
    func endpointGateMatchesSavePath() throws {
        let requested = try JSONDecoder().decode(
            RelayRequestedConfig.self,
            from: Data(#"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http"}"#.utf8)
        )
        for endpoint in [
            "http://192.168.1.20:1234/v1",
            "http://203.0.113.8:1234/v1",
            "http://user:pass@192.168.1.20:1234",
            "ftp://192.168.1.20:1234",
        ] {
            let draft = RelayFormDraft(requested: requested, endpoint: endpoint)
            let formSaysOK = RelayFormValidation.validate(draft, mode: .edit).isEmpty
            let savePathSaysOK = (try? RelayEndpointPolicy.requireConfigured(
                endpoint,
                securityMode: .localHTTP,
                credentials: RelayCredentialPolicy.endpointCredentials(for: requested, hasStoredKey: false)
            )) != nil
            #expect(formSaysOK == savePathSaysOK)
        }
    }

    @Test("Normalized Endpoint Matches Save Path")
    func normalizedEndpointMatchesSavePath() throws {
        let requested = try JSONDecoder().decode(
            RelayRequestedConfig.self,
            from: Data(#"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http"}"#.utf8)
        )
        let draft = RelayFormDraft(requested: requested, endpoint: "192.168.1.20:1234/v1/")
        #expect(RelayFormValidation.normalizedEndpoint(draft, mode: .edit) == "http://192.168.1.20:1234/v1")
        let rejected = RelayFormDraft(requested: requested, endpoint: "http://user:pass@192.168.1.20:1234")
        #expect(RelayFormValidation.normalizedEndpoint(rejected, mode: .edit) == nil)
    }


    private func productionDraft(_ raw: FixtureDraft) throws -> RelayFormDraft {
        var payload: [String: Any] = [
            "transport": raw.transport,
            "authMode": raw.authMode,
            "securityMode": raw.securityMode,
        ]
        if !raw.modelId.isEmpty { payload["modelID"] = raw.modelId }
        if !raw.headers.isEmpty { payload["headers"] = raw.headers.map { ["key": $0.key, "value": $0.value] } }
        if !raw.queryParams.isEmpty {
            payload["queryParams"] = raw.queryParams.map { ["key": $0.key, "value": $0.value] }
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let requested = try JSONDecoder().decode(RelayRequestedConfig.self, from: data)
        return RelayFormDraft(
            requested: requested,
            endpoint: raw.endpoint,
            apiKey: raw.apiKey,
            hasSavedCredential: raw.hasSavedCredential
        )
    }

    private func loadContract() throws -> FormContract {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("relay")
                .appendingPathComponent("form-validation.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(FormContract.self, from: Data(contentsOf: candidate))
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private struct FormContract: Decodable {
        let version: Int
        let form: FixtureForm
        let credentialMatrix: [FixtureMatrixState]
        let cases: [FixtureCase]
    }

    private struct FixtureForm: Decodable {
        let fields: [FixtureField]
    }

    private struct FixtureField: Decodable {
        let field: String
        let group: String
        let labelEN: String?
        let placeholder: String?
        let revalidation: String
    }

    private struct FixtureMatrixState: Decodable {
        let state: String
    }

    private struct FixtureCase: Decodable {
        let caseId: String
        let matrixState: String?
        let mode: String
        let draft: FixtureDraft
        let expect: FixtureExpectation
    }

    private struct FixtureDraft: Decodable {
        let endpoint: String
        let apiKey: String
        let authMode: String
        let securityMode: String
        let transport: String
        let modelId: String
        let headers: [FixtureKeyValue]
        let queryParams: [FixtureKeyValue]
        let hasSavedCredential: Bool
    }

    private struct FixtureKeyValue: Decodable {
        let key: String
        let value: String
    }

    private struct FixtureExpectation: Decodable {
        let valid: Bool
        let issues: [FixtureIssue]
    }

    private struct FixtureIssue: Decodable {
        let field: String
        let code: String
        let detail: String?
    }
}
