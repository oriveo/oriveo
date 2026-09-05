import Foundation
import Testing
@testable import Oriveo

/// `usesLegacyMapping: false`;`ProfileParamsResolver.reasoningMergeParams` /
enum CapabilityRuntimeFixtures {

    static let defaultRevision = "runtime-fixture"


    static func runtimeEnvelope(
        revision: String = defaultRevision,
        generatedAt: String = "2026-08-15T00:00:00Z"
    ) throws -> [String: Any] {
        var envelope = try mergedRegistry()
        envelope["revision"] = revision
        envelope["generatedAt"] = generatedAt
        return envelope
    }

    static func runtimeEnvelopeJSON(
        revision: String = defaultRevision,
        generatedAt: String = "2026-08-15T00:00:00Z"
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: try runtimeEnvelope(revision: revision, generatedAt: generatedAt),
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }


    struct ControlSpec {
        let capability: String
        let recipeRef: String?
        let state: String
        let availableIntents: [String]?
        let reasonCode: String?

        init(
            capability: String,
            recipeRef: String? = nil,
            state: String = "auto_available",
            availableIntents: [String]? = nil,
            reasonCode: String? = nil
        ) {
            self.capability = capability
            self.recipeRef = recipeRef
            self.state = state
            self.availableIntents = availableIntents
            self.reasonCode = reasonCode
        }
    }

    static let reasoningIntentLadder = ["off", "low", "balanced", "deep", "max"]

    static func reasoningIntents(ofRecipe recipeRef: String) throws -> [String] {
        let recipe = try #require(try mergedRegistry()["recipes"] as? [String: Any])
        let target = try #require(recipe[recipeRef] as? [String: Any])
        let ops = try #require(target["requestOps"] as? [[String: Any]])
        let declared = Set(ops.compactMap { $0["intent"] as? String })
        return reasoningIntentLadder.filter { declared.contains($0) }
    }

    static func controls(_ specs: [ControlSpec]) -> [String: Any] {
        var result: [String: Any] = [:]
        for spec in specs {
            var entry: [String: Any] = ["state": spec.state]
            if let recipeRef = spec.recipeRef { entry["recipeRef"] = recipeRef }
            if let intents = spec.availableIntents { entry["availableIntents"] = intents }
            if let reasonCode = spec.reasonCode { entry["reasonCode"] = reasonCode }
            result[spec.capability] = entry
        }
        return result
    }

    static func controls(_ specs: ControlSpec...) -> [String: Any] {
        controls(specs)
    }

    static func controlsJSON(_ specs: ControlSpec...) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: controls(specs), options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }


    static func recipeValue(
        recipeRef: String,
        intent: String? = nil,
        pointer: String
    ) throws -> Any {
        let recipes = try #require(try mergedRegistry()["recipes"] as? [String: Any])
        let recipe = try #require(recipes[recipeRef] as? [String: Any])
        let ops = try #require(recipe["requestOps"] as? [[String: Any]])
        let match = try #require(ops.first {
            ($0["pointer"] as? String) == pointer && ($0["intent"] as? String) == intent
        })
        return try #require(match["value"])
    }


    private nonisolated(unsafe) static var cachedRegistry: [String: Any]?

    private static func mergedRegistry() throws -> [String: Any] {
        if let cachedRegistry { return cachedRegistry }
        var registry = try loadJSONObject([
            "shared", "capabilityrecipe",
            "capability_runtime.v1.json",
        ])
        let definitions = try loadJSONObject([
            "shared", "capabilityrecipe",
            "capability_result_definitions.v1.json",
        ])
        let bindings = try #require(definitions["recipeBindings"] as? [String: [String: Any]])
        let evidence = try #require(definitions["responseEvidenceDefinitions"] as? [String: [String: Any]])
        let locatorRules = (definitions["errorRecoveryDefinitions"] as? [String: Any])?["locatorRules"]
            as? [String: Any] ?? [:]

        var recipes = try #require(registry["recipes"] as? [String: Any])
        for (recipeID, raw) in recipes {
            guard var recipe = raw as? [String: Any],
                  let binding = bindings[recipeID],
                  let evidenceRef = binding["responseEvidenceRef"] as? String,
                  let recoveryRef = binding["errorRecoveryRef"] as? String else { continue }
            recipe["responseEvidenceRef"] = evidenceRef
            recipe["errorRecoveryRef"] = recoveryRef
            recipes[recipeID] = recipe
        }
        var recoveryDefinitions: [String: Any] = [:]
        for (ref, definition) in evidence {
            recoveryDefinitions[ref] = [
                "capability": definition["capability"] ?? "",
                "protocol": definition["protocol"] ?? "",
                "responseParserKind": definition["responseParserKind"] ?? "",
                "locatorRules": locatorRules[ref] ?? [],
            ]
        }
        registry["recipes"] = recipes
        registry["responseEvidenceDefinitions"] = evidence
        registry["errorRecoveryDefinitions"] = recoveryDefinitions
        registry.removeValue(forKey: "$comment")
        cachedRegistry = registry
        return registry
    }

    private static func loadJSONObject(_ suffix: [String]) throws -> [String: Any] {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let file = suffix.reduce(folder) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: file.path) {
                return try #require(
                    JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                )
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
