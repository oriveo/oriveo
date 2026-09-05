import Foundation
import Testing
@testable import Oriveo

@Suite("Relay credential policy")
struct RelayCredentialPolicyTests {


    private func decodedRequested(_ json: String) throws -> RelayRequestedConfig {
        try JSONDecoder().decode(RelayRequestedConfig.self, from: Data(json.utf8))
    }

    @Test("Requires Credential Derivation")
    func requiresCredentialDerivation() throws {
        let none = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http"}"#)
        let bearer = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"bearer","securityMode":"remote_https"}"#)
        let auto = try decodedRequested(#"{"transport":"auto","authMode":"auto","securityMode":"remote_https"}"#)
        let unknown = try decodedRequested(#"{"transport":"auto","authMode":"oauth_device","securityMode":"remote_https"}"#)
        let missingField = try decodedRequested(#"{"transport":"auto","securityMode":"remote_https"}"#)

        #expect(RelayCredentialPolicy.requiresCredential(none) == false)
        #expect(RelayCredentialPolicy.requiresCredential(bearer))
        #expect(RelayCredentialPolicy.requiresCredential(auto))
        #expect(RelayCredentialPolicy.requiresCredential(unknown))
        #expect(RelayCredentialPolicy.requiresCredential(missingField))
        #expect(RelayCredentialPolicy.requiresCredential(nil))
    }

    @Test("Preset Kinds Require Credential")
    func presetKindsRequireCredential() {
        for kind in [RelayKind.openaiCompatible, .codexStyle, .anthropicCompatible, .geminiCompatible, .custom] {
            let requested = RelayKindDefaults.makeRequested(for: kind)
            #expect(
                RelayCredentialPolicy.requiresCredential(requested),
                "Preset \(kind.rawValue) default authMode should not be none"
            )
        }
        let keyless = RelayKindDefaults.makeRequested(
            for: .custom,
            preserving: RelayRequestedConfig(authMode: RelayAuthMode.none)
        )
        #expect(RelayCredentialPolicy.requiresCredential(keyless) == false)
    }

    // MARK: - S0–S3

    @Test("State Not Required")
    func stateNotRequired() throws {
        let requested = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http"}"#)
        #expect(RelayCredentialPolicy.state(requested, hasStoredKey: false) == .notRequired)
    }

    @Test("State Missing And Present")
    func stateMissingAndPresent() throws {
        let requested = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"bearer","securityMode":"remote_https"}"#)
        #expect(RelayCredentialPolicy.state(requested, hasStoredKey: false) == .missing)
        #expect(RelayCredentialPolicy.state(requested, hasStoredKey: true) == .present)
    }

    @Test("State Conflict")
    func stateConflict() throws {
        let stillAuthed = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"bearer","securityMode":"local_http"}"#)
        #expect(RelayCredentialPolicy.state(stillAuthed, hasStoredKey: false) == .conflict)

        let leftoverKey = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"none","securityMode":"private_vpn"}"#)
        #expect(RelayCredentialPolicy.state(leftoverKey, hasStoredKey: true) == .conflict)

        let sensitiveHeader = try decodedRequested(
            #"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http","headers":[{"key":"Authorization","value":"Bearer x"}]}"#
        )
        #expect(RelayCredentialPolicy.state(sensitiveHeader, hasStoredKey: false) == .conflict)

        let benignHeader = try decodedRequested(
            #"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http","headers":[{"key":"X-Trace","value":"1"}]}"#
        )
        #expect(RelayCredentialPolicy.state(benignHeader, hasStoredKey: false) == .notRequired)
    }

    @Test("Encrypted Connection Is Never Conflict")
    func encryptedConnectionIsNeverConflict() throws {
        let requested = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"none","securityMode":"remote_https"}"#)
        #expect(RelayCredentialPolicy.state(requested, hasStoredKey: true) == .notRequired)
    }

    // MARK: - T3 / T4 / T5

    @Test("Remove Credential Keeps Auth Mode")
    func removeCredentialKeepsAuthMode() {
        let mutation = RelayCredentialPolicy.removeCredential(currentAuthMode: .bearer)
        #expect(mutation.authMode == .bearer)
        #expect(mutation.clearsStoredKey)
        #expect(RelayCredentialPolicy.removeCredential(currentAuthMode: nil).authMode == .auto)
    }

    @Test("Set Auth Mode None Clears Stored Key")
    func setAuthModeNoneClearsStoredKey() {
        #expect(
            RelayCredentialPolicy.setAuthMode(RelayAuthMode.none, hasStoredKey: true)
                == RelayCredentialPolicy.Mutation(authMode: RelayAuthMode.none, clearsStoredKey: true)
        )
        #expect(
            RelayCredentialPolicy.setAuthMode(RelayAuthMode.none, hasStoredKey: false)
                == RelayCredentialPolicy.Mutation(authMode: RelayAuthMode.none, clearsStoredKey: false)
        )
        #expect(
            RelayCredentialPolicy.setAuthMode(.xApiKey, hasStoredKey: true)
                == RelayCredentialPolicy.Mutation(authMode: .xApiKey, clearsStoredKey: false)
        )
    }

    @Test("Credential Input Gate")
    func credentialInputGate() {
        let keyless = RelayKindDefaults.makeRequested(
            for: .custom,
            preserving: RelayRequestedConfig(authMode: RelayAuthMode.none)
        )
        let bearer = RelayKindDefaults.makeRequested(for: .openaiCompatible)

        #expect(RelayCredentialPolicy.credentialInputRequired(mode: .create, authMode: keyless.authMode, hasStoredKey: false) == false)
        #expect(RelayCredentialPolicy.credentialInputRequired(mode: .create, authMode: bearer.authMode, hasStoredKey: false))

        for authMode in [RelayAuthMode.auto, .bearer, .xApiKey, .xGoogApiKey, .queryKey, RelayAuthMode.none] {
            for hasStoredKey in [true, false] {
                #expect(
                    RelayCredentialPolicy.credentialInputRequired(
                        mode: .edit, authMode: authMode, hasStoredKey: hasStoredKey
                    ) == false,
                    "Edit-state authMode=\(authMode.rawValue) hasStoredKey=\(hasStoredKey) should not require a key"
                )
            }
        }
    }


    @Test("Save Time Interlock Uses Endpoint Policy")
    func saveTimeInterlockUsesEndpointPolicy() throws {
        let cleartextWithAuth = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"bearer","securityMode":"local_http"}"#)
        let denied = RelayEndpointPolicy.classify(
            "http://192.168.31.250:1234/v1",
            securityMode: .localHTTP,
            credentials: RelayCredentialPolicy.endpointCredentials(for: cleartextWithAuth, hasStoredKey: true)
        )
        #expect(denied.allowed == false)
        #expect(denied.reason == "cleartext_credentials")

        let keyless = try decodedRequested(#"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http"}"#)
        let allowed = RelayEndpointPolicy.classify(
            "http://192.168.31.250:1234/v1",
            securityMode: .localHTTP,
            credentials: RelayCredentialPolicy.endpointCredentials(for: keyless, hasStoredKey: false)
        )
        #expect(allowed.allowed)
    }


    @Test("Masking Threshold")
    func maskingThreshold() {
        #expect(APIKeyMask.masked("sk-123456") == APIKeyMask.fullyMasked)
        #expect(APIKeyMask.masked("sk-abcdefghi") == APIKeyMask.fullyMasked)
        #expect(APIKeyMask.masked("sk-abcdefghij") == "sk-a…ghij")
        #expect(APIKeyMask.masked("sk-proj-0123456789abcdef7f2a") == "sk-p…7f2a")
    }

    @Test("Masking Empty Returns Empty")
    func maskingEmptyReturnsEmpty() {
        #expect(APIKeyMask.masked("") == "")
        #expect(APIKeyMask.masked("   ") == "")
        #expect(APIKeyMask.masked("").isEmpty)
    }

    @Test("Masking Leaks At Most Eight Characters")
    func maskingLeaksAtMostEightCharacters() {
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz"
        let masked = APIKeyMask.masked(key)
        #expect(masked == "sk-p…wxyz")
        #expect(masked.contains("proj-abcdefghijklmnopqrstuv") == false)
    }
}
