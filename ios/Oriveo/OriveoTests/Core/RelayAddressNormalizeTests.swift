import Foundation
import Testing
@testable import Oriveo

/// Reads the fixture `shared/test-fixtures/relay/address-normalize.v1.json` and builds connections from it.
/// Shared by the pure-function cases and the production refresh cases (`ProviderManagerRelaySyncTests` / `RelayKeyCatalogContractTests`).
enum RelayAddressNormalizeFixture {
    static func section(_ name: String) throws -> [[String: Any]] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/address-normalize.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                return try #require(root[name] as? [[String: Any]])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func caseItem(_ section: String, _ caseId: String) throws -> [String: Any] {
        try #require(try Self.section(section).first { $0["caseId"] as? String == caseId }, "fixture is missing \(section)/\(caseId)")
    }

    /// Connection for catalogCases: the fixture fields layered onto a single-key cloud relay connection.
    static func catalogProvider(_ caseId: String, apiKey: String = "sk-primary") throws -> (provider: Provider, catalogURL: String) {
        let item = try caseItem("catalogCases", caseId)
        let raw = try #require(item["provider"] as? [String: Any])
        let requestedRaw = try #require(raw["relayRequested"] as? [String: Any])
        let transportRaw = try #require(requestedRaw["transport"] as? String)
        let transport = try #require(RelayTransport(rawValue: transportRaw))
        var requested = RelayRequestedConfig(transport: transport, authMode: .bearer, securityMode: .remoteHTTPS)
        requested.resolvedAPIBaseURL = requestedRaw["resolvedAPIBaseURL"] as? String
        requested.resolvedAPIBaseURLs = requestedRaw["resolvedAPIBaseURLs"] as? [String: String]
        let baseURL = try #require(raw["baseURL"] as? String)
        let provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [],
            catalogModels: [],
            lastCheckedAt: Date(timeIntervalSince1970: 1),
            apiKey: apiKey,
            apiKeyPreview: "...mary",
            baseURLText: baseURL,
            relayRequested: requested
        )
        let expect = try #require(item["expect"] as? [String: Any])
        return (provider, try #require(expect["catalogURL"] as? String))
    }

    static func caseIDs(_ section: String) throws -> Set<String> {
        Set(try Self.section(section).compactMap { $0["caseId"] as? String })
    }
}

@Suite("Relay address normalization")
struct RelayAddressNormalizeTests {

    // MARK: - RD2-ADDR-PREVIEW

    private func runPreview(_ caseId: String) throws {
        let item = try RelayAddressNormalizeFixture.caseItem("previewCases", caseId)
        let input = try #require(item["input"] as? String)
        let expected = item["expect"] as? String
        #expect(RelayEndpointResolver.previewAPIRoot(input) == expected, "\(caseId)")
    }

    @Test("RD2-ADDR-PREVIEW-bare_host_gets_https_and_v1") func previewBareHost() throws { try runPreview("bare_host_gets_https_and_v1") }
    @Test("RD2-ADDR-PREVIEW-trailing_slash_is_dropped") func previewTrailingSlash() throws { try runPreview("trailing_slash_is_dropped") }
    @Test("RD2-ADDR-PREVIEW-explicit_v1_is_kept") func previewExplicitV1() throws { try runPreview("explicit_v1_is_kept") }
    @Test("RD2-ADDR-PREVIEW-pasted_chat_route_is_trimmed_to_its_root") func previewChatRoute() throws { try runPreview("pasted_chat_route_is_trimmed_to_its_root") }
    @Test("RD2-ADDR-PREVIEW-proxy_prefix_is_kept") func previewProxyPrefix() throws { try runPreview("proxy_prefix_is_kept") }
    @Test("RD2-ADDR-PREVIEW-explicit_v1beta_is_kept") func previewV1beta() throws { try runPreview("explicit_v1beta_is_kept") }
    @Test("RD2-ADDR-PREVIEW-pasted_messages_route_is_trimmed") func previewMessagesRoute() throws { try runPreview("pasted_messages_route_is_trimmed") }
    @Test("RD2-ADDR-PREVIEW-pasted_models_route_is_trimmed") func previewModelsRoute() throws { try runPreview("pasted_models_route_is_trimmed") }
    @Test("RD2-ADDR-PREVIEW-empty_input_has_no_preview") func previewEmpty() throws { try runPreview("empty_input_has_no_preview") }
    @Test("RD2-ADDR-PREVIEW-userinfo_has_no_preview") func previewUserinfo() throws { try runPreview("userinfo_has_no_preview") }
    @Test("RD2-ADDR-PREVIEW-embedded_query_has_no_preview") func previewQuery() throws { try runPreview("embedded_query_has_no_preview") }
    @Test("RD2-ADDR-PREVIEW-plain_http_remote_has_no_preview") func previewPlainHTTP() throws { try runPreview("plain_http_remote_has_no_preview") }
    @Test("RD2-ADDR-PREVIEW-existing_v4_segment_is_kept") func previewExistingV4() throws { try runPreview("existing_v4_segment_is_kept") }
    @Test("RD2-ADDR-PREVIEW-pasted_versionless_chat_route_completes_v1") func previewVersionlessChatRoute() throws { try runPreview("pasted_versionless_chat_route_completes_v1") }

    // MARK: - RD2-ADDR-CATALOG

    private func runCatalog(_ caseId: String) throws {
        let (provider, catalogURL) = try RelayAddressNormalizeFixture.catalogProvider(caseId)
        let root = try #require(RelayEndpointResolver.catalogAPIRoot(provider: provider), "\(caseId)")
        #expect(root + "/models" == catalogURL, "\(caseId)")
    }

    @Test("RD2-ADDR-CATALOG-host_only_connection_refreshes_v1_models") func catalogHostOnly() throws { try runCatalog("host_only_connection_refreshes_v1_models") }
    @Test("RD2-ADDR-CATALOG-verified_root_from_detection_wins") func catalogVerifiedRoot() throws { try runCatalog("verified_root_from_detection_wins") }
    @Test("RD2-ADDR-CATALOG-versionless_verified_root_is_not_versioned_again") func catalogVersionless() throws { try runCatalog("versionless_verified_root_is_not_versioned_again") }
    @Test("RD2-ADDR-CATALOG-per_transport_root_of_the_connection_transport_wins") func catalogPerTransport() throws { try runCatalog("per_transport_root_of_the_connection_transport_wins") }
    @Test("RD2-ADDR-CATALOG-stored_chat_route_is_trimmed_before_models") func catalogStoredChatRoute() throws { try runCatalog("stored_chat_route_is_trimmed_before_models") }
    @Test("RD2-ADDR-CATALOG-messages_connection_refreshes_its_v1_root") func catalogMessages() throws { try runCatalog("messages_connection_refreshes_its_v1_root") }
    @Test("RD2-ADDR-CATALOG-gemini_connection_refreshes_its_v1beta_root") func catalogGemini() throws { try runCatalog("gemini_connection_refreshes_its_v1beta_root") }
    @Test("RD2-ADDR-CATALOG-existing_v4_segment_is_not_versioned_again") func catalogExistingV4() throws { try runCatalog("existing_v4_segment_is_not_versioned_again") }

    @Test("RD2-ADDR every caseId in the fixture's previewCases / catalogCases has a test of the same name")
    func fixtureCasesCovered() throws {
        #expect(try RelayAddressNormalizeFixture.caseIDs("previewCases") == [
            "bare_host_gets_https_and_v1", "trailing_slash_is_dropped", "explicit_v1_is_kept",
            "pasted_chat_route_is_trimmed_to_its_root", "proxy_prefix_is_kept", "explicit_v1beta_is_kept",
            "pasted_messages_route_is_trimmed", "pasted_models_route_is_trimmed", "empty_input_has_no_preview",
            "userinfo_has_no_preview", "embedded_query_has_no_preview", "plain_http_remote_has_no_preview",
            "existing_v4_segment_is_kept", "pasted_versionless_chat_route_completes_v1",
        ])
        #expect(try RelayAddressNormalizeFixture.caseIDs("catalogCases") == [
            "host_only_connection_refreshes_v1_models", "verified_root_from_detection_wins",
            "versionless_verified_root_is_not_versioned_again", "per_transport_root_of_the_connection_transport_wins",
            "stored_chat_route_is_trimmed_before_models", "messages_connection_refreshes_its_v1_root",
            "gemini_connection_refreshes_its_v1beta_root", "existing_v4_segment_is_not_versioned_again",
        ])
    }

    /// Local-engine catalog sync goes through the injected root address (`injectedAPIRoot`); when a probed root exists, catalogAPIRoot has the same value.
    @Test("RD2-ADDR-CATALOG the local engine's probed root address equals the injected root address")
    func localEngineMatchesInjectedRoot() {
        var requested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .none, securityMode: .localHTTP)
        requested.resolvedAPIBaseURL = "http://192.168.1.20:11434/v1"
        let provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [],
            catalogModels: [],
            apiKey: "",
            apiKeyPreview: "",
            baseURLText: "http://192.168.1.20:11434",
            relayRequested: requested
        )
        #expect(RelayEndpointResolver.catalogAPIRoot(provider: provider) == RelayEndpointResolver.injectedAPIRoot(requested))
    }
}
