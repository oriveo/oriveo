import Foundation
import Testing
@testable import Oriveo

@Suite("Skills routing", .serialized)
@MainActor
struct SkillsRoutingTests {
    @Test("Skill Routes Push Expected Destinations")
    func skillRoutesPushExpectedDestinations() {
        let appState = AppState(seedDemoData: true)
        let skillID = UUID()

        appState.openSkillsList()
        appState.openSkillEdit(skillID: skillID)

        #expect(appState.navigation.path[0] == .skillsList)
        #expect(appState.navigation.path[1] == .skillEdit(skillID))
    }

    @Test("Start Skill Without Provider Does Not Force Provider Setup")
    func startSkillWithoutProviderDoesNotForceProviderSetup() {
        let appState = AppState(
            seedDemoData: false,
            sessionUID: "skills-route-\(UUID().uuidString)"
        )
        let skill = Skill(name: "Draft Skill", systemPrompt: "Help")

        appState.openSkillsList()
        appState.startConversationWithSkill(skill)

        #expect(appState.navigation.path == [.skillsList])
    }

    @Test("Skill Reasoning Match Uses Capability Evidence")
    func skillReasoningMatchUsesCapabilityEvidence() async throws {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "openai.responses.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "openai.responses.reasoning.v1"
                )
            )
        )
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": \(runtime),
          "profiles": {"reasoning": {"reasoning-profile": {"levels": ["deep"]}}},
          "providers": {"openAI": {
            "resolveMap": {"raw-liar":"raw-liar", "evidenced":"evidenced"},
            "models": {
              "raw-liar": {
                "canonicalModelId":"raw-liar", "transport":"openai_responses",
                "capabilities":["text"], "profiles":{}
              },
              "evidenced": {
                "canonicalModelId":"evidenced", "transport":"openai_responses",
                "capabilities":["text","reasoning"],
                "capabilityControls":\(controls),
                "profiles":{"reasoning":"reasoning-profile"}
              }
            }
          }}
        }
        """, metadataETag: "skill-capability-etag")

        let rawLiar = TestFactories.makeModel(
            id: "raw-liar", capabilities: [.text, .reasoning],
            reasoningModeAvailable: true, isDefault: true
        )
        let evidenced = TestFactories.makeModel(
            id: "evidenced", capabilities: [.text],
            reasoningModeAvailable: false, isDefault: true
        )
        let first = TestFactories.makeProvider(kind: .openAI, models: [rawLiar])
        let second = TestFactories.makeProvider(kind: .openAI, models: [evidenced])
        let appState = AppState(
            seedDemoData: false,
            sessionUID: "skill-evidence-\(UUID().uuidString)"
        )
        appState.providers = [first, second]

        appState.startConversationWithSkill(Skill(
            name: "Reasoning Skill",
            systemPrompt: "Think",
            modelCapabilityHint: "reasoning"
        ))

        let created = try #require(appState.conversations.last)
        #expect(created.providerID == second.id)
        #expect(created.modelID == evidenced.id)
        await MetadataClient.shared.resetForTesting()
    }
}
