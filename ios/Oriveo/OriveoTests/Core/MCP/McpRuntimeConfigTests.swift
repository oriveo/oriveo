import Foundation
import Testing
@testable import Oriveo

/// Parsing of the `mcpRuntimeConfig` section of the model catalog: missing fields use the fallback, out-of-range values are clamped.
@Suite("MCP runtime config parsing")
struct McpRuntimeConfigTests {

    private func parse(_ json: String) throws -> McpRuntimeConfig {
        McpRuntimeConfig(json: try JSONValue(parsing: json))
    }

    @Test("fallback values are the documented defaults; a missing section or a non-object returns the fallback")
    func fallbackMatchesContract() throws {
        let fallback = McpRuntimeConfig.fallback
        #expect(fallback.version == 1)
        #expect(fallback.enabled)
        #expect(fallback.maxServers == 20)
        #expect(fallback.maxToolsPerRequest == 40)
        #expect(fallback.maxToolDefinitionBytes == 16_384)
        #expect(fallback.maxResultChars == 24_000)
        #expect(fallback.callTimeoutSeconds == 60)
        #expect(fallback.maxSteps == 6)

        #expect(McpRuntimeConfig(json: nil) == fallback)
        #expect(try parse("null") == fallback)
        #expect(try parse("[1,2,3]") == fallback)
        #expect(try parse("\"enabled\"") == fallback)
        #expect(try parse("{}") == fallback)
    }

    @Test("valid values are used as is; fields that are absent keep the fallback")
    func validValuesAreHonored() throws {
        let config = try parse("""
            {"version":3,"enabled":false,"maxServers":5,"maxToolsPerRequest":12,"maxToolDefinitionBytes":8192,
             "maxResultChars":5000,"callTimeoutSeconds":30.5,"maxSteps":4,"futureField":"ignored"}
            """)
        #expect(config == McpRuntimeConfig(
            version: 3, enabled: false, maxServers: 5, maxToolsPerRequest: 12, maxToolDefinitionBytes: 8192,
            maxResultChars: 5000, callTimeoutSeconds: 30.5, maxSteps: 4
        ))

        let partial = try parse(#"{"maxServers":7}"#)
        #expect(partial.maxServers == 7)
        #expect(partial.maxToolsPerRequest == 40)
        #expect(partial.enabled)
    }

    @Test("zero and negative values clamp to the lower bound, so there is never a zero server limit or an instant call timeout")
    func zeroAndNegativeClampToLowerBound() throws {
        for value in ["0", "-1", "-999999", "-1e30"] {
            let config = try parse("""
                {"version":\(value),"maxServers":\(value),"maxToolsPerRequest":\(value),"maxToolDefinitionBytes":\(value),
                 "maxResultChars":\(value),"callTimeoutSeconds":\(value),"maxSteps":\(value)}
                """)
            #expect(config.version == 1, "\(value)")
            #expect(config.maxServers == 1, "\(value)")
            #expect(config.maxToolsPerRequest == 1, "\(value)")
            #expect(config.maxToolDefinitionBytes == 1_024, "\(value)")
            #expect(config.maxResultChars == 1_000, "\(value)")
            #expect(config.callTimeoutSeconds == 5, "\(value)")
            #expect(config.maxSteps == 1, "\(value)")
            #expect(config.effectiveMaxSteps == 1)
        }
    }

    @Test("huge values clamp to the hard ceiling and never crash on integer conversion")
    func hugeValuesClampToUpperBound() throws {
        for value in ["1000000000", "9223372036854775807", "1e30", "1.7e308"] {
            let config = try parse("""
                {"maxServers":\(value),"maxToolsPerRequest":\(value),"maxToolDefinitionBytes":\(value),
                 "maxResultChars":\(value),"callTimeoutSeconds":\(value),"maxSteps":\(value)}
                """)
            #expect(config.maxServers == 100, "\(value)")
            #expect(config.maxToolsPerRequest == 128, "\(value)")
            #expect(config.maxToolDefinitionBytes == 262_144, "\(value)")
            #expect(config.maxResultChars == 200_000, "\(value)")
            #expect(config.callTimeoutSeconds == 600, "\(value)")
            #expect(config.maxSteps == 8, "\(value)")
            #expect(config.effectiveMaxSteps == 8)
        }
    }

    @Test("version is not clamped: only integers >= 1 are accepted, anything else keeps the fallback")
    func versionIsNotClamped() throws {
        #expect(try parse(#"{"version":7}"#).version == 7)
        for value in ["0", "-3", "1e30", "2.5", "\"2\""] {
            #expect(try parse("{\"version\":\(value)}").version == 1, "\(value)")
        }
    }

    @Test("boundary values themselves are accepted; fractions round down")
    func boundsAreInclusive() throws {
        let low = try parse(#"{"maxServers":1,"maxToolsPerRequest":1,"maxToolDefinitionBytes":1024,"maxResultChars":1000,"callTimeoutSeconds":5,"maxSteps":1}"#)
        #expect(low.maxServers == 1 && low.maxToolsPerRequest == 1 && low.maxToolDefinitionBytes == 1_024)
        #expect(low.maxResultChars == 1_000 && low.callTimeoutSeconds == 5 && low.maxSteps == 1)
        let high = try parse(#"{"maxServers":100,"maxToolsPerRequest":128,"maxToolDefinitionBytes":262144,"maxResultChars":200000,"callTimeoutSeconds":600,"maxSteps":8}"#)
        #expect(high.maxServers == 100 && high.maxToolsPerRequest == 128 && high.maxToolDefinitionBytes == 262_144)
        #expect(high.maxResultChars == 200_000 && high.callTimeoutSeconds == 600 && high.maxSteps == 8)
        #expect(try parse(#"{"maxServers":2.9}"#).maxServers == 2)
    }

    @Test("a field of the wrong type keeps its fallback without affecting other fields")
    func wrongTypesKeepFallback() throws {
        let config = try parse("""
            {"version":"2","enabled":"yes","maxServers":"30","maxToolsPerRequest":null,"maxToolDefinitionBytes":[1],
             "maxResultChars":{"n":1},"callTimeoutSeconds":"60","maxSteps":true,"extra":5}
            """)
        #expect(config == McpRuntimeConfig.fallback)
        let mixed = try parse(#"{"maxServers":"30","maxSteps":3}"#)
        #expect(mixed.maxServers == 20)
        #expect(mixed.maxSteps == 3)
    }

    @Test("the step limit is additionally capped at 8")
    func effectiveMaxStepsIsCappedAtEight() {
        #expect(McpRuntimeConfig(maxSteps: 6).effectiveMaxSteps == 6)
        #expect(McpRuntimeConfig(maxSteps: 12).effectiveMaxSteps == 8)
    }
}

// MARK: - Reading from the model catalog snapshot (MetadataClient wiring)
//
// Lives on the metadata fixture suite to share its `.serialized` trait: both replace the same process-wide snapshot.
extension MetadataFixtureTests {

    /// Wraps a `mcpRuntimeConfig` fragment in a minimal model catalog, decodes it for real, then reads it back
    /// through the production accessor.
    private func loadMcpRuntimeConfig(_ fragment: String?) async throws -> McpRuntimeConfig {
        let client = MetadataClient()
        let field = fragment.map { ",\n  \"mcpRuntimeConfig\": \($0)" } ?? ""
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-4o",
              "resolveMap": { "gpt-4o": "gpt-4o" },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o",
                  "contextLength": 128000,
                  "capabilities": ["text"]
                }
              }
            }
          }\(field)
        }
        """)
        // The models must still be there: a malformed section here must not fail decoding of the whole catalog.
        #expect(await client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI) != nil)
        let config = MetadataClient.shared.syncMcpRuntimeConfig()
        await client.resetForTesting()
        return config
    }

    @Test("mcpRuntimeConfig: values from the model catalog replace the fallback; enabled=false is read as is; out-of-range values clamp to the bounds")
    func mcpRuntimeConfigComesFromMetadata() async throws {
        let custom = try await loadMcpRuntimeConfig("""
        {"version":2,"enabled":false,"maxServers":5,"maxToolsPerRequest":12,"maxToolDefinitionBytes":8192,
         "maxResultChars":9000,"callTimeoutSeconds":30,"maxSteps":99}
        """)
        #expect(custom == McpRuntimeConfig(
            version: 2, enabled: false, maxServers: 5, maxToolsPerRequest: 12, maxToolDefinitionBytes: 8192,
            maxResultChars: 9000, callTimeoutSeconds: 30, maxSteps: 8
        ))
        // A catalog that spells out every default.
        let defaults = try await loadMcpRuntimeConfig("""
        {"version":1,"enabled":true,"maxServers":20,"maxToolsPerRequest":40,"maxToolDefinitionBytes":16384,
         "maxResultChars":24000,"callTimeoutSeconds":60,"maxSteps":6}
        """)
        #expect(defaults == .fallback)
    }

    @Test("mcpRuntimeConfig: a missing section or a wrong shape yields the fallback; the models keep resolving and the feature is not disabled")
    func mcpRuntimeConfigFallsBackWithoutBreakingCatalog() async throws {
        #expect(try await loadMcpRuntimeConfig(nil) == .fallback)
        #expect(try await loadMcpRuntimeConfig("\"off\"") == .fallback)
        #expect(try await loadMcpRuntimeConfig("[1,2]") == .fallback)
        #expect(try await loadMcpRuntimeConfig("{\"enabled\":\"no\",\"maxServers\":null}") == .fallback)
        // Still the fallback after the snapshot is cleared.
        #expect(MetadataClient.shared.syncMcpRuntimeConfig() == .fallback)
    }
}
