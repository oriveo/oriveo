import Foundation
import CoreFoundation

/// A lossless JSON value as it appears inside a provider recipe.
///
/// Recipes are consumed as data rather than as decoded models, so the tree has to survive a
/// round trip unchanged. `[String: Any]` cannot: it is not `Sendable` under Swift 6 strict
/// concurrency, and it silently normalises numbers. This enum keeps integers, decimals and
/// booleans distinct all the way to the wire.
public enum ProviderRecipeValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Decimal)
    case string(String)
    case array([ProviderRecipeValue])
    case object([String: ProviderRecipeValue])

    public var objectValue: [String: ProviderRecipeValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [ProviderRecipeValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .integer(let value): value
        case .number(let value): NSDecimalNumber(decimal: value)
        case .string(let value): value
        case .array(let value): value.map(\.foundationValue)
        case .object(let value): value.mapValues(\.foundationValue)
        }
    }

    public static func fromFoundation(_ value: Any) -> ProviderRecipeValue? {
        switch value {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            if Decimal(value.int64Value) == value.decimalValue { return .integer(value.int64Value) }
            return .number(value.decimalValue)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            let mapped = value.compactMap(Self.fromFoundation)
            return mapped.count == value.count ? .array(mapped) : nil
        case let value as [String: Any]:
            var mapped: [String: ProviderRecipeValue] = [:]
            for (key, child) in value {
                guard let converted = Self.fromFoundation(child) else { return nil }
                mapped[key] = converted
            }
            return .object(mapped)
        default:
            return nil
        }
    }
}

extension ProviderRecipeValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(Decimal.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([ProviderRecipeValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: ProviderRecipeValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported recipe JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct ProviderRecipeTransport: Codable, Hashable, Sendable {
    public var protocolName: String
    public var endpointClass: String
    public var requiredHeaders: [String]
    public var streaming: String

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case endpointClass, requiredHeaders, streaming
    }
}

public struct ProviderRecipeOperation: Codable, Hashable, Sendable {
    public var op: String
    public var intent: String?
    public var pointer: String?
    public var value: ProviderRecipeValue?
    public var template: String?

    public init(
        op: String,
        intent: String? = nil,
        pointer: String? = nil,
        value: ProviderRecipeValue? = nil,
        template: String? = nil
    ) {
        self.op = op
        self.intent = intent
        self.pointer = pointer
        self.value = value
        self.template = template
    }
}

public struct ProviderRecipeRoute: Codable, Hashable, Sendable {
    public var sourceProtocol: String?
    public var protocolName: String
    public var endpointClass: String
    public var path: String
    public var method: String?
    public var authMode: String?
    public var authHeader: String?
    public var headers: [String: String]?
    public var requestMapper: String

    enum CodingKeys: String, CodingKey {
        case sourceProtocol
        case protocolName = "protocol"
        case endpointClass, path, method, authMode, authHeader, headers, requestMapper
    }
}

/// One published recipe: everything needed to turn a capability the user switched on into the
/// exact request body a specific provider expects. Fields are additive - an unknown field in a
/// newer document is ignored rather than fatal - but a recipe is only ever applied whole.
public struct ProviderRecipe: Codable, Hashable, Sendable {
    public var id: String
    public var providerKind: String
    public var transport: ProviderRecipeTransport
    public var capability: String
    public var executionKind: String
    public var requestOps: [ProviderRecipeOperation]
    public var responseParserKind: String
    public var continuationKind: String
    public var continuationVariant: String?
    public var controlRefs: [String]
    public var fallbackPolicy: String
    public var sourceRefs: [String]
    public var reviewedAt: String
    public var maxToolLoops: Int?
    public var route: ProviderRecipeRoute?
    public var formula: ProviderRecipeValue?
}

public struct ProviderCapabilityControl: Codable, Hashable, Sendable {
    public var state: String
    public var recipeRef: String?
    public var customControlRefs: [String]?
    public var availableIntents: [String]?
    public var reasonCode: String?
    public var sourceRefs: [String]?
    public var reasoningFacts: ProviderRecipeValue?

    public init(
        state: String,
        recipeRef: String? = nil,
        customControlRefs: [String]? = nil,
        availableIntents: [String]? = nil,
        reasonCode: String? = nil,
        sourceRefs: [String]? = nil,
        reasoningFacts: ProviderRecipeValue? = nil
    ) {
        self.state = state
        self.recipeRef = recipeRef
        self.customControlRefs = customControlRefs
        self.availableIntents = availableIntents
        self.reasonCode = reasonCode
        self.sourceRefs = sourceRefs
        self.reasoningFacts = reasoningFacts
    }
}

public struct ProviderCapabilityRuntime: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var revision: String?
    public var generatedAt: String?
    public var recipes: [String: ProviderRecipe]
    public var controlDefinitions: [String: ProviderRecipeValue]
    public var sourceIndex: [String: ProviderRecipeValue]

    public init(
        schemaVersion: Int,
        revision: String?,
        generatedAt: String?,
        recipes: [String: ProviderRecipe],
        controlDefinitions: [String: ProviderRecipeValue],
        sourceIndex: [String: ProviderRecipeValue]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generatedAt = generatedAt
        self.recipes = recipes
        self.controlDefinitions = controlDefinitions
        self.sourceIndex = sourceIndex
    }
}

/// The capability authority frozen for a single run.
///
/// A run carries its own copy of the controls it resolved, the recipes those controls point at,
/// and the sources and control definitions they reference, so that a request compiled halfway
/// through a conversation cannot be changed underneath it by a later capability document.
/// `validated` is the only way to build one: it rejects a snapshot whose references do not all
/// resolve, and a nil result means the run has no authority and must send nothing automatically.
public struct ProviderModelRecipeSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var revision: String
    /// Capability controls are resolved for one specific model. Recording that model next to
    /// the frozen recipes is what stops an otherwise valid recipe from being replayed after the
    /// user has switched the run to a different model.
    public var canonicalModelID: String?
    public var recipes: [String: ProviderRecipe]
    public var controlDefinitions: [String: ProviderRecipeValue]
    public var sourceIndex: [String: ProviderRecipeValue]
    public var capabilityControls: [String: ProviderCapabilityControl]

    public static func validated(
        runtime: ProviderCapabilityRuntime,
        capabilityControls: [String: ProviderCapabilityControl],
        providerKind: String,
        canonicalModelID: String
    ) -> ProviderModelRecipeSnapshot? {
        let capabilityKeys: Set<String> = ["web", "reasoning", "generation"]
        let controlStates: Set<String> = [
            "auto_available", "custom_only", "unavailable", "unknown",
        ]
        let normalizedModelID = canonicalModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runtime.schemaVersion == 2,
              let revision = runtime.revision?.trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty,
              !normalizedModelID.isEmpty,
              Set(capabilityControls.keys) == capabilityKeys else { return nil }

        var recipes: [String: ProviderRecipe] = [:]
        var sourceRefs = Set<String>()
        var controlRefs = Set<String>()
        for control in capabilityControls.values {
            guard controlStates.contains(control.state) else { return nil }
            if control.state == "auto_available" {
                guard let recipeRef = control.recipeRef,
                      let recipe = runtime.recipes[recipeRef],
                      recipe.id == recipeRef,
                      recipe.providerKind == providerKind else { return nil }
                recipes[recipeRef] = recipe
                sourceRefs.formUnion(recipe.sourceRefs)
                controlRefs.formUnion(recipe.controlRefs)
            } else {
                guard control.recipeRef == nil,
                      control.reasonCode?.isEmpty == false else { return nil }
                let refs = control.sourceRefs ?? []
                let isSourceExempt =
                    (providerKind == "relay" && control.state == "custom_only"
                        && control.reasonCode == "relay_user_directory")
                guard isSourceExempt || !refs.isEmpty else { return nil }
                sourceRefs.formUnion(refs)
            }
            controlRefs.formUnion(control.customControlRefs ?? [])
        }
        guard sourceRefs.allSatisfy({ runtime.sourceIndex[$0] != nil }),
              controlRefs.allSatisfy({ runtime.controlDefinitions[$0] != nil }) else { return nil }

        return ProviderModelRecipeSnapshot(
            schemaVersion: runtime.schemaVersion,
            revision: revision,
            canonicalModelID: normalizedModelID,
            recipes: recipes,
            controlDefinitions: runtime.controlDefinitions.filter { controlRefs.contains($0.key) },
            sourceIndex: runtime.sourceIndex.filter { sourceRefs.contains($0.key) },
            capabilityControls: capabilityControls
        )
    }

    public var runtime: ProviderCapabilityRuntime {
        ProviderCapabilityRuntime(
            schemaVersion: schemaVersion,
            revision: revision,
            generatedAt: nil,
            recipes: recipes,
            controlDefinitions: controlDefinitions,
            sourceIndex: sourceIndex
        )
    }
}
