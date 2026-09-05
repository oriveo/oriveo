//  Loads the public model catalog (capability recipes, pricing, transport).

import Foundation
import GRDB
import os

actor MetadataClient {
    static let shared = MetadataClient()

    typealias ErrorReporter = @Sendable (_ error: Error, _ context: [String: String]) -> Void

    // MARK: - Types

    struct ModelPricing: Codable, Sendable {
        let promptPerMToken: Double?
        let completionPerMToken: Double?
        let cachedInputPerMToken: Double?
        let costPerUnit: Double?
        let costInputBatches: Double?
        let costOutputBatches: Double?
        let costInputPriority: Double?
        let costOutputPriority: Double?
        let cacheReadInputPerMToken: Double?
        let cacheCreationInputPerMToken: Double?
        let cacheWrite5mPerMToken: Double?
        let cacheWrite1hPerMToken: Double?

        var promptPerToken: Double? { promptPerMToken.map { $0 / 1_000_000 } }
        var completionPerToken: Double? { completionPerMToken.map { $0 / 1_000_000 } }
    }

    struct ModelSourceSummary: Codable, Sendable {
        let sourceKind: String
        let sourceName: String
        let fetchedAt: String
    }

    struct ModelProfileRefs: Codable, Sendable {
        let reasoning: String?
        let webSearch: String?
        let imageGen: String?
        let generation: GenerationProfileRef?
    }

    struct ModelUIHints: Codable, Sendable {
        let groupKey: String?
        let groupName: String?
        let rank: Int?
        let recommended: Bool?
        let badgeOrder: [String]?
    }

    @propertyWrapper
    struct CapabilityEvidenceRawField: Codable, Sendable {
        var wrappedValue: JSONValue?
        let isPresent: Bool
        var projectedValue: CapabilityEvidenceRawField { self }

        init(wrappedValue: JSONValue?) {
            self.wrappedValue = wrappedValue
            self.isPresent = false
        }

        init(presentValue: JSONValue) {
            self.wrappedValue = presentValue
            self.isPresent = true
        }

        init(from decoder: Decoder) throws {
            self.wrappedValue = try JSONValue(from: decoder)
            self.isPresent = true
        }

        func encode(to encoder: Encoder) throws {
            try (wrappedValue ?? .null).encode(to: encoder)
        }
    }

    struct LibraryRuntimeConfig: Codable, Sendable {
        let version: Int
        let toolDescriptions: [String: String]
        let maxSteps: Int
        let toolTimeoutMs: Int
        let maxEmptyHits: Int
        let maxSelfCorrections: Int
        let tokenBudget: Int
        let estimatedTokensPerStep: Int
        let highCostConfirmationUSD: Double
        let weakModelDenylist: [String]
        let sensitiveGateEnabled: Bool
        let enabled: Bool?
        let availableProviders: [String]?
        let directMaxDocuments: Int?
        let directContextMaxChars: Int?
        let serverResearchEnabled: Bool?
        let serverResearchProviderDenylist: [String]?
        let serverResearchMaxDocuments: Int?

        static let fallback = LibraryRuntimeConfig(version: 6, toolDescriptions: [:], maxSteps: 6, toolTimeoutMs: 15_000, maxEmptyHits: 2, maxSelfCorrections: 3, tokenBudget: 0, estimatedTokensPerStep: 2_000, highCostConfirmationUSD: 0.25, weakModelDenylist: [], sensitiveGateEnabled: true, enabled: nil, availableProviders: nil, directMaxDocuments: nil, directContextMaxChars: nil, serverResearchEnabled: nil, serverResearchProviderDenylist: nil, serverResearchMaxDocuments: nil)
    }

    struct StreamShape: Codable, Sendable, Equatable {
        let reasoningDeltaPath: String?
        let citationsBlockType: String?
        let citationsArrayPath: String?
        let citationUrlField: String?
        let citationTitleField: String?
        let citationSnippetField: String?
        let imageDataPath: String?
    }

    struct ReasoningProfileDefinition: Codable, Sendable {
        let transport: String?
        let fallbackProfile: String?
        let levels: [String]?
        let defaultLevel: String?
        let params: [String: JSONValue]?
        let streamShape: StreamShape?
    }

    struct WebSearchProfileDefinition: Codable, Sendable {
        let mergeParams: JSONValue?
        let maxToolLoops: Int?
        let streamShape: StreamShape?
    }

    struct ImageGenProfileDefinition: Codable, Sendable {
        let route: String?
        let mergeParams: JSONValue?
        let requestDefaults: JSONValue?
        let streamShape: StreamShape?
    }

    struct ProviderTransportDefinition: Codable, Sendable, Equatable {
        let baseUrl: String?
        let endpoints: TransportEndpoints?
    }

    struct TransportEndpoints: Codable, Sendable, Equatable {
        let chat: String?
        let responses: String?
        let images: String?
        let embeddings: String?
        let files: String?
    }

    struct ModelMetadataEntry: Codable, Sendable {
        let canonicalModelId: String?
        let modelRef: String?
        let aliases: [String]?
        let displayName: String?
        let contextLength: Int?
        let maxOutputTokens: Int?
        let supportsTemperature: Bool?
        let billingSku: String?
        let pricingUnit: String?
        let sourceSummary: ModelSourceSummary?
        let pricing: ModelPricing?
        let pricingStatus: String?
        let capabilities: [String]?
        let supportsPdfInput: Bool?
        let supportsServiceTier: Bool?
        let profiles: ModelProfileRefs?
        let uiHints: ModelUIHints?
        let vendorKey: String?
        let vendorName: String?
        let toolCall: Bool?
        let libraryAgentic: Bool?
        let transport: String?
        let capabilityControls: [String: CapabilityControl]?
        @CapabilityEvidenceRawField var capabilityEvidenceView: JSONValue?
    }

    struct CapabilityControl: Codable, Sendable {
        let state: String
        let recipeRef: String?
        let reasonCode: String?
        let sourceRefs: [String]?
        let availableIntents: [String]?
        let customControlRefs: [String]?
    }

    struct CapabilityRecipeOperation: Codable, Sendable {
        let op: String
        let intent: String?
        let pointer: String?
        let value: JSONValue?
        /// Generation recipes authorize an existing typed profile by template; they deliberately
        /// carry no raw body value and therefore cannot be handled as a generic `set` operation.
        let template: String?
    }

    struct CapabilityRecipeTransport: Codable, Sendable {
        let protocolName: String

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
        }
    }

    struct CapabilityRecipe: Codable, Sendable {
        let id: String
        let providerKind: String
        let transport: CapabilityRecipeTransport
        let capability: String
        let executionKind: String
        let requestOps: [CapabilityRecipeOperation]
        let route: CapabilityRecipeRoute?
        let responseParserKind: String?
        let continuationKind: String?
        let continuationVariant: String?
        let maxToolLoops: Int?
        let formula: CapabilityRecipeFormula?
        let fallbackPolicy: String?
        let sourceRefs: [String]?
        /// binds an execution result to the exact catalog-reviewed parser definition.
        /// A missing ref is fail-safe: the request may still chat, but can never claim observed.
        let responseEvidenceRef: String?
        /// Kept separate on the wire so a future recovery rule cannot be inferred from text.
        let errorRecoveryRef: String?
    }

    struct CapabilityRecipeRoute: Codable, Sendable {
        let sourceProtocol: String?
        let protocolName: String
        let endpointClass: String
        let path: String
        let method: String?
        let authMode: String?
        let authHeader: String?
        let headers: [String: String]?
        let requestMapper: String

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
            case sourceProtocol, endpointClass, path, method, authMode, authHeader, headers, requestMapper
        }
    }

    struct CapabilityRecipeFormula: Codable, Sendable {
        let uri: String
        let toolsPath: String
        let fibersPath: String
        let argumentsMode: String
        let resultPaths: [String]
    }

    struct CapabilityRuntimeEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let revision: String
        let generatedAt: String
        let recipes: [String: CapabilityRecipe]
        let controlDefinitions: [String: JSONValue]
        let sourceIndex: [String: JSONValue]
        let responseEvidenceDefinitions: [String: CapabilityResponseEvidenceDefinition]?
        let errorRecoveryDefinitions: [String: CapabilityErrorRecoveryDefinition]?
    }

    struct CapabilityResponseEvidenceDefinition: Codable, Sendable {
        struct Signal: Codable, Sendable {
            let kind: String
            let producerEvent: String
            let pointer: String
            let nonEmpty: Bool
        }

        let capability: String
        let protocolName: String
        let responseParserKind: String
        let signals: [Signal]

        enum CodingKeys: String, CodingKey {
            case capability, protocolName = "protocol", responseParserKind, signals
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            capability = try container.decode(String.self, forKey: .capability)
            protocolName = try container.decode(String.self, forKey: .protocolName)
            responseParserKind = try container.decode(String.self, forKey: .responseParserKind)
            signals = try container.decodeIfPresent([Signal].self, forKey: .signals) ?? []
        }
    }

    /// A recovery definition is deliberately declarative. only accepts a reviewed structured
    /// locator; an absent/empty list is not a weaker heuristic, it is an explicit no-retry rule.
    struct CapabilityErrorRecoveryDefinition: Codable, Sendable {
        struct LocatorRule: Codable, Sendable {
            let status: Int
            let owner: String
            let pointers: [String]
            let errorFields: [String: String]
        }

        let capability: String
        let protocolName: String
        let responseParserKind: String
        let locatorRules: [LocatorRule]

        enum CodingKeys: String, CodingKey {
            case capability, protocolName = "protocol", responseParserKind, locatorRules
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            capability = try container.decode(String.self, forKey: .capability)
            protocolName = try container.decode(String.self, forKey: .protocolName)
            responseParserKind = try container.decode(String.self, forKey: .responseParserKind)
            locatorRules = try container.decodeIfPresent([LocatorRule].self, forKey: .locatorRules) ?? []
        }
    }

    struct CapabilityRecipeRuntimeSnapshot: Sendable {
        let runtime: CapabilityRuntimeEnvelope?
        let controls: [String: CapabilityControl]?
    }

    struct CapabilityEvidenceViewProjection: Sendable, Equatable {
        let namespacePresent: Bool
        let candidates: [CapabilityEvidenceFacade.Candidate]
        let ownedKeys: Set<String>
        let malformed: Bool

        static let absent = CapabilityEvidenceViewProjection(
            namespacePresent: false, candidates: [], ownedKeys: [], malformed: false
        )
    }

    struct ResolvedModelMetadata: Sendable {
        let canonicalModelId: String
        let modelRef: String?
        let displayName: String?
        let contextLength: Int?
        let maxOutputTokens: Int?
        let supportsTemperature: Bool?
        let billingSku: String?
        let pricingUnit: String
        let sourceSummary: ModelSourceSummary?
        let pricingStatus: String
        let capabilities: [ModelCapability]
        let promptPerToken: Double?
        let completionPerToken: Double?
        let costPerUnit: Double?
        let costInputBatches: Double?
        let costOutputBatches: Double?
        let costInputPriority: Double?
        let costOutputPriority: Double?
        let cacheReadInputPerMToken: Double?
        let cacheCreationInputPerMToken: Double?
        let cacheWrite5mPerMToken: Double?
        let cacheWrite1hPerMToken: Double?
        let profiles: (reasoning: String?, webSearch: String?, imageGen: String?)
        let generationProfile: GenerationProfileRef?
        let supportsPdfInput: Bool
        let supportsServiceTier: Bool
        let uiHints: (groupKey: String?, groupName: String?, rank: Int?, recommended: Bool, badgeOrder: [ModelCapability]?)
        let isDefault: Bool
        let vendorKey: String?
        let vendorName: String?
        let toolCall: Bool?
        let libraryAgentic: Bool?
        let capabilityContractVersion: Int?
        let transport: String?
        var capabilityEvidenceCandidates: [CapabilityEvidenceFacade.Candidate] = []
        var capabilityEvidenceOwnedKeys: Set<String> = []
        var capabilityEvidenceViewPresent: Bool = false
        var capabilityEvidenceViewMalformed: Bool = false
    }

    struct AttachmentSupport: Codable, Sendable, Equatable {
        let image: Bool
        let video: Bool
        let nativeFile: Bool
        let textFileInline: Bool

        init(image: Bool, video: Bool = false, nativeFile: Bool, textFileInline: Bool) {
            self.image = image
            self.video = video
            self.nativeFile = nativeFile
            self.textFileInline = textFileInline
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            image = try container.decodeIfPresent(Bool.self, forKey: .image) ?? false
            video = try container.decodeIfPresent(Bool.self, forKey: .video) ?? false
            nativeFile = try container.decodeIfPresent(Bool.self, forKey: .nativeFile) ?? false
            textFileInline = try container.decodeIfPresent(Bool.self, forKey: .textFileInline) ?? false
        }
    }

    struct ProviderRegionOption: Codable, Sendable, Equatable {
        let id: String
        let label: String
        let baseURL: String
        var privacyPolicyURL: String? = nil
        var apiKeyHelpURL: String? = nil
    }

    struct PublicProviderConfig: Codable, Sendable, Equatable {
        let kind: String
        let displayName: String
        let shortName: String?
        let selectionLabel: String?
        let autoFillNote: String?
        let defaultBaseURL: String
        let apiKeyPlaceholder: String?
        let apiKeyHelpURL: String?
        let apiProtocol: String?
        let category: String?
        let supportsAutoSync: Bool?
        let attachmentSupport: AttachmentSupport?
        let regionOptions: [ProviderRegionOption]?
        let sortOrder: Int?
        var protocolFeatures: RawProtocolFeatures? = nil
    }

    struct RawProtocolFeatures: Codable, Sendable, Equatable {
        let subscriptionAuth: RawGrokSubscriptionAuth?
    }

    struct RawGrokSubscriptionAuth: Codable, Sendable, Equatable {
        let enabled: Bool?
        let flow: String?
        let clientId: String?
        let scopes: String?
        let deviceAuthorizationEndpoint: String?
        let deviceTokenEndpoint: String?
        let tokenEndpoint: String?
        let revocationEndpoint: String?
        let verificationURL: String?
        let redirectURI: String?
        let trustedAuthHosts: [String]?
        let trustedVerificationHosts: [String]?
        let resourceBaseURL: String?
        let requiredHeaders: [String: String]?
        let modelsPath: String?
        let chatPath: String?
        let responsesPath: String?
        let apiBackend: String?
        let pollIntervalSeconds: Int?
        let pollTimeoutSeconds: Int?
        let minAppVersion: [String: String]?
        let disabledNotice: String?
    }

    // MARK: - Relay Runtime Config

    struct RelayTransportEnvelope: Codable, Sendable {
        let image: Bool
        let nativeFile: Bool
        let textFileInline: Bool
        let webSearch: Bool
        let imageGeneration: Bool
        let reasoning: Bool
    }

    fileprivate struct RawRelayTransportEnvelope: Codable, Sendable {
        let image: Bool?
        let nativeFile: Bool?
        let textFileInline: Bool?
        let webSearch: Bool?
        let imageGeneration: Bool?
        let reasoning: Bool?
    }

    struct RelayTransportRule: Sendable {
        let providerPriority: String?
        let defaultAuthMode: String
        let defaultVersion: String
        let acceptedVersions: [String]
        let headerProfile: String
        let codexIdentityDefault: Bool
        let webSearchToolName: String
        let imageRoute: String
        let forceStreamForImageGeneration: Bool
    }

    fileprivate struct RawRelayTransportRule: Codable, Sendable {
        let providerPriority: String?
        let defaultAuthMode: String?
        let defaultVersion: String?
        let acceptedVersions: [String]?
        let headerProfile: String?
        let codexIdentityDefault: Bool?
        let webSearchToolName: String?
        let imageRoute: String?
        let forceStreamForImageGeneration: Bool?
    }

    struct RelayVerificationPolicy: Codable, Sendable {
        let hardFailedExpiryDays: Int
        let softFailedRetryAfterSeconds: Int
        let verifiedCacheDays: Int
    }

    struct RelayFeatureGatingPolicy: Codable, Sendable {
        let showActualModelIdHint: Bool
        let showSoftFailHint: Bool
    }

    struct ReviewPromptPolicy: Codable, Equatable, Sendable {
        var enabled: Bool = false
        var policyVersion: Int = 0
    }

    fileprivate struct RawRuntimeConfig: Codable, Sendable {
        let featureFlags: [String: Bool]?
        let selfHealPatterns: [SelfHealPatternDefinition]?
        let reviewPrompt: ReviewPromptPolicy?

        private enum CodingKeys: String, CodingKey {
            case featureFlags
            case selfHealPatterns
            case reviewPrompt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            featureFlags = try? container.decode([String: Bool].self, forKey: .featureFlags)
            selfHealPatterns = try? container.decode(
                [SelfHealPatternDefinition].self,
                forKey: .selfHealPatterns
            )
            reviewPrompt = try? container.decode(ReviewPromptPolicy.self, forKey: .reviewPrompt)
        }
    }

    fileprivate struct RawRelayRuntimeConfig: Codable, Sendable {
        let version: String?
        let officialProviderWhitelist: [String]?
        let transportEnvelopes: [String: RawRelayTransportEnvelope]?
        let transportRules: [String: RawRelayTransportRule]?
        let verificationPolicy: RelayVerificationPolicy?
        let featureGatingPolicy: RelayFeatureGatingPolicy?
    }

    struct RelayRuntimeConfig: Sendable {
        let version: String
        let officialProviderWhitelist: [String]
        let transportEnvelopes: [String: RelayTransportEnvelope]
        let transportRules: [String: RelayTransportRule]
        let verificationPolicy: RelayVerificationPolicy
        let featureGatingPolicy: RelayFeatureGatingPolicy

        static let fallback = RelayRuntimeConfig(
            version: "fallback",
            officialProviderWhitelist: ["openAI", "anthropic", "gemini", "deepseek", "miniMax", "zhipu", "qwen", "moonshot"],
            transportEnvelopes: [
                "openai_responses": RelayTransportEnvelope(
                    image: true, nativeFile: true, textFileInline: true,
                    webSearch: true, imageGeneration: true, reasoning: true
                ),
                "openai_chat_completions": RelayTransportEnvelope(
                    image: true, nativeFile: false, textFileInline: true,
                    webSearch: false, imageGeneration: false, reasoning: true
                ),
                "anthropic_messages": RelayTransportEnvelope(
                    image: true, nativeFile: true, textFileInline: true,
                    webSearch: false, imageGeneration: false, reasoning: true
                ),
                "gemini_generate_content": RelayTransportEnvelope(
                    image: true, nativeFile: true, textFileInline: true,
                    webSearch: true, imageGeneration: true, reasoning: true
                ),
            ],
            transportRules: [
                "openai_responses": RelayTransportRule(
                    providerPriority: "openAI",
                    defaultAuthMode: "bearer",
                    defaultVersion: "v1",
                    acceptedVersions: ["v1"],
                    headerProfile: "codex_responses",
                    codexIdentityDefault: true,
                    webSearchToolName: "web_search",
                    imageRoute: "inline_responses_tool",
                    forceStreamForImageGeneration: true
                ),
                "openai_chat_completions": RelayTransportRule(
                    providerPriority: "openAI",
                    defaultAuthMode: "bearer",
                    defaultVersion: "v1",
                    acceptedVersions: ["v1"],
                    headerProfile: "none",
                    codexIdentityDefault: false,
                    webSearchToolName: "disabled",
                    imageRoute: "images_endpoint",
                    forceStreamForImageGeneration: false
                ),
                "anthropic_messages": RelayTransportRule(
                    providerPriority: "anthropic",
                    defaultAuthMode: "x_api_key",
                    defaultVersion: "v1",
                    acceptedVersions: ["v1"],
                    headerProfile: "anthropic_v2023_06_01",
                    codexIdentityDefault: false,
                    webSearchToolName: "disabled",
                    imageRoute: "unsupported",
                    forceStreamForImageGeneration: false
                ),
                "gemini_generate_content": RelayTransportRule(
                    providerPriority: "gemini",
                    defaultAuthMode: "x_goog_api_key",
                    defaultVersion: "v1beta",
                    acceptedVersions: ["v1", "v1beta"],
                    headerProfile: "gemini_key",
                    codexIdentityDefault: false,
                    webSearchToolName: "google_search",
                    imageRoute: "gemini_modality",
                    forceStreamForImageGeneration: false
                ),
            ],
            verificationPolicy: RelayVerificationPolicy(
                hardFailedExpiryDays: 7,
                softFailedRetryAfterSeconds: 60,
                verifiedCacheDays: 30
            ),
            featureGatingPolicy: RelayFeatureGatingPolicy(
                showActualModelIdHint: true,
                showSoftFailHint: true
            )
        )
    }

    enum RelayCatalogMatchSource: String, Sendable {
        case transportFirst = "transport_first"
        case crossProvider = "cross_provider"
    }

    struct RelayCatalogMatchResult: Sendable {
        let matchedProviderKind: ProviderKind
        let canonicalModelId: String
        let metadata: ResolvedModelMetadata
        let source: RelayCatalogMatchSource
    }

    private struct ProviderData: Codable, Sendable {
        let displayName: String?
        let attachmentSupport: AttachmentSupport?
        let defaultModelId: String?
        let validation: ProviderValidation?
        let resolveMap: [String: String]?
        let models: [String: ModelMetadataEntry]
        let transport: ProviderTransportDefinition?
    }

    struct ProviderValidation: Codable, Sendable, Equatable {
        let probe: String?
        let probePath: String?
        let authMode: String?
        let headerProfile: String?
        let invalidKeySignals: [InvalidKeySignal]?

        struct InvalidKeySignal: Codable, Sendable, Equatable {
            let status: Int?
            let bodyIncludes: [String]?
        }
    }

    enum JSONValue: Codable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .bool(let value):
                try container.encode(value)
            case .object(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }

        var foundationValue: Any {
            switch self {
            case .string(let value): return value
            case .number(let value): return value
            case .bool(let value): return value
            case .object(let value): return value.mapValues(\.foundationValue)
            case .array(let value): return value.map(\.foundationValue)
            case .null: return NSNull()
            }
        }
    }

    private struct IgnoredJSON: Codable, Sendable {
        init() {}

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
                for key in container.allKeys {
                    _ = try? container.decode(IgnoredJSON.self, forKey: key)
                }
                return
            }

            if var container = try? decoder.unkeyedContainer() {
                while !container.isAtEnd {
                    _ = try? container.decode(IgnoredJSON.self)
                }
                return
            }

            let container = try decoder.singleValueContainer()
            if container.decodeNil() { return }
            if (try? container.decode(Bool.self)) != nil { return }
            if (try? container.decode(Int.self)) != nil { return }
            if (try? container.decode(Double.self)) != nil { return }
            if (try? container.decode(String.self)) != nil { return }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    private struct DynamicCodingKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private struct ProfileDefinitions: Codable, Sendable {
        let reasoning: [String: ReasoningProfileDefinition]?
        let webSearch: [String: WebSearchProfileDefinition]?
        let imageGen: [String: ImageGenProfileDefinition]?
        let generation: GenerationProfileDefinitions?
    }

    private struct GenerationProfileDefinitions: Codable, Sendable {
        let version: Int?
        let parameters: [String: GenerationParameterDefinition]?
        let templates: [String: GenerationTemplateDefinition]?
    }

    private struct GenerationParameterDefinition: Codable, Sendable {
        let group: String?
        let valueSchema: String?
        let range: GenerationParameterRange?
        let enumValues: [GenerationParameterValue]?
        let fixedValue: GenerationParameterValue?
        let defaultDescription: GenerationParameterValue?
        let interactionGroup: String?
        let conflictsWith: [String]?
        let requires: [[String: GenerationParameterValue]]?
        let constraints: [[String: GenerationParameterValue]]?
        let portability: String?
        let risk: String?
    }

    private struct GenerationTemplateDefinition: Codable, Sendable {
        let transport: String?
        let wire: [String: String]?
    }

    nonisolated private static func resolveGenerationProfile(
        _ reference: GenerationProfileRef?,
        definitions: GenerationProfileDefinitions?,
        parameterTables: [String: [GenerationParameterRef]]?
    ) -> GenerationProfileRef? {
        guard let reference,
              let template = trimmedNonEmpty(reference.template),
              let templateDefinition = definitions?.templates?[template],
              let wire = templateDefinition.wire,
              !wire.isEmpty else {
            return nil
        }

        var resolved = reference
        resolved.template = template
        resolved.transport = templateDefinition.transport
        resolved.wire = wire
        let parameters: [GenerationParameterRef]?
        if reference.parametersRef != nil {
            parameters = trimmedNonEmpty(reference.parametersRef)
                .flatMap { parameterTables?[$0] }
        } else {
            parameters = reference.parameters
        }
        resolved.parameters = parameters?.map { parameter in
            guard let id = trimmedNonEmpty(parameter.id),
                  let definition = definitions?.parameters?[id] else {
                return parameter
            }
            var expanded = parameter
            expanded.id = id
            expanded.group = definition.group
            expanded.valueSchema = definition.valueSchema
            expanded.range = definition.range
            expanded.enumValues = parameter.enumValues ?? definition.enumValues
            expanded.fixedValue = definition.fixedValue
            expanded.defaultDescription = definition.defaultDescription
            expanded.interactionGroup = definition.interactionGroup
            expanded.conflictsWith = definition.conflictsWith
            expanded.requires = definition.requires
            expanded.constraints = definition.constraints
            expanded.portability = definition.portability
            expanded.risk = definition.risk
            return expanded
        }
        return resolved
    }

    struct ModelFacts: Codable, Sendable, Equatable {
        struct Modalities: Codable, Sendable, Equatable {
            let input: [String]?
            let output: [String]?
        }
        let toolCall: Bool?
        let reasoning: Bool?
        let reasoningEfforts: [String]?
        let reasoningToggle: Bool?
        let modalities: Modalities?
        let attachment: Bool?
        let source: String?
    }

    private struct MetadataResponse: Codable, Sendable {
        let version: Int
        let view: String?
        let contractVersion: Int?
        let capabilityContractVersion: Int?
        let updatedAt: String?
        let profiles: ProfileDefinitions?
        let generationParameterTables: [String: [GenerationParameterRef]]?
        let providers: [String: ProviderData]
        let providerConfigs: [PublicProviderConfig]?
        let relayRuntimeConfig: RawRelayRuntimeConfig?
        let runtimeConfig: RawRuntimeConfig?
        let libraryRuntimeConfig: LibraryRuntimeConfig?
        let capabilityRuntime: CapabilityRuntimeEnvelope?
        let modelFacts: [String: ModelFacts]?
        let modelFactsRevision: String?
    }

    // MARK: - Contract Version

    static let supportedContractVersion = 1

    static let authoritativeCapabilityContractVersion = 2

    struct ContractVersionSnapshot: Sendable, Equatable {
        let clientContractVersion: Int
        let metadataContractVersion: Int
        var isCompatible: Bool {
            metadataContractVersion <= clientContractVersion + 1
        }
        var shouldSafeDegrade: Bool {
            metadataContractVersion >= clientContractVersion + 2
        }
    }

    private struct WrappedResponse: Codable, Sendable {
        let data: MetadataResponse
    }

    private struct ModelFactsEndpointData: Codable, Sendable {
        let revision: String
        let facts: [String: ModelFacts]
    }

    private struct WrappedModelFactsResponse: Codable, Sendable {
        let data: ModelFactsEndpointData
    }

    private struct CacheEntry: Codable, Sendable {
        let data: MetadataResponse
        let timestamp: TimeInterval
    }

    private struct MetadataPayloadDecodeSentinel: LocalizedError, Sendable {
        var errorDescription: String? { "metadata_payload_decode_failed" }
    }

    private enum MetadataDecodeSource: String, Sendable {
        case network
        case grdb
        case userDefaults = "user_defaults"
    }

    // MARK: - Config

    private let cacheKey = "oriveo:metadataCache"
    private let etagKey = "oriveo:metadataETag"
    private let modelFactsETagKeyPrefix = "oriveo:modelFactsETag"
    private let cacheStorageFormatVersionKeyPrefix = "oriveo:metadataCacheStorageFormatVersion"
    private let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let currentCacheStorageFormatVersion = 1
    private static let librarySettingsRefreshInterval: TimeInterval = 60

    private let session: URLSession
    private let allowsNetworkRequestsInTests: Bool
    private let errorReporter: ErrorReporter

    private func cacheStorageFormatVersionKey(for boundUID: String) -> String {
        "\(cacheStorageFormatVersionKeyPrefix).\(boundUID)"
    }

    private func modelFactsETagKey(for boundUID: String) -> String {
        "\(modelFactsETagKeyPrefix).\(boundUID)"
    }

    private static let kindMap: [String: String] = [
        "openAI": "openAI",
        "anthropic": "anthropic",
        "gemini": "gemini",
        "openRouter": "openRouter",
        "deepseek": "deepseek",
        "grok": "grok",
        "groq": "groq",
        "together": "togetherAI",
        "fireworks": "fireworksAI",
        "miniMax": "miniMax",
        "zhipu": "zhipu",
        "qwen": "qwen",
        "moonshot": "moonshot",
        "mistral": "mistral",
        "siliconFlow": "siliconFlow",
    ]

    private static let validCapabilities: Set<String> = [
        "reasoning", "text", "image", "video", "file", "web", "imageGeneration",
    ]
    private static let snapshotDatePatterns = [
        #"-\d{8}$"#,
        #"-\d{4}-\d{2}-\d{2}$"#,
    ]
    private static let nonAutomaticReasoningModes: [ReasoningMode] = [
        .fast, .balanced, .deep, .max,
    ]

    // MARK: - State

    private final class MetadataSnapshotBox: Sendable {
        let snapshot: MetadataResponse

        init(_ snapshot: MetadataResponse) { self.snapshot = snapshot }

        deinit {
            MetadataClient.drainOffCallerThread(snapshot)
        }
    }

    private static let snapshotReleaseQueue = DispatchQueue(
        label: "ai.oriveo.community.metadata.snapshot-release",
        qos: .utility
    )

    nonisolated private static func drainOffCallerThread(_ snapshot: MetadataResponse?) {
        guard let snapshot else { return }
        snapshotReleaseQueue.async {
            withExtendedLifetime(snapshot) {}
            #if DEBUG
            snapshotReleaseThreadObserverForTesting?(Thread.isMainThread)
            #endif
        }
    }

    #if DEBUG
    nonisolated(unsafe) static var snapshotReleaseThreadObserverForTesting: (@Sendable (Bool) -> Void)?

    nonisolated static func waitForSnapshotReleaseDrainForTesting() {
        snapshotReleaseQueue.sync {}
    }
    #endif

    private struct SharedMetadataState: Sendable {
        let box: MetadataSnapshotBox?
        let etag: String?
        let generation: UInt64
    }
    private static let sharedStateLock = OSAllocatedUnfairLock(
        initialState: SharedMetadataState(box: nil, etag: nil, generation: 0)
    )

    nonisolated private static func withSharedSnapshot<T>(_ body: (MetadataResponse?) -> T) -> T {
        let box = sharedStateLock.withLock { $0.box }
        guard let box else { return body(nil) }
        return body(box.snapshot)
    }

    nonisolated private static func withSharedState<T>(_ body: (MetadataResponse?, String?) -> T) -> T {
        let state = sharedStateLock.withLock { $0 }
        guard let box = state.box else { return body(nil, state.etag) }
        return body(box.snapshot, state.etag)
    }

    nonisolated private static var sharedETag: String? { sharedStateLock.withLock { $0.etag } }

    nonisolated private static func replaceSharedState(snapshot: MetadataResponse?, etag: String?) {
        let box = snapshot.map(MetadataSnapshotBox.init)
        let previous = sharedStateLock.withLock { state -> MetadataSnapshotBox? in
            let old = state.box
            state = SharedMetadataState(
                box: box,
                etag: etag,
                generation: state.generation &+ 1
            )
            return old
        }
        withExtendedLifetime(previous) {}
    }

    private static let snapshotConfirmedLock = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static var snapshotConfirmedThisSession: Bool {
        get { snapshotConfirmedLock.withLock { $0 } }
        set { snapshotConfirmedLock.withLock { $0 = newValue } }
    }

    private var table: MetadataResponse?
    private var storedETag: String?
    private var storedModelFactsETag: String?
    private var boundUID: String?
    private var bootstrappedUID: String?
    private var initialization: (token: UUID, uid: String, task: Task<Void, Never>)?
    private var lastLibrarySettingsRefreshAtByUID: [String: Date] = [:]
    #if DEBUG
    private var grdbPersistCountForTesting = 0
    #endif

    init(
        session: URLSession = .shared,
        allowsNetworkRequestsInTests: Bool = false,
        errorReporter: @escaping ErrorReporter = { error, context in
            Task { @MainActor in
                AppLog.error(error, module: "metadata", context: context)
            }
        }
    ) {
        self.session = session
        self.allowsNetworkRequestsInTests = allowsNetworkRequestsInTests
        self.errorReporter = errorReporter
    }

    // MARK: - Public API

    func initialize() async {
        while true {
            let requestedUID = AppSessionStore.activeUID
            if bootstrappedUID == requestedUID, boundUID == requestedUID { return }

            if let current = initialization {
                await current.task.value
                if initialization?.token == current.token {
                    initialization = nil
                }
                continue
            }

            let token = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.bootstrap(boundUID: requestedUID)
            }
            initialization = (token, requestedUID, task)
            await task.value
            if initialization?.token == token {
                initialization = nil
            }
            if AppSessionStore.activeUID == requestedUID, boundUID == requestedUID {
                bootstrappedUID = requestedUID
                return
            }
        }
    }

    private func bootstrap(boundUID requestedUID: String) async {
        boundUID = requestedUID
        replaceTable(nil)
        storedETag = nil
        storedModelFactsETag = UserDefaults.standard.string(
            forKey: modelFactsETagKey(for: requestedUID)
        )
        Self.replaceSharedState(snapshot: nil, etag: nil)

        if let entry = loadPersistedCache(boundUID: requestedUID) {
            replaceTable(entry.data)
            Self.replaceSharedState(snapshot: entry.data, etag: entry.etag)
            if entry.requiresStorageMigration {
                persistCache(entry.data, timestamp: entry.timestamp, etag: entry.etag, boundUID: requestedUID)
            }
            await publishCapabilityEvidenceContent(snapshot: entry.data, etag: entry.etag)
            Self.syncSelfHealPatternsToClassifier()
            storedETag = entry.etag
            if Date().timeIntervalSince1970 - entry.timestamp < cacheTTL {
                await fetchMetadata(boundUID: requestedUID)
                return
            }
        } else if let entry = loadLegacyUserDefaultsCache() {
            let safeData = Self.sanitizedMetadataResponse(entry.data)
            replaceTable(safeData)
            Self.replaceSharedState(
                snapshot: safeData, etag: UserDefaults.standard.string(forKey: etagKey)
            )
            await publishCapabilityEvidenceContent(
                snapshot: safeData,
                etag: UserDefaults.standard.string(forKey: etagKey)
            )
            Self.syncSelfHealPatternsToClassifier()
            storedETag = UserDefaults.standard.string(forKey: etagKey)
            persistCache(
                safeData,
                timestamp: entry.timestamp,
                etag: UserDefaults.standard.string(forKey: etagKey),
                boundUID: requestedUID
            )
            if Date().timeIntervalSince1970 - entry.timestamp < cacheTTL {
                await fetchMetadata(boundUID: requestedUID)
                return
            }
        }

        await fetchMetadata(boundUID: requestedUID)
    }

    func ensureInitialized() async {
        await initialize()
    }

    func refreshModelFacts() async {
        await ensureInitialized()
        await fetchModelFacts()
    }

    func forceRefresh() async {
        let requestedUID = AppSessionStore.activeUID
        if boundUID != requestedUID {
            boundUID = requestedUID
            bootstrappedUID = nil
            replaceTable(nil)
            storedETag = nil
            storedModelFactsETag = UserDefaults.standard.string(
                forKey: modelFactsETagKey(for: requestedUID)
            )
            Self.replaceSharedState(snapshot: nil, etag: nil)
        }
        await fetchMetadata(boundUID: requestedUID, bypassETag: true)
        if AppSessionStore.activeUID == requestedUID, boundUID == requestedUID {
            bootstrappedUID = requestedUID
        }
    }

    @discardableResult
    func refreshForLibrarySettings(
        minimumInterval: TimeInterval = MetadataClient.librarySettingsRefreshInterval,
        now: Date = Date()
    ) async -> Bool {
        let requestedUID = AppSessionStore.activeUID
        let wasBootstrapped = bootstrappedUID == requestedUID && boundUID == requestedUID
        await ensureInitialized()
        guard AppSessionStore.activeUID == requestedUID else {
            return await refreshForLibrarySettings(minimumInterval: minimumInterval, now: now)
        }
        guard wasBootstrapped else { return false }
        if let lastLibrarySettingsRefreshAt = lastLibrarySettingsRefreshAtByUID[requestedUID],
           now.timeIntervalSince(lastLibrarySettingsRefreshAt) < minimumInterval {
            return false
        }
        lastLibrarySettingsRefreshAtByUID[requestedUID] = now
        await fetchMetadata(boundUID: requestedUID)
        return true
    }

    nonisolated func resolveCatalogModel(
        modelID: String,
        providerKind: ProviderKind
    ) -> ResolvedModelMetadata? {
        Self.withSharedState { snapshot, etag in
            Self.resolveCatalogModel(
                in: snapshot, modelID: modelID, providerKind: providerKind, metadataRevision: etag
            )
        }
    }

    func lookup(modelID: String, providerKind: ProviderKind) -> (promptPerToken: Double, completionPerToken: Double)? {
        guard let metadata = resolveCatalogModel(modelID: modelID, providerKind: providerKind),
              let prompt = metadata.promptPerToken,
              let completion = metadata.completionPerToken else { return nil }
        return (prompt, completion)
    }

    func capabilities(modelID: String, providerKind: ProviderKind) -> [ModelCapability]? {
        guard let metadata = resolveCatalogModel(modelID: modelID, providerKind: providerKind),
              !metadata.capabilities.isEmpty else {
            return nil
        }
        return metadata.capabilities
    }

    nonisolated func providerModelIDs(providerKind: ProviderKind) -> [String] {
        Self.withSharedSnapshot { snapshot -> [String] in
            guard let provider = Self.providerData(for: providerKind, in: snapshot) else { return [] }
            return provider.models.keys.sorted()
        }
    }

    nonisolated func providerDefaultModelID(providerKind: ProviderKind) -> String? {
        Self.withSharedSnapshot { Self.providerData(for: providerKind, in: $0)?.defaultModelId }
    }

    func providerValidation(providerKind: ProviderKind) -> ProviderValidation? {
        providerData(for: providerKind)?.validation
    }

    nonisolated func syncProviderValidation(providerKind: ProviderKind) -> ProviderValidation? {
        Self.withSharedSnapshot { Self.providerData(for: providerKind, in: $0)?.validation }
    }

    func providerDisplayName(providerKind: ProviderKind) -> String? {
        providerData(for: providerKind)?.displayName
    }

    func providerAttachmentSupport(providerKind: ProviderKind) -> AttachmentSupport? {
        providerData(for: providerKind)?.attachmentSupport
    }


    func providerTransport(providerKind: ProviderKind) -> ProviderTransportDefinition? {
        providerData(for: providerKind)?.transport
    }

    nonisolated func syncProviderTransport(providerKind: ProviderKind) -> ProviderTransportDefinition? {
        Self.withSharedSnapshot { Self.providerData(for: providerKind, in: $0)?.transport }
    }

    nonisolated func syncWebSearchStreamShape(profileName: String?) -> StreamShape? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return Self.withSharedSnapshot { $0?.profiles?.webSearch?[name]?.streamShape }
    }

    nonisolated func syncReasoningStreamShape(profileName: String?) -> StreamShape? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return Self.withSharedSnapshot { $0?.profiles?.reasoning?[name]?.streamShape }
    }


    nonisolated func syncReasoningMergeParams(profileName: String?, mode: ReasoningMode) -> [String: Any]? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let (profile, normalized) = Self.withSharedSnapshot { snapshot -> (ReasoningProfileDefinition?, ReasoningMode) in
            (
                snapshot?.profiles?.reasoning?[name],
                Self.clampReasoningMode(mode, profileName: name, in: snapshot)
            )
        }
        let effectiveLevel: String
        if normalized == .automatic {
            guard let defaultLevel = profile?.defaultLevel,
                  !defaultLevel.isEmpty else { return nil }
            effectiveLevel = defaultLevel
        } else {
            effectiveLevel = normalized.rawValue
        }
        return profile?.params?[effectiveLevel]?.foundationValue as? [String: Any]
    }

    nonisolated func syncImageGenStreamShape(profileName: String?) -> StreamShape? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return Self.withSharedSnapshot { $0?.profiles?.imageGen?[name]?.streamShape }
    }

    nonisolated func syncImageGenMergeParams(profileName: String?) -> [String: Any]? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return Self.withSharedSnapshot { $0?.profiles?.imageGen?[name]?.mergeParams?.foundationValue } as? [String: Any]
    }

    nonisolated func syncImageGenRoute(profileName: String?) -> String? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return Self.withSharedSnapshot { $0?.profiles?.imageGen?[name]?.route }
    }

    nonisolated func syncImageGenRequestDefaults(profileName: String?) -> [String: Any]? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return Self.withSharedSnapshot { $0?.profiles?.imageGen?[name]?.requestDefaults?.foundationValue } as? [String: Any]
    }

    nonisolated func syncWebSearchMergeParams(profileName: String?) -> [String: Any]? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let lookup = Self.withSharedSnapshot { snapshot -> (isKnown: Bool, merged: Any?) in
            guard let def = snapshot?.profiles?.webSearch?[name] else { return (false, nil) }
            return (true, def.mergeParams?.foundationValue)
        }
        if lookup.isKnown {
            return lookup.merged as? [String: Any]
        }
        return nil
    }

    nonisolated func syncWebSearchMaxToolLoops(profileName: String?) -> Int? {
        guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return Self.withSharedSnapshot { $0?.profiles?.webSearch?[name]?.maxToolLoops }
    }

    nonisolated func syncKnownWebSearchProfileNames() -> Set<String> {
        Self.withSharedSnapshot { snapshot -> Set<String> in
            guard let map = snapshot?.profiles?.webSearch else { return [] }
            return Set(map.keys)
        }
    }

    func hasPublicProviderConfigSource() -> Bool {
        table?.providerConfigs != nil
    }

    func listPublicProviderConfigs() -> [PublicProviderConfig] {
        guard let configs = table?.providerConfigs else { return [] }
        return configs.sorted { left, right in
            let leftOrder = left.sortOrder ?? Int.max
            let rightOrder = right.sortOrder ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            let leftIndex = Self.providerConfigFallbackOrder(left.kind)
            let rightIndex = Self.providerConfigFallbackOrder(right.kind)
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return left.kind < right.kind
        }
    }

    func currentVersion() -> Int? {
        table?.version
    }

    nonisolated func contractVersionSnapshot() -> ContractVersionSnapshot {
        ContractVersionSnapshot(
            clientContractVersion: Self.supportedContractVersion,
            metadataContractVersion: Self.withSharedSnapshot { $0?.contractVersion } ?? 0
        )
    }

    func supportedReasoningModes(profileName: String?) -> [ReasoningMode] {
        Self.supportedReasoningModes(profileName: profileName, in: table)
    }

    func clampReasoningMode(_ mode: ReasoningMode, profileName: String?) -> ReasoningMode {
        Self.clampReasoningMode(mode, profileName: profileName, in: table)
    }

    nonisolated func syncMetadataSnapshotVersion() -> Int? {
        Self.withSharedSnapshot { $0?.version }
    }

    nonisolated func syncMetadataETag() -> String? {
        Self.sharedETag
    }

    nonisolated static func sharedSnapshotGeneration() -> UInt64 {
        sharedStateLock.withLock { $0.generation }
    }

    nonisolated func syncModelFacts(providerKind: ProviderKind, modelID: String) -> ModelFacts? {
        guard let key = Self.modelFactsKey(providerKind: providerKind, modelID: modelID) else { return nil }
        return Self.withSharedSnapshot { $0?.modelFacts?[key] }
    }

    nonisolated func syncModelFactsRevision() -> String? {
        Self.withSharedSnapshot { $0?.modelFactsRevision }
    }

    nonisolated static func modelFactsKey(providerKind: ProviderKind, modelID: String) -> String? {
        guard let kind = kindMap[providerKind.rawValue] else { return nil }
        let normalized = normalizeModelFactsID(modelID)
        guard !normalized.isEmpty else { return nil }
        return "\(kind)/\(normalized)"
    }

    nonisolated static func normalizeModelFactsID(_ modelID: String) -> String {
        var value = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["accounts/fireworks/models/", "accounts/fireworks/routers/", "pro/"]
        where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        value = value.replacingOccurrences(
            of: #"(?:-\d{8}|-\d{4}-\d{2}-\d{2})$"#, with: "", options: .regularExpression
        )
        return value.replacingOccurrences(
            of: #"(\d)p(\d)"#, with: "$1.$2", options: .regularExpression
        )
    }

    nonisolated func syncResolveCatalogModel(modelID: String, providerKind: ProviderKind) -> ResolvedModelMetadata? {
        resolveCatalogModel(modelID: modelID, providerKind: providerKind)
    }

    nonisolated func syncCapabilityRecipeRuntime(
        modelID: String,
        providerKind: ProviderKind
    ) -> CapabilityRecipeRuntimeSnapshot {
        Self.withSharedState { snapshot, etag -> CapabilityRecipeRuntimeSnapshot in
            guard let runtime = snapshot?.capabilityRuntime else {
                return .init(runtime: nil, controls: nil)
            }
            guard let resolved = Self.resolveCatalogModel(
                in: snapshot, modelID: modelID, providerKind: providerKind,
                metadataRevision: etag
            ), let provider = Self.providerData(for: providerKind, in: snapshot),
              let model = provider.models[resolved.canonicalModelId] else {
                return .init(runtime: runtime, controls: nil)
            }
            return .init(runtime: runtime, controls: model.capabilityControls)
        }
    }

    nonisolated func syncCapabilityRecipe(
        modelID: String,
        providerKind: ProviderKind,
        capability: String
    ) -> CapabilityRecipe? {
        guard let resolved = syncResolveCatalogModel(modelID: modelID, providerKind: providerKind) else {
            return nil
        }
        let snapshot = syncCapabilityRecipeRuntime(modelID: modelID, providerKind: providerKind)
        guard let runtime = snapshot.runtime,
              runtime.schemaVersion == RequestPreferenceResolver.runtimeSchemaVersion,
              let control = snapshot.controls?[capability],
              control.state == RequestControlAvailability.autoAvailable.rawValue,
              let ref = control.recipeRef,
              let recipe = runtime.recipes[ref],
              (
                Self.canonicalCapabilityTransport(resolved.transport ?? "") == Self.canonicalCapabilityTransport(recipe.transport.protocolName)
                // Endpoint-route recipes are an explicit runtime transport replacement, not a
                // selector alias. Gemini Interactions is therefore reachable only through its
                // exact control/route validation, while ordinary model transport misses fail.
                || (recipe.executionKind == "endpoint_route" && recipe.transport.protocolName == "gemini_interactions")
              )
        else { return nil }
        return recipe
    }

    private static func canonicalCapabilityTransport(_ transport: String) -> String {
        transport == "gemini_generate" ? "gemini_generate_content" : transport
    }

    nonisolated func syncCapabilityEvidenceModelInput(
        modelID: String,
        providerKind: ProviderKind
    ) -> (
        resolved: ResolvedModelMetadata?,
        metadataRevision: String?,
        reasoningModes: [ReasoningMode],
        reasoningDefaultLevel: ReasoningMode?
    ) {
        Self.withSharedState { snapshot, etag in
            let resolved = Self.resolveCatalogModel(
                in: snapshot,
                modelID: modelID,
                providerKind: providerKind,
                metadataRevision: etag
            )
            return (
                resolved,
                etag,
                Self.supportedReasoningModes(profileName: resolved?.profiles.reasoning, in: snapshot),
                Self.declaredReasoningDefaultLevel(
                    profileName: resolved?.profiles.reasoning, in: snapshot
                )
            )
        }
    }

    nonisolated func syncCurrentCapabilityEvidenceModel(_ model: AIModel, providerKind: ProviderKind) -> AIModel {
        var current = model
        guard let resolved = Self.withSharedState({ snapshot, etag in
            Self.resolveCatalogModel(
                in: snapshot, modelID: model.id, providerKind: providerKind, metadataRevision: etag
            )
        }) else {
            current.generationProfile = nil
            current.capabilityEvidenceCandidates = []
            current.capabilityEvidenceOwnedKeys = []
            current.capabilityEvidenceViewPresent = false
            current.capabilityEvidenceViewMalformed = false
            return current
        }
        current.canonicalModelId = resolved.canonicalModelId
        current.generationProfile = resolved.generationProfile
        current.capabilityEvidenceCandidates = resolved.capabilityEvidenceCandidates
        current.capabilityEvidenceOwnedKeys = resolved.capabilityEvidenceOwnedKeys
        current.capabilityEvidenceViewPresent = resolved.capabilityEvidenceViewPresent
        current.capabilityEvidenceViewMalformed = resolved.capabilityEvidenceViewMalformed
        return current
    }

    nonisolated func syncResolveCatalogModelAcrossProviders(modelID: String) -> ResolvedModelMetadata? {
        Self.withSharedSnapshot { snapshot -> ResolvedModelMetadata? in
            for kind in ProviderKind.allCases where kind != .relay {
                if let resolved = Self.resolveCatalogModel(in: snapshot, modelID: modelID, providerKind: kind) {
                    return resolved
                }
            }
            return nil
        }
    }

    nonisolated func syncResolveCatalogModelAcrossProvidersWithProvider(
        modelID: String,
        transportPriority: ProviderKind? = nil
    ) -> RelayCatalogMatchResult? {
        let runtime = syncRelayRuntimeConfig()
        let whitelist = runtime.officialProviderWhitelist
        let priorityRaw = transportPriority?.rawValue

        var ordered: [ProviderKind] = []
        if let raw = priorityRaw,
           whitelist.contains(raw),
           let kind = ProviderKind(rawValue: raw) {
            ordered.append(kind)
        }
        for raw in whitelist {
            if raw == priorityRaw { continue }
            guard let kind = ProviderKind(rawValue: raw) else { continue }
            ordered.append(kind)
        }

        return Self.withSharedSnapshot { snapshot -> RelayCatalogMatchResult? in
            for kind in ordered {
                if let resolved = Self.resolveCatalogModel(
                    in: snapshot,
                    modelID: modelID,
                    providerKind: kind
                ) {
                    return RelayCatalogMatchResult(
                        matchedProviderKind: kind,
                        canonicalModelId: resolved.canonicalModelId,
                        metadata: resolved,
                        source: kind.rawValue == priorityRaw ? .transportFirst : .crossProvider
                    )
                }
            }
            return nil
        }
    }

    nonisolated func syncFeatureFlag(_ key: String, defaultValue: Bool) -> Bool {
        Self.withSharedSnapshot { $0?.runtimeConfig?.featureFlags?[key] } ?? defaultValue
    }

    nonisolated func syncReviewPromptPolicy() -> ReviewPromptPolicy? {
        Self.withSharedSnapshot { $0?.runtimeConfig?.reviewPrompt }
    }

    nonisolated func syncLibraryRuntimeConfig() -> LibraryRuntimeConfig {
        Self.withSharedSnapshot { $0?.libraryRuntimeConfig } ?? .fallback
    }

    nonisolated func syncSnapshotConfirmedThisSession() -> Bool {
        Self.snapshotConfirmedThisSession
    }

    nonisolated func syncHasCatalogModel(modelID: String, providerKind: ProviderKind) -> Bool {
        Self.withSharedSnapshot {
            Self.resolveCatalogModel(in: $0, modelID: modelID, providerKind: providerKind)
        } != nil
    }

    nonisolated static func syncSelfHealPatternsToClassifier() {
        UnsupportedParamClassifier.setRuntimePatterns(withSharedSnapshot { $0?.runtimeConfig?.selfHealPatterns } ?? [])
    }

    nonisolated func syncRelayRuntimeConfig() -> RelayRuntimeConfig {
        Self.withSharedSnapshot { snapshot -> RelayRuntimeConfig in
            guard let remote = snapshot?.relayRuntimeConfig else {
                return RelayRuntimeConfig.fallback
            }
            return Self.mergeRelayRuntimeConfig(remote: remote)
        }
    }

    nonisolated private static func mergeRelayRuntimeConfig(
        remote: RawRelayRuntimeConfig
    ) -> RelayRuntimeConfig {
        let fallback = RelayRuntimeConfig.fallback
        let whitelist: [String] = {
            if let raw = remote.officialProviderWhitelist, !raw.isEmpty {
                return raw
            }
            return fallback.officialProviderWhitelist
        }()

        var envelopes = fallback.transportEnvelopes
        if let remoteEnvelopes = remote.transportEnvelopes {
            for (key, override) in remoteEnvelopes {
                guard let base = envelopes[key] else { continue }
                envelopes[key] = RelayTransportEnvelope(
                    image: override.image ?? base.image,
                    nativeFile: override.nativeFile ?? base.nativeFile,
                    textFileInline: override.textFileInline ?? base.textFileInline,
                    webSearch: override.webSearch ?? base.webSearch,
                    imageGeneration: override.imageGeneration ?? base.imageGeneration,
                    reasoning: override.reasoning ?? base.reasoning
                )
            }
        }

        var rules = fallback.transportRules
        if let remoteRules = remote.transportRules {
            for (key, override) in remoteRules {
                guard let base = rules[key] else { continue }
                rules[key] = RelayTransportRule(
                    providerPriority: override.providerPriority ?? base.providerPriority,
                    defaultAuthMode: override.defaultAuthMode ?? base.defaultAuthMode,
                    defaultVersion: override.defaultVersion ?? base.defaultVersion,
                    acceptedVersions: (override.acceptedVersions?.isEmpty == false)
                        ? override.acceptedVersions!
                        : base.acceptedVersions,
                    headerProfile: override.headerProfile ?? base.headerProfile,
                    codexIdentityDefault: override.codexIdentityDefault ?? base.codexIdentityDefault,
                    webSearchToolName: override.webSearchToolName ?? base.webSearchToolName,
                    imageRoute: override.imageRoute ?? base.imageRoute,
                    forceStreamForImageGeneration: override.forceStreamForImageGeneration ?? base.forceStreamForImageGeneration
                )
            }
        }

        let version: String = {
            if let raw = remote.version, !raw.isEmpty { return raw }
            return fallback.version
        }()

        return RelayRuntimeConfig(
            version: version,
            officialProviderWhitelist: whitelist,
            transportEnvelopes: envelopes,
            transportRules: rules,
            verificationPolicy: remote.verificationPolicy ?? fallback.verificationPolicy,
            featureGatingPolicy: remote.featureGatingPolicy ?? fallback.featureGatingPolicy
        )
    }

    nonisolated func syncProviderDisplayName(providerKind: ProviderKind) -> String? {
        Self.withSharedSnapshot { Self.providerData(for: providerKind, in: $0)?.displayName }
    }

    nonisolated func syncProviderAttachmentSupport(providerKind: ProviderKind) -> AttachmentSupport? {
        Self.withSharedSnapshot { Self.providerData(for: providerKind, in: $0)?.attachmentSupport }
    }

    nonisolated func syncGrokSubscriptionAvailability() -> GrokSubscriptionAvailability {
        let raw = Self.withSharedSnapshot { snapshot in
            snapshot?.providerConfigs?
                .first { $0.kind == ProviderKind.grok.rawValue }?
                .protocolFeatures?
                .subscriptionAuth
        }
        return GrokSubscriptionAuthResolver.resolve(raw: raw)
    }

    nonisolated func syncOpenAISubscriptionAvailability() -> OpenAISubscriptionAvailability {
        let raw = Self.withSharedSnapshot { snapshot in
            snapshot?.providerConfigs?
                .first { $0.kind == ProviderKind.openAI.rawValue }?
                .protocolFeatures?
                .subscriptionAuth
        }
        return OpenAISubscriptionAuthResolver.resolve(raw: raw)
    }

    nonisolated func syncHasPublicProviderConfigSource() -> Bool {
        Self.withSharedSnapshot { $0?.providerConfigs != nil }
    }

    nonisolated func syncListPublicProviderConfigs() -> [PublicProviderConfig] {
        Self.withSharedSnapshot { snapshot -> [PublicProviderConfig] in
            guard let configs = snapshot?.providerConfigs else { return [] }
            return configs.sorted { left, right in
                let leftOrder = left.sortOrder ?? Int.max
                let rightOrder = right.sortOrder ?? Int.max
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                let leftIndex = Self.providerConfigFallbackOrder(left.kind)
                let rightIndex = Self.providerConfigFallbackOrder(right.kind)
                if leftIndex != rightIndex { return leftIndex < rightIndex }
                return left.kind < right.kind
            }
        }
    }

    nonisolated func syncProviderDefaultModelID(providerKind: ProviderKind) -> String? {
        providerDefaultModelID(providerKind: providerKind)
    }

    nonisolated func syncSupportedReasoningModes(profileName: String?) -> [ReasoningMode] {
        Self.withSharedSnapshot { Self.supportedReasoningModes(profileName: profileName, in: $0) }
    }

    nonisolated func syncDeclaredReasoningDefaultLevel(
        profileName: String?
    ) -> ReasoningMode? {
        Self.withSharedSnapshot {
            Self.declaredReasoningDefaultLevel(profileName: profileName, in: $0)
        }
    }

    nonisolated func syncClampReasoningMode(mode: ReasoningMode, profileName: String?) -> ReasoningMode {
        Self.withSharedSnapshot { Self.clampReasoningMode(mode, profileName: profileName, in: $0) }
    }

    // MARK: - Internal

    private func replaceTable(_ newValue: MetadataResponse?) {
        let previous = table
        table = newValue
        Self.drainOffCallerThread(previous)
    }

    private func providerData(for providerKind: ProviderKind) -> ProviderData? {
        Self.providerData(for: providerKind, in: table)
    }

    nonisolated private static func providerData(
        for providerKind: ProviderKind,
        in table: MetadataResponse?
    ) -> ProviderData? {
        guard let table else { return nil }
        let backendKind = kindMap[providerKind.rawValue] ?? providerKind.rawValue
        return table.providers[backendKind]
    }

    nonisolated private static func providerConfigFallbackOrder(_ kind: String) -> Int {
        switch kind {
        case "openAI": return 0
        case "anthropic": return 1
        case "gemini": return 2
        case "openRouter": return 3
        case "deepseek": return 4
        case "grok": return 5
        case "moonshot": return 6
        case "mistral": return 7
        case "siliconFlow": return 8
        case "groq": return 9
        case "togetherAI": return 10
        case "fireworksAI": return 11
        case "miniMax": return 12
        case "zhipu": return 13
        case "qwen": return 14
        default: return Int.max
        }
    }

    nonisolated private static func resolveCatalogModel(
        in table: MetadataResponse?,
        modelID: String,
        providerKind: ProviderKind,
        metadataRevision: String? = nil
    ) -> ResolvedModelMetadata? {
        guard let provider = providerData(for: providerKind, in: table),
              let resolveMap = provider.resolveMap else { return nil }

        let strippedID = ModelResolver.resolvedProviderModelIdentifier(modelID, providerKind: providerKind)
        var lookupKeys = lookupCandidates(for: modelID)
        if strippedID != modelID {
            for candidate in lookupCandidates(for: strippedID) where !lookupKeys.contains(candidate) {
                lookupKeys.append(candidate)
            }
        }
        let canonicalId = lookupKeys.lazy
            .compactMap { key -> String? in
                if let resolved = resolveMap[key] {
                    return resolved
                }
                return provider.models[key] == nil ? nil : key
            }
            .first
        guard let canonicalId,
              let model = provider.models[canonicalId] else { return nil }

        let capabilities = Self.normalizeCapabilities(
            model.capabilities,
            badgeOrder: model.uiHints?.badgeOrder
        )
        let pricing = model.pricing
        let pricingUnit = Self.normalizePricingUnit(model.pricingUnit)
        let pricingStatus = Self.normalizePricingStatus(model, pricing: pricing, pricingUnit: pricingUnit)
        let profiles = model.profiles
        let hints = model.uiHints
        let sourceSummary = Self.normalizeSourceSummary(model.sourceSummary)
        let backendProviderKind = kindMap[providerKind.rawValue] ?? providerKind.rawValue
        let evidence = Self.normalizeCapabilityEvidenceView(
            model.capabilityEvidenceView,
            namespacePresent: model.$capabilityEvidenceView.isPresent,
            metadataRevision: metadataRevision,
            allowsLeanIdentityFallback: table?.view == "lean",
            treeProviderKind: backendProviderKind,
            projectedProviderKind: providerKind.rawValue,
            treeModelID: model.canonicalModelId ?? canonicalId,
            treeTransport: model.transport
        )

        let badgeOrder = hints?.badgeOrder?
            .compactMap { ModelCapability(rawValue: $0) }
            .filter { $0 != .text }

        return ResolvedModelMetadata(
            canonicalModelId: model.canonicalModelId ?? canonicalId,
            modelRef: Self.trimmedNonEmpty(model.modelRef),
            displayName: model.displayName,
            contextLength: model.contextLength,
            maxOutputTokens: model.maxOutputTokens,
            supportsTemperature: model.supportsTemperature,
            billingSku: Self.trimmedNonEmpty(model.billingSku),
            pricingUnit: pricingUnit,
            sourceSummary: sourceSummary,
            pricingStatus: pricingStatus,
            capabilities: capabilities,
            promptPerToken: (pricingStatus == "unknown" || pricingUnit != "per_token") ? nil : pricing?.promptPerToken,
            completionPerToken: (pricingStatus == "unknown" || pricingUnit != "per_token") ? nil : pricing?.completionPerToken,
            costPerUnit: pricing?.costPerUnit,
            costInputBatches: pricing?.costInputBatches,
            costOutputBatches: pricing?.costOutputBatches,
            costInputPriority: pricing?.costInputPriority,
            costOutputPriority: pricing?.costOutputPriority,
            cacheReadInputPerMToken: pricing?.cacheReadInputPerMToken,
            cacheCreationInputPerMToken: pricing?.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken: pricing?.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken: pricing?.cacheWrite1hPerMToken,
            profiles: (
                reasoning: profiles?.reasoning,
                webSearch: profiles?.webSearch,
                imageGen: profiles?.imageGen
            ),
            generationProfile: Self.resolveGenerationProfile(
                profiles?.generation,
                definitions: table?.profiles?.generation,
                parameterTables: table?.generationParameterTables
            ),
            supportsPdfInput: model.supportsPdfInput ?? false,
            supportsServiceTier: model.supportsServiceTier ?? false,
            uiHints: (
                groupKey: hints?.groupKey,
                groupName: hints?.groupName,
                rank: hints?.rank,
                recommended: hints?.recommended ?? false,
                badgeOrder: badgeOrder
            ),
            isDefault: provider.defaultModelId == canonicalId,
            vendorKey: Self.trimmedNonEmpty(model.vendorKey),
            vendorName: Self.trimmedNonEmpty(model.vendorName),
            toolCall: model.toolCall,
            libraryAgentic: model.libraryAgentic,
            capabilityContractVersion: table?.capabilityContractVersion,
            transport: Self.trimmedNonEmpty(model.transport),
            capabilityEvidenceCandidates: evidence.candidates,
            capabilityEvidenceOwnedKeys: evidence.ownedKeys,
            capabilityEvidenceViewPresent: evidence.namespacePresent,
            capabilityEvidenceViewMalformed: evidence.malformed
        )
    }

    nonisolated private static func normalizeCapabilityEvidenceView(
        _ raw: JSONValue?,
        namespacePresent: Bool,
        metadataRevision: String?,
        allowsLeanIdentityFallback: Bool,
        treeProviderKind: String,
        projectedProviderKind: String,
        treeModelID: String,
        treeTransport: String?
    ) -> CapabilityEvidenceViewProjection {
        guard namespacePresent else { return .absent }
        guard let raw else {
            return CapabilityEvidenceViewProjection(
                namespacePresent: true, candidates: [], ownedKeys: [], malformed: true
            )
        }
        guard case .object(let object) = raw,
              case .array(let rawCandidates)? = object["candidates"] else {
            return CapabilityEvidenceViewProjection(
                namespacePresent: true, candidates: [], ownedKeys: [], malformed: true
            )
        }
        if let schema = object["schema"] {
            guard case .string("capability-evidence-view/v1") = schema else {
                return CapabilityEvidenceViewProjection(
                    namespacePresent: true, candidates: [], ownedKeys: [], malformed: true
                )
            }
        } else if !allowsLeanIdentityFallback {
            return CapabilityEvidenceViewProjection(
                namespacePresent: true, candidates: [], ownedKeys: [], malformed: true
            )
        }

        guard let treeTransport = trimmedNonEmpty(treeTransport),
              CapabilityEvidenceFacade.isConcreteTransport(treeTransport) else {
            return CapabilityEvidenceViewProjection(
                namespacePresent: true, candidates: [], ownedKeys: [], malformed: false
            )
        }

        var candidates: [CapabilityEvidenceFacade.Candidate] = []
        var ownedKeys: Set<String> = []
        for rawCandidate in rawCandidates {
            guard case .object(let value) = rawCandidate,
                  let key = jsonString(value["key"]),
                  isSafeCapabilityEvidenceKey(key) else { continue }
            ownedKeys.insert(key)

            guard let metadataRevision = trimmedNonEmpty(metadataRevision) else { continue }

            guard let supportRaw = jsonString(value["support"]),
                  let support = CapabilityEvidenceFacade.Support(rawValue: supportRaw),
                  let sourceRaw = jsonString(value["source"]),
                  let source = CapabilityEvidenceFacade.Source(rawValue: sourceRaw),
                  let gradeRaw = jsonString(value["grade"]),
                  let grade = CapabilityEvidenceFacade.Grade(rawValue: gradeRaw),
                  let scope = resolvedLeanIdentity(
                    value["scope"], expected: CapabilityEvidenceFacade.Scope.providerModelTransport.rawValue,
                    fallbackAllowed: allowsLeanIdentityFallback
                  ).flatMap(CapabilityEvidenceFacade.Scope.init(rawValue:)),
                  resolvedLeanIdentity(
                    value["providerKind"], expected: treeProviderKind,
                    fallbackAllowed: allowsLeanIdentityFallback
                  ) != nil,
                  resolvedLeanIdentity(
                    value["modelId"], expected: treeModelID,
                    fallbackAllowed: allowsLeanIdentityFallback
                  ) != nil,
                  resolvedLeanIdentity(
                    value["transport"], expected: treeTransport,
                    fallbackAllowed: allowsLeanIdentityFallback
                  ) != nil,
                  isAllowedPublicEvidenceShape(source: source, grade: grade, scope: scope) else {
                continue
            }

            let generationRevision = trimmedNonEmpty(jsonString(value["generationRevision"]))
            if key.hasPrefix("generation_parameter/"), generationRevision == nil { continue }
            let observedAt = jsonPositiveInt64(value["observedAt"])
            let expiresAt = jsonPositiveInt64(value["expiresAt"])
            if (value["observedAt"] != nil && observedAt == nil)
                || (value["expiresAt"] != nil && expiresAt == nil) {
                continue
            }
            if source == .serverTyped {
                guard let observedAt, let expiresAt, expiresAt > observedAt else { continue }
            }
            candidates.append(CapabilityEvidenceFacade.Candidate(
                key: key,
                support: support,
                source: source,
                grade: grade,
                scope: scope,
                providerKind: projectedProviderKind,
                modelID: treeModelID,
                transport: treeTransport,
                metadataRevision: metadataRevision,
                generationRevision: generationRevision,
                observedAt: observedAt,
                expiresAt: expiresAt
            ))
        }
        return CapabilityEvidenceViewProjection(
            namespacePresent: true, candidates: candidates, ownedKeys: ownedKeys, malformed: false
        )
    }

    nonisolated private static func resolvedLeanIdentity(
        _ raw: JSONValue?,
        expected: String,
        fallbackAllowed: Bool
    ) -> String? {
        if let raw {
            guard case .string(let value) = raw, value == expected else { return nil }
            return value
        }
        return fallbackAllowed ? expected : nil
    }

    nonisolated private static func jsonString(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    nonisolated private static func jsonPositiveInt64(_ value: JSONValue?) -> Int64? {
        guard case .number(let number)? = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number > 0, number <= Double(Int64.max) else { return nil }
        return Int64(number)
    }

    nonisolated private static func isSafeCapabilityEvidenceKey(_ key: String) -> Bool {
        if key == "tool_call" || key == "web_search" || key == "vision_input" { return true }
        let prefixes = ["generation_parameter/", "reasoning_level/"]
        guard let prefix = prefixes.first(where: key.hasPrefix) else { return false }
        let suffix = key.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.count <= 64 else { return false }
        return suffix.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    nonisolated private static func isAllowedPublicEvidenceShape(
        source: CapabilityEvidenceFacade.Source,
        grade: CapabilityEvidenceFacade.Grade,
        scope: CapabilityEvidenceFacade.Scope
    ) -> Bool {
        guard scope == .providerModelTransport else { return false }
        switch source {
        case .serverTyped:
            return grade == .machineVerified
        case .serverProfile:
            return grade == .effectVerified || grade == .declared
        case .operatorOverride:
            return grade == .operator
        default:
            return false
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizePricingStatus(
        _ model: ModelMetadataEntry,
        pricing: ModelPricing?,
        pricingUnit: String
    ) -> String {
        if let status = model.pricingStatus,
           status == "priced" || status == "free" || status == "unknown" {
            return status
        }

        if pricingUnit != "per_token" {
            if let cost = pricing?.costPerUnit {
                return cost > 0 ? "priced" : "free"
            }
            return "unknown"
        }

        if let pricing,
           (pricing.promptPerMToken ?? 0) > 0 || (pricing.completionPerMToken ?? 0) > 0 {
            return "priced"
        }

        if let pricing,
           (pricing.promptPerMToken ?? 0) == 0 && (pricing.completionPerMToken ?? 0) == 0 {
            return "free"
        }

        return "unknown"
    }

    private static func normalizePricingUnit(_ value: String?) -> String {
        trimmedNonEmpty(value) ?? "per_token"
    }

    private static func normalizeSourceSummary(_ summary: ModelSourceSummary?) -> ModelSourceSummary? {
        guard let sourceKind = trimmedNonEmpty(summary?.sourceKind),
              let sourceName = trimmedNonEmpty(summary?.sourceName) else {
            return nil
        }

        return ModelSourceSummary(
            sourceKind: sourceKind,
            sourceName: sourceName,
            fetchedAt: summary?.fetchedAt ?? ""
        )
    }

    private static func normalizeCapabilities(_ rawCapabilities: [String]?, badgeOrder: [String]?) -> [ModelCapability] {
        guard let rawCapabilities, !rawCapabilities.isEmpty else { return [] }

        let mapped = rawCapabilities.compactMap { raw -> ModelCapability? in
            guard Self.validCapabilities.contains(raw) else { return nil }
            return ModelCapability(rawValue: raw)
        }

        guard let badgeOrder, !badgeOrder.isEmpty else { return mapped }

        let hasText = mapped.contains(.text)
        let nonText = mapped.filter { $0 != .text }
        let sorted = nonText.sorted { lhs, rhs in
            let lhsIndex = badgeOrder.firstIndex(of: lhs.rawValue) ?? Int.max
            let rhsIndex = badgeOrder.firstIndex(of: rhs.rawValue) ?? Int.max
            return lhsIndex < rhsIndex
        }

        return hasText ? [.text] + sorted : sorted
    }

    private static func supportedReasoningModes(
        profileName: String?,
        in table: MetadataResponse?
    ) -> [ReasoningMode] {
        guard let profileName = profileName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !profileName.isEmpty else {
            return ReasoningMode.allCases
        }

        guard let levels = table?.profiles?.reasoning?[profileName]?.levels,
              !levels.isEmpty else {
            return [.automatic]
        }

        let supported = nonAutomaticReasoningModes.filter { mode in
            levels.contains(mode.rawValue) || mode.intentToken.map(levels.contains) == true
        }
        guard !supported.isEmpty else { return [.automatic] }
        return [.automatic] + supported
    }

    private static func declaredReasoningDefaultLevel(
        profileName: String?,
        in table: MetadataResponse?
    ) -> ReasoningMode? {
        guard let profileName = profileName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !profileName.isEmpty,
              let definition = table?.profiles?.reasoning?[profileName],
              let raw = definition.defaultLevel?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let mode = ReasoningMode.fromIntent(raw),
              let levels = definition.levels,
              levels.contains(raw) || levels.contains(mode.rawValue)
                || mode.intentToken.map(levels.contains) == true else { return nil }
        return mode
    }

    private static func clampReasoningMode(
        _ mode: ReasoningMode,
        profileName: String?,
        in table: MetadataResponse?
    ) -> ReasoningMode {
        let supported = supportedReasoningModes(profileName: profileName, in: table)
        if supported.contains(mode) {
            return mode
        }

        guard let modeIndex = ReasoningMode.allCases.firstIndex(of: mode) else {
            return .automatic
        }

        for candidate in ReasoningMode.allCases[..<modeIndex].reversed() where supported.contains(candidate) {
            return candidate
        }

        return .automatic
    }

    private static func lookupCandidates(for modelID: String) -> [String] {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let normalized = snapshotDatePatterns.reduce(trimmed) { partialResult, pattern in
            partialResult.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        return normalized == trimmed ? [trimmed] : [trimmed, normalized]
    }

    private func fetchMetadata(boundUID requestedUID: String, bypassETag: Bool = false) async {
        #if DEBUG
        if AppRuntime.isRunningTests
            && !allowsNetworkRequestsInTests
            && !Self.allowNetworkRequestsForTesting {
            return
        }
        #endif
        do {
            let resolvedURL = BackendURLResolver.resolve()
            guard !resolvedURL.isEmpty else { return }
            let urlString = "\(resolvedURL)/api/metadata?view=lean"
            AppLog.info("Fetching metadata from \(urlString)", module: "Metadata")
            guard let url = URL(string: urlString) else {
                AppLog.warning("Metadata endpoint is not a valid URL, skipping the fetch", module: "Metadata")
                return
            }

            var request = URLRequest(url: url)
            if !bypassETag, boundUID == requestedUID, let etag = storedETag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await dataForBackendRequest(request)
            guard let httpRes = response as? HTTPURLResponse else { return }
            AppLog.info("Metadata response: status=\(httpRes.statusCode) bytes=\(data.count)", module: "Metadata")
            if httpRes.statusCode == 304 {
                if AppSessionStore.activeUID == requestedUID, boundUID == requestedUID {
                    Self.snapshotConfirmedThisSession = true
                }
                return
            }
            guard httpRes.statusCode == 200 else { return }

            let responseETag = httpRes.value(forHTTPHeaderField: "Etag")

            let rawDecoded: MetadataResponse
            do {
                rawDecoded = try decodeMetadataResponse(from: data)
                AppLog.info(
                    "Decoded metadata for providers: \(rawDecoded.providers.keys.sorted().joined(separator: ", "))",
                    module: "Metadata"
                )
            } catch {
                reportMetadataDecodingFailure(
                    source: .network,
                    byteCount: data.count,
                    statusCode: httpRes.statusCode
                )
                throw error
            }
            let decoded = Self.sanitizedMetadataResponse(
                Self.preservingModelFactsForLean(rawDecoded, from: table)
            )
            persistCache(decoded, etag: responseETag, boundUID: requestedUID)
            guard AppSessionStore.activeUID == requestedUID, boundUID == requestedUID else { return }
            replaceTable(decoded)
            replaceStoredETag(responseETag)
            Self.replaceSharedState(snapshot: decoded, etag: responseETag)
            await publishCapabilityEvidenceContent(snapshot: decoded, etag: responseETag)
            Self.snapshotConfirmedThisSession = true
            Self.syncSelfHealPatternsToClassifier()
        } catch {
            AppLog.error(error, module: "Metadata", context: ["op": "fetch"])
        }
    }

    private func dataForBackendRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    private func decodeMetadataResponse(from data: Data) throws -> MetadataResponse {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(WrappedResponse.self, from: data).data
        } catch {
            guard let direct = try? decoder.decode(MetadataResponse.self, from: data) else {
                throw MetadataPayloadDecodeSentinel()
            }
            return direct
        }
    }

    private func fetchModelFacts() async {
        let requestedUID = AppSessionStore.activeUID
        guard boundUID == requestedUID else { return }
        do {
            let resolvedURL = BackendURLResolver.resolve()
            guard !resolvedURL.isEmpty,
                  let url = URL(string: "\(resolvedURL)/api/metadata/model-facts") else { return }
            var request = URLRequest(url: url)
            if let etag = storedModelFactsETag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            let (data, response) = try await dataForBackendRequest(request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 304 { return }
            if http.statusCode == 404 {
                storedModelFactsETag = nil
                UserDefaults.standard.removeObject(forKey: modelFactsETagKey(for: requestedUID))
                guard AppSessionStore.activeUID == requestedUID,
                      boundUID == requestedUID,
                      let current = table else { return }
                let withdrawn = Self.removingModelFacts(from: current)
                replaceTable(withdrawn)
                Self.replaceSharedState(snapshot: withdrawn, etag: storedETag)
                persistCache(withdrawn, etag: storedETag, boundUID: requestedUID)
                return
            }
            guard http.statusCode == 200 else { return }
            let payload = try JSONDecoder().decode(WrappedModelFactsResponse.self, from: data).data
            guard AppSessionStore.activeUID == requestedUID,
                  boundUID == requestedUID,
                  let current = table else { return }
            let merged = Self.replacingModelFacts(
                in: current,
                facts: payload.facts,
                revision: payload.revision
            )
            replaceTable(merged)
            Self.replaceSharedState(snapshot: merged, etag: storedETag)
            let responseETag = http.value(forHTTPHeaderField: "Etag")
            storedModelFactsETag = responseETag
            UserDefaults.standard.set(responseETag, forKey: modelFactsETagKey(for: requestedUID))
            persistCache(merged, etag: storedETag, boundUID: requestedUID)
        } catch {
            errorReporter(error, ["operation": "model_facts_fetch"])
        }
    }

    private func reportMetadataDecodingFailure(
        source: MetadataDecodeSource,
        byteCount: Int,
        statusCode: Int? = nil
    ) {
        var tags = [
            "operation": "decode",
            "source": source.rawValue,
            "byte_count": String(byteCount),
        ]
        if let statusCode {
            tags["http_status"] = String(statusCode)
        }
        errorReporter(MetadataPayloadDecodeSentinel(), tags)
    }

    private func publishCapabilityEvidenceContent(snapshot: MetadataResponse, etag: String?) async {
        let expiries = Self.capabilityEvidenceExpiries(in: snapshot, metadataRevision: etag)
        await CapabilityEvidenceObservationBridge.shared.publishContent(candidateExpiries: expiries)
    }

    nonisolated private static func capabilityEvidenceExpiries(
        in snapshot: MetadataResponse,
        metadataRevision: String?
    ) -> [Int64] {
        snapshot.providers.flatMap { backendProviderKind, provider in
            let projectedProviderKind = kindMap.first(where: { $0.value == backendProviderKind })?.key
                ?? backendProviderKind
            return provider.models.flatMap { mapModelID, model in
                normalizeCapabilityEvidenceView(
                    model.capabilityEvidenceView,
                    namespacePresent: model.$capabilityEvidenceView.isPresent,
                    metadataRevision: metadataRevision,
                    allowsLeanIdentityFallback: snapshot.view == "lean",
                    treeProviderKind: backendProviderKind,
                    projectedProviderKind: projectedProviderKind,
                    treeModelID: model.canonicalModelId ?? mapModelID,
                    treeTransport: model.transport
                ).candidates.compactMap(\.expiresAt)
            }
        }
    }

    private func replaceStoredETag(_ etag: String?) {
        storedETag = etag
    }

    nonisolated private static func sanitizedMetadataResponse(
        _ response: MetadataResponse
    ) -> MetadataResponse {
        let providers = response.providers.mapValues { provider in
            let models = provider.models.mapValues { model in
                guard model.$capabilityEvidenceView.isPresent else { return model }
                var safeModel = model
                safeModel.capabilityEvidenceView = sanitizedCapabilityEvidenceRaw(
                    model.capabilityEvidenceView ?? .null,
                    allowsSchemaOmission: response.view == "lean"
                )
                return safeModel
            }
            return ProviderData(
                displayName: provider.displayName,
                attachmentSupport: provider.attachmentSupport,
                defaultModelId: provider.defaultModelId,
                validation: provider.validation,
                resolveMap: provider.resolveMap,
                models: models,
                transport: provider.transport
            )
        }
        return MetadataResponse(
            version: response.version,
            view: response.view,
            contractVersion: response.contractVersion,
            capabilityContractVersion: response.capabilityContractVersion,
            updatedAt: response.updatedAt,
            profiles: response.profiles,
            generationParameterTables: response.generationParameterTables,
            providers: providers,
            providerConfigs: response.providerConfigs,
            relayRuntimeConfig: response.relayRuntimeConfig,
            runtimeConfig: response.runtimeConfig,
            libraryRuntimeConfig: response.libraryRuntimeConfig,
            capabilityRuntime: response.capabilityRuntime,
            modelFacts: response.modelFacts,
            modelFactsRevision: response.modelFactsRevision
        )
    }

    nonisolated private static func preservingModelFactsForLean(
        _ response: MetadataResponse,
        from previous: MetadataResponse?
    ) -> MetadataResponse {
        guard response.view == "lean", response.modelFacts == nil,
              let facts = previous?.modelFacts,
              let revision = previous?.modelFactsRevision else { return response }
        return replacingModelFacts(in: response, facts: facts, revision: revision)
    }

    nonisolated private static func replacingModelFacts(
        in response: MetadataResponse,
        facts: [String: ModelFacts],
        revision: String
    ) -> MetadataResponse {
        MetadataResponse(
            version: response.version,
            view: response.view,
            contractVersion: response.contractVersion,
            capabilityContractVersion: response.capabilityContractVersion,
            updatedAt: response.updatedAt,
            profiles: response.profiles,
            generationParameterTables: response.generationParameterTables,
            providers: response.providers,
            providerConfigs: response.providerConfigs,
            relayRuntimeConfig: response.relayRuntimeConfig,
            runtimeConfig: response.runtimeConfig,
            libraryRuntimeConfig: response.libraryRuntimeConfig,
            capabilityRuntime: response.capabilityRuntime,
            modelFacts: facts,
            modelFactsRevision: revision
        )
    }

    nonisolated private static func removingModelFacts(
        from response: MetadataResponse
    ) -> MetadataResponse {
        MetadataResponse(
            version: response.version,
            view: response.view,
            contractVersion: response.contractVersion,
            capabilityContractVersion: response.capabilityContractVersion,
            updatedAt: response.updatedAt,
            profiles: response.profiles,
            generationParameterTables: response.generationParameterTables,
            providers: response.providers,
            providerConfigs: response.providerConfigs,
            relayRuntimeConfig: response.relayRuntimeConfig,
            runtimeConfig: response.runtimeConfig,
            libraryRuntimeConfig: response.libraryRuntimeConfig,
            capabilityRuntime: response.capabilityRuntime,
            modelFacts: nil,
            modelFactsRevision: nil
        )
    }

    nonisolated private static func sanitizedCapabilityEvidenceRaw(
        _ raw: JSONValue,
        allowsSchemaOmission: Bool
    ) -> JSONValue {
        guard case .object(let namespace) = raw,
              case .array(let rawCandidates)? = namespace["candidates"] else {
            if case .null = raw { return .null }
            return .object(["schema": .string("malformed")])
        }
        let schema: JSONValue?
        if let rawSchema = namespace["schema"] {
            guard case .string("capability-evidence-view/v1") = rawSchema else {
                return .object(["schema": .string("malformed")])
            }
            schema = rawSchema
        } else {
            guard allowsSchemaOmission else {
                return .object(["schema": .string("malformed")])
            }
            schema = nil
        }

        let safeStringFields: Set<String> = [
            "key", "support", "source", "grade", "scope", "providerKind", "modelId",
            "transport", "generationRevision",
        ]
        let safeNumberFields: Set<String> = ["observedAt", "expiresAt"]
        let candidates = rawCandidates.compactMap { candidate -> JSONValue? in
            guard case .object(let fields) = candidate,
                  case .string(let key)? = fields["key"],
                  isSafeCapabilityEvidenceKey(key) else { return nil }
            var safe: [String: JSONValue] = ["key": .string(key)]
            for field in safeStringFields where field != "key" {
                if case .string(let value)? = fields[field] {
                    safe[field] = .string(value)
                }
            }
            for field in safeNumberFields {
                if case .number(let value)? = fields[field], value.isFinite {
                    safe[field] = .number(value)
                }
            }
            return .object(safe)
        }
        var sanitized: [String: JSONValue] = ["candidates": .array(candidates)]
        if let schema { sanitized["schema"] = schema }
        return .object(sanitized)
    }

    private func persistCache(
        _ data: MetadataResponse,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        etag: String?,
        boundUID requestedUID: String
    ) {
        let safeData = Self.sanitizedMetadataResponse(data)
        let entry = CacheEntry(data: safeData, timestamp: timestamp)
        if persistToGRDB(entry: entry, etag: etag, boundUID: requestedUID) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: cacheKey)
            defaults.removeObject(forKey: etagKey)
            defaults.set(
                Self.currentCacheStorageFormatVersion,
                forKey: cacheStorageFormatVersionKey(for: requestedUID)
            )
        }
    }


    private struct PersistedCacheEntry {
        let data: MetadataResponse
        let etag: String?
        let timestamp: TimeInterval
        let requiresStorageMigration: Bool
    }

    private func loadPersistedCache(boundUID requestedUID: String) -> PersistedCacheEntry? {
        do {
            let pool = try DatabaseManager.shared.openIfNeeded(for: requestedUID)
            let stored = try pool.read { db -> (payload: String, contractVersion: Int, etag: String?, timestamp: Double)? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT payload, version, contractVersion, etag, updatedAt FROM metadata_cache WHERE id = 1"
                ) else { return nil }
                return (row["payload"], row["contractVersion"], row["etag"], row["updatedAt"])
            }
            guard let stored else { return nil }

            guard stored.contractVersion <= Self.supportedContractVersion + 1 else { return nil }
            guard let jsonData = stored.payload.data(using: .utf8) else { return nil }

            let decoded: MetadataResponse
            do {
                decoded = try JSONDecoder().decode(MetadataResponse.self, from: jsonData)
            } catch {
                reportMetadataDecodingFailure(source: .grdb, byteCount: jsonData.count)
                return nil
            }

            guard decoded.view == "lean" else { return nil }

            return PersistedCacheEntry(
                data: Self.sanitizedMetadataResponse(decoded),
                etag: stored.etag,
                timestamp: stored.timestamp,
                requiresStorageMigration: UserDefaults.standard.integer(
                    forKey: cacheStorageFormatVersionKey(for: requestedUID)
                ) < Self.currentCacheStorageFormatVersion
            )
        } catch {
            return nil
        }
    }

    private func loadLegacyUserDefaultsCache() -> CacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        do {
            return try JSONDecoder().decode(CacheEntry.self, from: data)
        } catch {
            reportMetadataDecodingFailure(source: .userDefaults, byteCount: data.count)
            return nil
        }
    }

    @discardableResult
    private func persistToGRDB(entry: CacheEntry, etag: String?, boundUID requestedUID: String) -> Bool {
        do {
            let pool = try DatabaseManager.shared.openIfNeeded(for: requestedUID)
            let payloadData = try JSONEncoder().encode(entry.data)
            guard let payloadString = String(data: payloadData, encoding: .utf8) else { return false }

            try pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO metadata_cache (id, payload, version, contractVersion, etag, updatedAt)
                    VALUES (1, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        version = excluded.version,
                        contractVersion = excluded.contractVersion,
                        etag = excluded.etag,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        payloadString,
                        entry.data.version,
                        entry.data.contractVersion ?? 0,
                        etag,
                        entry.timestamp,
                    ]
                )
            }
            #if DEBUG
            grdbPersistCountForTesting += 1
            #endif
            return true
        } catch {
            return false
        }
    }
}

extension MetadataClient.LibraryRuntimeConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.fallback
        self.init(
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? fallback.version,
            toolDescriptions: try container.decodeIfPresent(
                [String: String].self,
                forKey: .toolDescriptions
            ) ?? fallback.toolDescriptions,
            maxSteps: try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? fallback.maxSteps,
            toolTimeoutMs: try container.decodeIfPresent(
                Int.self,
                forKey: .toolTimeoutMs
            ) ?? fallback.toolTimeoutMs,
            maxEmptyHits: try container.decodeIfPresent(
                Int.self,
                forKey: .maxEmptyHits
            ) ?? fallback.maxEmptyHits,
            maxSelfCorrections: try container.decodeIfPresent(
                Int.self,
                forKey: .maxSelfCorrections
            ) ?? fallback.maxSelfCorrections,
            tokenBudget: try container.decodeIfPresent(
                Int.self,
                forKey: .tokenBudget
            ) ?? fallback.tokenBudget,
            estimatedTokensPerStep: try container.decodeIfPresent(
                Int.self,
                forKey: .estimatedTokensPerStep
            ) ?? fallback.estimatedTokensPerStep,
            highCostConfirmationUSD: try container.decodeIfPresent(
                Double.self,
                forKey: .highCostConfirmationUSD
            ) ?? fallback.highCostConfirmationUSD,
            weakModelDenylist: try container.decodeIfPresent(
                [String].self,
                forKey: .weakModelDenylist
            ) ?? fallback.weakModelDenylist,
            sensitiveGateEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .sensitiveGateEnabled
            ) ?? fallback.sensitiveGateEnabled,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled),
            availableProviders: try container.decodeIfPresent(
                [String].self,
                forKey: .availableProviders
            ),
            directMaxDocuments: try container.decodeIfPresent(Int.self, forKey: .directMaxDocuments),
            directContextMaxChars: try container.decodeIfPresent(
                Int.self,
                forKey: .directContextMaxChars
            ),
            serverResearchEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .serverResearchEnabled
            ),
            serverResearchProviderDenylist: try container.decodeIfPresent(
                [String].self,
                forKey: .serverResearchProviderDenylist
            ),
            serverResearchMaxDocuments: try container.decodeIfPresent(
                Int.self,
                forKey: .serverResearchMaxDocuments
            )
        )
    }
}

extension MetadataClient {
    func estimateCost(
        modelID: String,
        providerKind: ProviderKind,
        promptTokens: Int,
        completionTokens: Int
    ) -> Double {
        guard let metadata = resolveCatalogModel(modelID: modelID, providerKind: providerKind) else {
            return 0
        }
        if metadata.pricingStatus == "free" || metadata.pricingStatus == "unknown" {
            return 0
        }
        if metadata.pricingUnit != "per_token" {
            return metadata.costPerUnit ?? 0
        }
        guard let promptPrice = metadata.promptPerToken,
              let completionPrice = metadata.completionPerToken else { return 0 }
        return promptPrice * Double(promptTokens)
             + completionPrice * Double(completionTokens)
    }

    func calcCost(
        breakdown: UsageBreakdown,
        modelID: String,
        providerKind: ProviderKind
    ) -> (cost: Double, source: CostSource) {
        let metadata = resolveCatalogModel(modelID: modelID, providerKind: providerKind)
        return CostCalculator.calcCost(breakdown: breakdown, pricing: metadata)
    }
}

extension KeyedDecodingContainer {
    func decode(
        _ type: MetadataClient.CapabilityEvidenceRawField.Type,
        forKey key: Key
    ) throws -> MetadataClient.CapabilityEvidenceRawField {
        guard contains(key) else { return .init(wrappedValue: nil) }
        if try decodeNil(forKey: key) { return .init(presentValue: .null) }
        return try .init(from: superDecoder(forKey: key))
    }
}

extension KeyedEncodingContainer {
    mutating func encode(
        _ value: MetadataClient.CapabilityEvidenceRawField,
        forKey key: Key
    ) throws {
        guard value.isPresent else { return }
        try value.encode(to: superEncoder(forKey: key))
    }
}

#if DEBUG
extension MetadataClient {
    nonisolated(unsafe) static var allowNetworkRequestsForTesting = false

    func replaceStoredETagForTesting(_ etag: String?) {
        boundUID = AppSessionStore.activeUID
        replaceStoredETag(etag)
        Self.replaceSharedState(snapshot: nil, etag: etag)
    }

    func resetForTesting() async {
        let requestedUID = AppSessionStore.activeUID
        replaceTable(nil)
        Self.replaceSharedState(snapshot: nil, etag: nil)
        await CapabilityEvidenceObservationBridge.shared.resetForTesting()
        Self.snapshotConfirmedThisSession = false
        Self.syncSelfHealPatternsToClassifier()
        storedETag = nil
        storedModelFactsETag = nil
        boundUID = nil
        bootstrappedUID = nil
        initialization?.task.cancel()
        initialization = nil
        lastLibrarySettingsRefreshAtByUID.removeAll()
        grdbPersistCountForTesting = 0
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: etagKey)
        UserDefaults.standard.removeObject(forKey: modelFactsETagKey(for: requestedUID))
        UserDefaults.standard.removeObject(forKey: cacheStorageFormatVersionKey(for: requestedUID))
        if let pool = try? DatabaseManager.shared.openIfNeeded(for: requestedUID) {
            try? await pool.write { db in
                try? db.execute(sql: "DELETE FROM metadata_cache")
            }
        }
    }

    func loadForTesting(json: String, metadataETag: String? = nil) async throws {
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: Data(json.utf8))
        let requestedUID = AppSessionStore.activeUID
        replaceTable(decoded)
        boundUID = requestedUID
        storedETag = metadataETag
        Self.replaceSharedState(snapshot: decoded, etag: metadataETag)
        await publishCapabilityEvidenceContent(snapshot: decoded, etag: metadataETag)
        Self.snapshotConfirmedThisSession = true
        Self.syncSelfHealPatternsToClassifier()
        bootstrappedUID = requestedUID
    }

    func writePersistedCacheForTesting(
        payload: String,
        version: Int,
        contractVersion: Int,
        etag: String?,
        boundUID requestedUID: String? = nil
    ) throws {
        let requestedUID = requestedUID ?? AppSessionStore.activeUID
        let pool = try DatabaseManager.shared.openIfNeeded(for: requestedUID)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO metadata_cache (id, payload, version, contractVersion, etag, updatedAt)
                VALUES (1, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    payload = excluded.payload,
                    version = excluded.version,
                    contractVersion = excluded.contractVersion,
                    etag = excluded.etag,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [payload, version, contractVersion, etag, Date().timeIntervalSince1970]
            )
        }
    }

    func markPersistedCacheAsCurrentFormatForTesting(boundUID requestedUID: String? = nil) {
        let requestedUID = requestedUID ?? AppSessionStore.activeUID
        UserDefaults.standard.set(
            Self.currentCacheStorageFormatVersion,
            forKey: cacheStorageFormatVersionKey(for: requestedUID)
        )
    }

    func grdbPersistCountSnapshotForTesting() -> Int {
        grdbPersistCountForTesting
    }

    func legacyUserDefaultsPayloadExistsForTesting() -> Bool {
        UserDefaults.standard.data(forKey: cacheKey) != nil
    }

    func writeLegacyUserDefaultsCacheForTesting(
        json: String,
        timestamp: TimeInterval,
        etag: String?,
        boundUID requestedUID: String? = nil
    ) throws {
        let requestedUID = requestedUID ?? AppSessionStore.activeUID
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(CacheEntry(data: decoded, timestamp: timestamp))
        UserDefaults.standard.set(encoded, forKey: cacheKey)
        UserDefaults.standard.set(etag, forKey: etagKey)
        UserDefaults.standard.removeObject(forKey: cacheStorageFormatVersionKey(for: requestedUID))
    }

    func readPersistedCacheForTesting(
        boundUID requestedUID: String? = nil
    ) -> (version: Int, contractVersion: Int, etag: String?)? {
        guard let entry = loadPersistedCache(boundUID: requestedUID ?? AppSessionStore.activeUID) else { return nil }
        return (entry.data.version, entry.data.contractVersion ?? 0, entry.etag)
    }

    func persistSanitizedCacheForTesting(
        json: String,
        etag: String?,
        boundUID requestedUID: String? = nil
    ) throws -> (userDefaultsPayload: String?, grdbPayload: String?) {
        let requestedUID = requestedUID ?? AppSessionStore.activeUID
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: Data(json.utf8))
        persistCache(decoded, etag: etag, boundUID: requestedUID)
        let userDefaultsPayload = UserDefaults.standard.data(forKey: cacheKey)
            .flatMap { String(data: $0, encoding: .utf8) }
        let pool = try DatabaseManager.shared.openIfNeeded(for: requestedUID)
        let grdbPayload = try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payload FROM metadata_cache WHERE id = 1"
            )
        }
        return (userDefaultsPayload, grdbPayload)
    }
}
#endif
