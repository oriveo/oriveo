import Foundation
import Testing
@testable import Oriveo

// Shared fixture `shared/test-fixtures/capability/display-facts.v1.json#managedWebBadgeCases`:
// the web badge and the picker's "can browse" filter hold only when the web control is auto_available;
// managed_only / custom_only / unknown / unavailable never light the badge and never match the filter.
// Each case sets up that form's source per the fixture form and webControlState, and takes the conclusion
// through production `AIModel.visibleMetadataCapabilities` (badge) and `ModelPickerCapabilityFilter.matches` (filter).
@Suite("display-facts.v1 managedWebBadgeCases (iOS)", .serialized, .sharedProcessState)
@MainActor
struct DisplayFactsManagedWebBadgeContractTests {
    private static let fixtureName = "display-facts.v1.json"
    private static let metadataETag = "display-facts-managed-web-badge"
    private static let coveredIDs: Set<String> = [
        "official_auto_badge",
        "official_custom_only_no_badge",
    ]

    private struct Case {
        let id: String
        let form: String
        let webControlState: String
        let badge: Bool
        let pickerFilterMatches: Bool
    }

    private static func cases() throws -> [Case] {
        let fixture = try CapabilitySharedFixture.load(fixtureName)
        let raw = try #require(fixture["managedWebBadgeCases"] as? [[String: Any]])
        return try raw.map { item in
            let expect = try #require(item["expect"] as? [String: Any])
            return Case(
                id: try #require(item["id"] as? String),
                form: try #require(item["form"] as? String),
                webControlState: try #require(item["webControlState"] as? String),
                badge: try #require(expect["badge"] as? Bool),
                pickerFilterMatches: try #require(expect["pickerFilterMatches"] as? Bool)
            )
        }
    }

    private static func badgeCase(_ id: String) throws -> Case {
        try #require(try cases().first { $0.id == id }, "The fixture has no \(id)")
    }

    /// Official catalog: an auto_available control with a web recipe (together with the profile, so the badge has
    /// evidence to project), or another state from the fixture (without a recipe).
    private static func installOfficialCatalog(modelID: String, webState: String) async throws {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let isAuto = webState == RequestControlAvailability.autoAvailable.rawValue
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "web", recipeRef: isAuto ? "openai.responses.web.v1" : nil, state: webState)
        )
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": \(runtime),
          "profiles": {
            "webSearch": {"web-profile": {"mergeParams": {"tools": [{"type":"web_search"}]}}}
          },
          "providers": {"openAI": {
            "resolveMap": {"\(modelID)": "\(modelID)"},
            "models": {"\(modelID)": {
              "canonicalModelId": "\(modelID)", "transport": "openai_responses",
              "capabilities": ["text","web"], "profiles": {"webSearch":"web-profile"},
              "capabilityControls": \(controls)
            }}
          }}
        }
        """, metadataETag: metadataETag)
    }

    private static func subject(_ item: Case) async throws -> (provider: Provider, model: AIModel) {
        let modelID = "badge-\(item.id)"
        switch item.form {
        case "official":
            try await installOfficialCatalog(modelID: modelID, webState: item.webControlState)
            let model = TestFactories.makeModel(id: modelID, capabilities: [.text, .web])
            let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
            return (provider, model)
        default:
            Issue.record("\(item.id): unknown form \(item.form)")
            throw CancellationError()
        }
    }

    private static func check(_ id: String) async throws {
        let item = try badgeCase(id)
        let (provider, model) = try await subject(item)
        let state = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "web").state
        #expect(state.rawValue == item.webControlState, "\(id) precondition: web control state")
        let badge = ModelPickerCapabilityFilter.visibleCapabilities(model: model, provider: provider).contains(.web)
        #expect(badge == item.badge, "\(id) badge")
        let matches = ModelPickerCapabilityFilter.matches(model: model, provider: provider, capability: .web)
        #expect(matches == item.pickerFilterMatches, "\(id) pickerFilterMatches")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("The fixture's managedWebBadgeCases id set == the list covered by this file")
    func coversEveryFixtureCase() throws {
        #expect(Set(try Self.cases().map(\.id)) == Self.coveredIDs)
    }

    @Test func DISPLAY_FACTS_official_auto_badge() async throws {
        try await Self.check("official_auto_badge")
    }

    @Test func DISPLAY_FACTS_official_custom_only_no_badge() async throws {
        try await Self.check("official_custom_only_no_badge")
    }
}
