import Testing
@testable import Oriveo

@Suite("Local pairing payload")
struct LocalPairingPayloadTests {
    @Test func parsesV1WithoutCredentials() throws {
        let result = try LocalPairingPayload.decode(#"{"v":1,"name":"Fixture Mac","urls":["http://192.168.1.20:8080","http://100.101.102.103:8080"],"engine":"llamacpp","auth":"none"}"#)
        #expect(result.engine == .llamacpp)
        #expect(result.endpoint == "http://192.168.1.20:8080")
        #expect(result.securityMode == .localHTTP)
        #expect(result.candidates.count == 2)
        #expect(result.candidates[1].securityMode == .privateVPN)
    }

    @Test func rejectsSecret() {
        #expect(throws: LocalPairingError.self) {
            try LocalPairingPayload.decode("oriveo://local-provider?v=1&engine=ollama&endpoint=http%3A%2F%2F127.0.0.1%3A11434&mode=local_http&auth=none&api_key=secret")
        }
    }

    @Test func rejectsSecretNestedInEndpoint() {
        #expect(throws: LocalPairingError.self) {
            try LocalPairingPayload.decode("oriveo://local-provider?v=1&engine=ollama&endpoint=http%3A%2F%2F127.0.0.1%3A11434%2F%3Fclient_secret%3Dx&mode=local_http&auth=none")
        }
    }

    @Test func rejectsDuplicateURIFieldWithoutCrashing() {
        #expect(throws: LocalPairingError.duplicateField) {
            try LocalPairingPayload.decode(
                "oriveo://local-provider?v=1&engine=ollama&engine=llamacpp&endpoint=http%3A%2F%2F127.0.0.1%3A11434&mode=local_http&auth=none"
            )
        }
    }

    @Test func rejectsDuplicateJSONFieldBeforeFoundationDecoding() {
        #expect(throws: LocalPairingError.duplicateField) {
            try LocalPairingPayload.decode(
                #"{"v":1,"v":1,"urls":["http://127.0.0.1:11434"],"engine":"ollama","auth":"none"}"#
            )
        }
    }

    @Test func rejectsOversizedMalformedAndConflictingPayloads() {
        #expect(throws: LocalPairingError.tooLarge) {
            try LocalPairingPayload.decode(String(repeating: "a", count: 16 * 1_024 + 1))
        }
        #expect(throws: LocalPairingError.invalidEncoding) {
            try LocalPairingPayload.decode("%%%not-base64%%%")
        }
        #expect(throws: LocalPairingError.conflictingFields) {
            try LocalPairingPayload.decode(
                #"{"v":1,"urls":["http://127.0.0.1:11434"],"endpoint":"http://127.0.0.1:11434","engine":"ollama","auth":"none"}"#
            )
        }
        #expect(throws: LocalPairingError.unsupportedVersion) {
            try LocalPairingPayload.decode(
                #"{"v":2,"urls":["http://127.0.0.1:11434"],"engine":"ollama","auth":"none"}"#
            )
        }
    }

    @Test func rejectsEndpointQueryAndInvalidFingerprint() {
        #expect(throws: LocalPairingError.invalid) {
            try LocalPairingPayload.decode(
                #"{"v":1,"urls":["http://127.0.0.1:11434?tenant=one"],"engine":"ollama","auth":"none"}"#
            )
        }
        #expect(throws: LocalPairingError.invalid) {
            try LocalPairingPayload.decode(
                #"{"v":1,"urls":["https://engine.example.com"],"engine":"ollama","auth":"none","fingerprint":"sha256:abcd"}"#
            )
        }
        #expect(throws: LocalPairingError.invalid) {
            try LocalPairingPayload.decode(
                #"{"v":1,"urls":["not a URL"],"engine":"ollama","auth":"none"}"#
            )
        }
        #expect(throws: LocalPairingError.invalid) {
            try LocalPairingPayload.decode(
                "oriveo://local-provider?v=1&engine=ollama&endpoint=%&mode=local_http&auth=none"
            )
        }
    }
}
