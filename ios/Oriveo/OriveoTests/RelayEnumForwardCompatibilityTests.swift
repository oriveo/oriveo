import Foundation
import Testing
@testable import Oriveo

@Suite("Relay enum forward compatibility")
struct RelayEnumForwardCompatibilityTests {
    @Test("unknown transport and auth values degrade without dropping the config")
    func unknownEnumsDoNotBreakConfig() throws {
        let data = Data(
            #"{"transport":"future_transport","authMode":"future_auth","modelID":"model-a","transportKind":"future_wire"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(RelayRequestedConfig.self, from: data)

        #expect(decoded.transport == .auto)
        #expect(decoded.authMode == .auto)
        #expect(decoded.modelID == "model-a")
        #expect(decoded.transportKind == "future_wire")
    }

    @Test("canonical relay wire keeps transportKind")
    func canonicalTransportKindRoundTrip() throws {
        let requested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            transportKind: "openai_chat"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(requested)) as? [String: Any]
        )

        #expect(object["transportKind"] as? String == "openai_chat")
        #expect(object["transportKindOverride"] == nil)
    }
}
