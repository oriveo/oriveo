import Foundation

/// The resolved image capability of one model (`shared/model-contracts/image_profile.v2.json`).
/// The Server is the only authority; clients never guess capability from a model id or provider
/// kind. Unknown fields are ignored; unknown enum values make the whole profile unusable, which
/// `ImageProfileResolver.validate` checks before this type is ever built.
struct ImageProfile: Decodable, Equatable, Sendable {
    enum Operation: String, CaseIterable, Codable, Sendable {
        case generate
        case edit
    }

    enum Route: String, CaseIterable, Codable, Sendable {
        case openaiImages = "openai_images"
        case xaiImages = "xai_images"
        case geminiGenerateContent = "gemini_generate_content"
        case chatModalities = "chat_modalities"
        case openrouterImages = "openrouter_images"
        case dashscopeMultimodal = "dashscope_multimodal"
        case minimaxImageGeneration = "minimax_image_generation"

        /// `routes[route].allowedEditTransports` in image_profile.v2.
        var allowedEditTransports: [EditTransport] {
            switch self {
            case .openaiImages: return [.multipart, .jsonImage, .jsonImageUrl]
            case .xaiImages: return [.jsonImageObject]
            case .geminiGenerateContent: return [.inline]
            case .chatModalities: return [.inline]
            case .openrouterImages: return [.inputReferences]
            case .dashscopeMultimodal: return [.inline]
            case .minimaxImageGeneration: return []
            }
        }

        /// `routes[route].allowedSizeParams` in image_profile.v2.
        var allowedSizeParams: [SizeParam] {
            switch self {
            case .openaiImages: return [.wxh]
            case .xaiImages: return [.aspectResolution]
            case .geminiGenerateContent: return [.geminiImageConfig]
            case .chatModalities: return [.chatImageConfig]
            case .openrouterImages: return [.wxh]
            case .dashscopeMultimodal: return [.dashscopeWxh]
            case .minimaxImageGeneration: return [.aspectOnly]
            }
        }
    }

    enum EditTransport: String, CaseIterable, Codable, Sendable {
        case multipart
        case jsonImage = "json_image"
        case jsonImageUrl = "json_image_url"
        case jsonImageObject = "json_image_object"
        case inputReferences = "input_references"
        case inline
    }

    enum SizeParam: String, CaseIterable, Codable, Sendable {
        case wxh
        case aspectResolution = "aspect_resolution"
        case geminiImageConfig = "gemini_image_config"
        case dashscopeWxh = "dashscope_wxh"
        case chatImageConfig = "chat_image_config"
        case aspectOnly = "aspect_only"
    }

    enum QualityTier: String, CaseIterable, Codable, Sendable {
        case draft
        case standard
        case fine
    }

    enum ResolutionTier: String, CaseIterable, Codable, Sendable {
        case oneK = "1K"
        case twoK = "2K"
        case fourK = "4K"
    }

    enum Source: String, CaseIterable, Codable, Sendable {
        case officialApi = "official_api"
        case verifiedAllowlist = "verified_allowlist"
        case modelsDev = "models_dev"
        case openrouter
        case relayProbe = "relay_probe"
        case userDeclared = "user_declared"
        case managedCatalog = "managed_catalog"
    }

    enum PricingUnit: String, CaseIterable, Codable, Sendable {
        case perImage = "per_image"
    }

    /// Read per sub-field: a pixel sub-field that is not a positive integer is absent, and a bad
    /// sub-field never drops the whole object (contract card U4a item 6).
    struct SizeConstraints: Decodable, Equatable, Sendable {
        var multipleOf: Int?
        var minPixels: Int?
        var maxPixels: Int?
        var maxLongEdge: Int?
        var ratioRange: [Double]?

        init(multipleOf: Int? = nil, minPixels: Int? = nil, maxPixels: Int? = nil, maxLongEdge: Int? = nil, ratioRange: [Double]? = nil) {
            self.multipleOf = multipleOf
            self.minPixels = minPixels
            self.maxPixels = maxPixels
            self.maxLongEdge = maxLongEdge
            self.ratioRange = ratioRange
        }

        private enum CodingKeys: String, CodingKey {
            case multipleOf, minPixels, maxPixels, maxLongEdge, ratioRange
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func positive(_ key: CodingKeys) -> Int? {
                ImageProfileResolver.positiveInteger((try? container.decodeIfPresent(MetadataClient.JSONValue.self, forKey: key)) ?? nil)
            }
            multipleOf = positive(.multipleOf)
            minPixels = positive(.minPixels)
            maxPixels = positive(.maxPixels)
            maxLongEdge = positive(.maxLongEdge)
            ratioRange = (try? container.decodeIfPresent([Double].self, forKey: .ratioRange)) ?? nil
        }
    }

    struct Pricing: Decodable, Equatable, Sendable {
        var unit: String?
        var currency: String?
        /// Resolution tier -> quality tier -> price.
        var byResolution: [String: [String: Double]]?
        var source: String?
    }

    /// `fields.required` in image_profile.v2; any of them missing or null fails closed.
    static let requiredFields = [
        "imageOutput",
        "operations",
        "route",
        "aspectRatios",
        "sizeParam",
        "resolutions",
        "maxNPerCall",
        "timeoutSeconds",
        "source",
    ]

    var imageOutput: Bool
    var operations: [Operation]
    var route: Route
    var editTransport: EditTransport?
    var maxReferenceImages: Int?
    var aspectRatios: [String]
    var sizeParam: SizeParam
    /// Resolution tier -> long edge in pixels.
    var resolutions: [String: Int]
    var sizeConstraints: SizeConstraints?
    /// Resolution tier -> wire string.
    var resolutionValues: [String: String]?
    /// Quality tier -> wire value; a missing tier is never sent.
    var qualityMap: [String: String]?
    var maxNPerCall: Int
    var nParam: Bool?
    var params: [String: Bool?]?
    var nativeMultiTurn: Bool?
    var timeoutSeconds: Int
    var typicalSeconds: [Double]?
    var maxPromptChars: Int?
    var pricing: Pricing?
    var source: Source
    var verifiedAt: String?

    /// Required fields decode strictly; an optional field of the wrong JSON type is dropped as absent
    /// and the profile stays usable (contract card U3b item 1).
    private enum CodingKeys: String, CodingKey {
        case imageOutput, operations, route, editTransport, maxReferenceImages, aspectRatios, sizeParam
        case resolutions, sizeConstraints, resolutionValues, qualityMap, maxNPerCall, nParam, params
        case nativeMultiTurn, timeoutSeconds, typicalSeconds, maxPromptChars, pricing, source, verifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        imageOutput = try container.decode(Bool.self, forKey: .imageOutput)
        operations = try container.decode([Operation].self, forKey: .operations)
        route = try container.decode(Route.self, forKey: .route)
        editTransport = optional(EditTransport.self, .editTransport)
        maxReferenceImages = optional(Int.self, .maxReferenceImages)
        aspectRatios = try container.decode([String].self, forKey: .aspectRatios)
        sizeParam = try container.decode(SizeParam.self, forKey: .sizeParam)
        resolutions = try container.decode([String: Int].self, forKey: .resolutions)
        sizeConstraints = optional(SizeConstraints.self, .sizeConstraints)
        resolutionValues = Self.stringEntries(optional(MetadataClient.JSONValue.self, .resolutionValues))
        qualityMap = Self.stringEntries(optional(MetadataClient.JSONValue.self, .qualityMap))
        maxNPerCall = try container.decode(Int.self, forKey: .maxNPerCall)
        nParam = optional(Bool.self, .nParam)
        params = Self.boolEntries(optional(MetadataClient.JSONValue.self, .params))
        nativeMultiTurn = optional(Bool.self, .nativeMultiTurn)
        timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
        typicalSeconds = optional([Double].self, .typicalSeconds)
        maxPromptChars = optional(Int.self, .maxPromptChars)
        pricing = optional(Pricing.self, .pricing)
        source = try container.decode(Source.self, forKey: .source)
        verifiedAt = optional(String.self, .verifiedAt)
    }

    /// A tier table read per entry: a non-object table is absent, and an entry that is not a
    /// non-empty string is a missing tier that never affects the others (contract card U4a item 7).
    private static func stringEntries(_ raw: MetadataClient.JSONValue?) -> [String: String]? {
        guard case .object(let object)? = raw else { return nil }
        var entries: [String: String] = [:]
        for (key, value) in object {
            if case .string(let text) = value, !text.isEmpty { entries[key] = text }
        }
        return entries
    }

    /// Capability flags read per entry: a non-object table is absent; true / false / null are kept
    /// and any other value counts as that entry missing, so one bad flag never drops the others.
    private static func boolEntries(_ raw: MetadataClient.JSONValue?) -> [String: Bool?]? {
        guard case .object(let object)? = raw else { return nil }
        var entries: [String: Bool?] = [:]
        for (key, value) in object {
            switch value {
            case .bool(let flag): entries[key] = .some(flag)
            case .null: entries[key] = .some(nil)
            default: continue
            }
        }
        return entries
    }
}

/// Resolves which ImageProfile applies to one model and whether it is listed in Studio.
/// Cases: `shared/model-contracts/image_profile_resolution.v1.json`, read by the iOS / Android /
/// Web contract tests alike. Pure functions, no UI entry point.
enum ImageProfileResolver {
    typealias JSONValue = MetadataClient.JSONValue

    /// Closed set of reasons a model has no usable profile, in fixture order.
    enum Reason: String, CaseIterable, Error, Sendable {
        case missingRequiredField = "missing_required_field"
        case noImageProfile = "no_image_profile"
        case danglingProfile = "dangling_profile"
        case modelNotInCatalog = "model_not_in_catalog"
        case unknownRoute = "unknown_route"
        case unknownEditTransport = "unknown_edit_transport"
        case unknownSizeParam = "unknown_size_param"
        case unknownOperation = "unknown_operation"
        case sizeParamNotAllowed = "size_param_not_allowed"
        case editTransportNotAllowed = "edit_transport_not_allowed"
        case editTransportWithoutEdit = "edit_transport_without_edit"
        case unknownSource = "unknown_source"
        case notImageOutput = "not_image_output"
        case relayUnmatched = "relay_unmatched"
        case probePendingConfirmation = "probe_pending_confirmation"
    }

    /// The metadata slice in wire shape: `profiles.image` plus `providers.<kind>.models` and
    /// `providers.<kind>.imageModels`, both keyed by wire model id. Decoding never fails on the shape
    /// of these fields: a non-object table / entry map is absent, a null entry is absent, a non-object
    /// entry is an entry without imageProfile (contract card U3b items 3 and 4).
    struct Slice: Decodable, Sendable {
        struct Profiles: Decodable, Sendable {
            var image: [String: JSONValue]?

            init(image: [String: JSONValue]?) {
                self.image = image
            }

            init(from decoder: Decoder) throws {
                guard case .object(let object) = try JSONValue(from: decoder),
                      case .object(let table)? = object["image"] else {
                    image = nil
                    return
                }
                image = table
            }
        }

        struct ModelEntry: Decodable, Sendable {
            var displayName: String?
            /// Only a string counts as a ref; any other JSON type is absent.
            var imageProfile: String?
            var imageProfileOverride: JSONValue?

            init(displayName: String?, imageProfile: String?, imageProfileOverride: JSONValue?) {
                self.displayName = displayName
                self.imageProfile = imageProfile
                self.imageProfileOverride = imageProfileOverride
            }

            /// A non-object entry is an entry without imageProfile.
            init(raw: JSONValue) {
                guard case .object(let object) = raw else {
                    self.init(displayName: nil, imageProfile: nil, imageProfileOverride: nil)
                    return
                }
                self.init(
                    displayName: ImageProfileResolver.string(object["displayName"]),
                    imageProfile: ImageProfileResolver.string(object["imageProfile"]),
                    imageProfileOverride: object["imageProfileOverride"]
                )
            }

            init(from decoder: Decoder) throws {
                self.init(raw: try JSONValue(from: decoder))
            }
        }

        struct Provider: Decodable, Sendable {
            var models: [String: ModelEntry]?
            var imageModels: [String: ModelEntry]?

            init(models: [String: ModelEntry]?, imageModels: [String: ModelEntry]?) {
                self.models = models
                self.imageModels = imageModels
            }

            /// A non-object provider has no entries, so every lookup is model_not_in_catalog.
            init(raw: JSONValue) {
                guard case .object(let object) = raw else {
                    self.init(models: nil, imageModels: nil)
                    return
                }
                self.init(models: Self.entries(object["models"]), imageModels: Self.entries(object["imageModels"]))
            }

            init(from decoder: Decoder) throws {
                self.init(raw: try JSONValue(from: decoder))
            }

            /// Raw `models` / `imageModels` map -> entries; a non-object map is absent and a null entry
            /// is dropped, so lookup falls through to `imageModels` as if the id were missing.
            static func entries(_ raw: JSONValue?) -> [String: ModelEntry]? {
                guard case .object(let object)? = raw else { return nil }
                var entries: [String: ModelEntry] = [:]
                for (id, value) in object {
                    if case .null = value { continue }
                    entries[id] = ModelEntry(raw: value)
                }
                return entries
            }
        }

        var profiles: Profiles?
        var providers: [String: Provider]?

        init(profiles: Profiles?, providers: [String: Provider]?) {
            self.profiles = profiles
            self.providers = providers
        }

        private enum CodingKeys: String, CodingKey {
            case profiles, providers
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try? container.decodeIfPresent(Profiles.self, forKey: .profiles)
            if case .object(let object)? = try? container.decodeIfPresent(JSONValue.self, forKey: .providers) {
                providers = object.mapValues(Provider.init(raw:))
            } else {
                providers = nil
            }
        }

        /// Lookup is scoped to one provider kind; `models` wins over `imageModels` on a shared id.
        func entry(providerKind: String, modelId: String) -> ModelEntry? {
            guard let provider = providers?[providerKind] else { return nil }
            return provider.models?[modelId] ?? provider.imageModels?[modelId]
        }
    }

    struct OfficialMatch: Decodable, Equatable, Sendable {
        var providerKind: String
        var modelId: String
    }

    /// Relay connection context: the Server alias match, the probe state and a connection-level
    /// (user-declared or confirmed probe) profile.
    struct RelayContext: Decodable, Sendable {
        var officialMatch: OfficialMatch?
        var probe: String?
        var userDeclared: [String: JSONValue]?
    }

    struct Resolution: Sendable {
        var profile: ImageProfile?
        /// Key into `profiles.image`, or `userDeclaredRef` for a connection-level profile.
        var profileRef: String?
        var reason: Reason?
        /// The `imageProfileOverride` merged over the table entry, when one applied.
        var appliedOverride: [String: JSONValue]?
    }

    static let userDeclaredRef = "user_declared"

    static func resolve(
        _ slice: Slice,
        providerKind: String?,
        modelId: String,
        relay: RelayContext? = nil
    ) -> Resolution {
        var lookupKind = providerKind
        var lookupId = modelId
        if let relay {
            // A connection-level profile wins outright and is the only thing validated.
            if let declared = relay.userDeclared {
                return resolution(validate(declared), profileRef: userDeclaredRef, appliedOverride: nil)
            }
            guard let match = relay.officialMatch else {
                // An empty probe is the same as an absent one.
                let probed = relay.probe.map { !$0.isEmpty } ?? false
                return failure(probed ? .probePendingConfirmation : .relayUnmatched)
            }
            lookupKind = match.providerKind
            lookupId = match.modelId
        }
        guard let lookupKind, let entry = slice.entry(providerKind: lookupKind, modelId: lookupId) else {
            return failure(.modelNotInCatalog)
        }
        guard let ref = entry.imageProfile, !ref.isEmpty else { return failure(.noImageProfile) }
        guard case .object(let base)? = slice.profiles?.image?[ref] else { return failure(.danglingProfile) }

        var merged = base
        var applied: [String: JSONValue]?
        if case .object(let override)? = entry.imageProfileOverride {
            merged.merge(override) { _, overriding in overriding }
            applied = override
        }
        return resolution(validate(merged), profileRef: ref, appliedOverride: applied)
    }

    /// Validates a merged profile object in the contract order, then builds the typed profile.
    static func validate(_ object: [String: JSONValue]) -> Result<ImageProfile, Reason> {
        for field in ImageProfile.requiredFields where nonNull(object[field]) == nil {
            return .failure(.missingRequiredField)
        }
        // These required fields have no reason of their own: a wrong JSON type, element types included,
        // counts as missing. Whole numbers only for the integer fields (2.0 is 2).
        guard case .array(let ratios)? = object["aspectRatios"], ratios.allSatisfy({ string($0) != nil }),
              case .object(let resolutions)? = object["resolutions"], resolutions.values.allSatisfy({ isInteger($0) }),
              isInteger(object["maxNPerCall"]), isInteger(object["timeoutSeconds"]) else {
            return .failure(.missingRequiredField)
        }
        // Conditionally required by the image_profile.v2 rules: the wire size is built from them.
        switch string(object["sizeParam"]) {
        case ImageProfile.SizeParam.wxh.rawValue, ImageProfile.SizeParam.dashscopeWxh.rawValue:
            guard case .object? = object["sizeConstraints"] else { return .failure(.missingRequiredField) }
        case ImageProfile.SizeParam.aspectResolution.rawValue, ImageProfile.SizeParam.geminiImageConfig.rawValue:
            guard case .object? = object["resolutionValues"] else { return .failure(.missingRequiredField) }
        default:
            break
        }
        guard case .bool(true)? = object["imageOutput"] else { return .failure(.notImageOutput) }
        guard let route = string(object["route"]).flatMap(ImageProfile.Route.init(rawValue:)) else {
            return .failure(.unknownRoute)
        }
        guard let sizeParam = string(object["sizeParam"]).flatMap(ImageProfile.SizeParam.init(rawValue:)) else {
            return .failure(.unknownSizeParam)
        }
        guard case .array(let rawOperations)? = object["operations"], !rawOperations.isEmpty else {
            return .failure(.unknownOperation)
        }
        var operations: [ImageProfile.Operation] = []
        for raw in rawOperations {
            guard let operation = string(raw).flatMap(ImageProfile.Operation.init(rawValue:)) else {
                return .failure(.unknownOperation)
            }
            operations.append(operation)
        }
        guard route.allowedSizeParams.contains(sizeParam) else { return .failure(.sizeParamNotAllowed) }
        let transportValue = nonNull(object["editTransport"])
        if operations.contains(.edit) {
            guard let transport = string(transportValue).flatMap(ImageProfile.EditTransport.init(rawValue:)) else {
                return .failure(.unknownEditTransport)
            }
            guard route.allowedEditTransports.contains(transport) else {
                return .failure(.editTransportNotAllowed)
            }
        } else if transportValue != nil {
            return .failure(.editTransportWithoutEdit)
        }
        guard string(object["source"]).flatMap(ImageProfile.Source.init(rawValue:)) != nil else {
            return .failure(.unknownSource)
        }
        do {
            let data = try JSONEncoder().encode(object)
            return .success(try JSONDecoder().decode(ImageProfile.self, from: data))
        } catch {
            // A required field of the wrong JSON type is as unusable as a missing one.
            return .failure(.missingRequiredField)
        }
    }

    private static func nonNull(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .none, .some(.null): return nil
        case .some(let present): return present
        }
    }

    fileprivate static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func isInteger(_ value: JSONValue?) -> Bool {
        guard case .number(let number)? = value else { return false }
        return number.isFinite && number.rounded() == number && abs(number) <= 9_007_199_254_740_991
    }

    /// A whole JSON number >= 1, else nil.
    static func positiveInteger(_ value: JSONValue?) -> Int? {
        guard isInteger(value), case .number(let number)? = value, number >= 1 else { return nil }
        return Int(number)
    }

    private static func failure(_ reason: Reason) -> Resolution {
        Resolution(profile: nil, profileRef: nil, reason: reason, appliedOverride: nil)
    }

    private static func resolution(
        _ validation: Result<ImageProfile, Reason>,
        profileRef: String,
        appliedOverride: [String: JSONValue]?
    ) -> Resolution {
        switch validation {
        case .success(let profile):
            return Resolution(profile: profile, profileRef: profileRef, reason: nil, appliedOverride: appliedOverride)
        case .failure(let reason):
            return failure(reason)
        }
    }

    /// Whether a resolved model is listed in the Studio model list for the current input images.
    static func visibleInStudio(
        _ profile: ImageProfile?,
        connectionUsable: Bool,
        hasBase: Bool,
        referenceCount: Int
    ) -> Bool {
        guard let profile, profile.imageOutput, connectionUsable else { return false }
        let imageCount = (hasBase ? 1 : 0) + max(0, referenceCount)
        if imageCount == 0 {
            return profile.operations.contains(.generate)
        }
        return profile.operations.contains(.edit) && imageCount <= (profile.maxReferenceImages ?? 1)
    }
}
