import Foundation

/// Normalizes one Studio image request against a resolved ImageProfile: aspect, resolution tier,
/// quality, the dotted wire body keys, the batch split and the adjustments shown in the notice bar.
/// Cases: `shared/model-contracts/image_param_normalization.v1.json`, read by the iOS / Android /
/// Web contract tests alike. Pure function, no UI entry point.
enum ImageParamNormalizer {
    typealias JSONValue = MetadataClient.JSONValue

    /// `explicitAspect.defaultAspect` in image_profile.v2: the wire always carries a ratio.
    static let defaultAspect = "1:1"

    /// Raw user choices. nil and the empty string mean unset; n = 0 means unset too.
    struct Request: Equatable, Sendable {
        var aspect: String?
        var resolution: String?
        var quality: String?
        var n: Int?

        init(aspect: String? = nil, resolution: String? = nil, quality: String? = nil, n: Int? = nil) {
            self.aspect = aspect
            self.resolution = resolution
            self.quality = quality
            self.n = n
        }
    }

    enum Failure: String, CaseIterable, Error, Sendable {
        /// A request value is set but outside its closed set.
        case invalidRequest = "invalid_request"
        /// The profile cannot serve any request (bad aspect list, maxNPerCall < 1, no usable tier).
        case invalidProfile = "invalid_profile"
    }

    /// A wire body value is either a string or an integer.
    enum WireValue: Equatable, Sendable {
        case string(String)
        case integer(Int)
    }

    enum AdjustmentField: String, CaseIterable, Sendable {
        case aspect, resolution, size, quality, n
    }

    enum AdjustmentValue: Equatable, Sendable {
        case string(String)
        case integer(Int)
        case null
        case integers([Int])
    }

    struct Adjustment: Equatable, Sendable {
        var field: AdjustmentField
        var from: AdjustmentValue
        var to: AdjustmentValue
    }

    struct Normalized: Equatable, Sendable {
        var aspect: String
        var resolution: String
        /// The quality tier actually sent, nil when no quality goes on the wire.
        var quality: String?
        /// Dotted body keys (`parameters.size`, `generationConfig.imageConfig.aspectRatio`).
        var wire: [String: WireValue]
        var batches: [Int]
        /// In the order aspect, resolution, size, quality, n.
        var adjustments: [Adjustment]

        /// The fixture shape of this result.
        var jsonObject: [String: JSONValue] {
            [
                "aspect": .string(aspect),
                "resolution": .string(resolution),
                "quality": quality.map(JSONValue.string) ?? .null,
                "wire": .object(wire.mapValues(Self.json)),
                "batches": .array(batches.map { .number(Double($0)) }),
                "adjustments": .array(adjustments.map { adjustment in
                    .object([
                        "field": .string(adjustment.field.rawValue),
                        "from": Self.json(adjustment.from),
                        "to": Self.json(adjustment.to),
                    ])
                }),
            ]
        }

        private static func json(_ value: WireValue) -> JSONValue {
            switch value {
            case .string(let text): return .string(text)
            case .integer(let number): return .number(Double(number))
            }
        }

        private static func json(_ value: AdjustmentValue) -> JSONValue {
            switch value {
            case .string(let text): return .string(text)
            case .integer(let number): return .number(Double(number))
            case .null: return .null
            case .integers(let numbers): return .array(numbers.map { .number(Double($0)) })
            }
        }
    }

    /// The profile is checked before the request (contract card U4a item 2); unset request fields
    /// take defaults and never produce adjustments.
    static func normalize(
        _ profile: ImageProfile,
        request: Request,
        defaultAspect: String = defaultAspect
    ) -> Result<Normalized, Failure> {
        // Profile first.
        var ratios: [(text: String, ratio: Ratio)] = []
        for text in profile.aspectRatios {
            guard let ratio = Ratio(text) else { return .failure(.invalidProfile) }
            ratios.append((text, ratio))
        }
        let tiers = availableTiers(profile)
        guard !ratios.isEmpty, profile.maxNPerCall >= 1, let lowestTier = tiers.first else {
            return .failure(.invalidProfile)
        }

        // Then the request.
        let userAspect = unset(request.aspect)
        let userResolution = unset(request.resolution)
        let userQuality = unset(request.quality)
        let userN = request.n == 0 ? nil : request.n
        if let userAspect, Ratio(userAspect) == nil { return .failure(.invalidRequest) }
        if let userResolution, ImageProfile.ResolutionTier(rawValue: userResolution) == nil {
            return .failure(.invalidRequest)
        }
        if let userQuality, ImageProfile.QualityTier(rawValue: userQuality) == nil { return .failure(.invalidRequest) }
        if let userN, userN < 1 { return .failure(.invalidRequest) }
        let requestedAspect = userAspect ?? defaultAspect
        guard let requestedRatio = Ratio(requestedAspect) else { return .failure(.invalidRequest) }
        let requestedTier = userResolution.flatMap(ImageProfile.ResolutionTier.init(rawValue:)) ?? .oneK
        let requestedQuality = userQuality ?? ImageProfile.QualityTier.standard.rawValue
        let n = userN ?? 1

        var adjustments: [Adjustment] = []
        var wire: [String: WireValue] = [:]

        // Aspect: an exact list entry, else nearest by |ln ratio|; ties keep the earlier entry.
        var chosen = ratios[0]
        if let exact = ratios.first(where: { $0.text == requestedAspect }) {
            chosen = exact
        } else {
            let target = requestedRatio.logValue
            var best = abs(chosen.ratio.logValue - target)
            for candidate in ratios.dropFirst() {
                let distance = abs(candidate.ratio.logValue - target)
                if distance < best - 1e-12 {
                    best = distance
                    chosen = candidate
                }
            }
        }
        if let userAspect, chosen.text != userAspect {
            adjustments.append(Adjustment(field: .aspect, from: .string(userAspect), to: .string(chosen.text)))
        }

        // Resolution: the highest available tier not above the request, else the lowest.
        let tier = tiers.last(where: { $0.order <= requestedTier.order }) ?? lowestTier
        if let userResolution, tier.rawValue != userResolution {
            adjustments.append(Adjustment(field: .resolution, from: .string(userResolution), to: .string(tier.rawValue)))
        }

        // Size on the wire.
        switch profile.sizeParam {
        case .wxh, .dashscopeWxh:
            let longEdge = profile.resolutions[tier.rawValue] ?? 0
            let initial = baseSize(longEdge: longEdge, ratio: chosen.ratio, multiple: profile.sizeConstraints?.multipleOf ?? 1)
            let final = clamp(initial, profile.sizeConstraints)
            if final != initial {
                adjustments.append(Adjustment(field: .size, from: .string(initial.text("x")), to: .string(final.text("x"))))
            }
            if profile.sizeParam == .wxh {
                wire["size"] = .string(final.text("x"))
            } else {
                wire["parameters.size"] = .string(final.text("*"))
            }
        case .aspectResolution:
            wire["aspect_ratio"] = .string(chosen.text)
            wire["resolution"] = .string(profile.resolutionValues?[tier.rawValue] ?? "")
        case .geminiImageConfig:
            wire["generationConfig.imageConfig.aspectRatio"] = .string(chosen.text)
            wire["generationConfig.imageConfig.imageSize"] = .string(profile.resolutionValues?[tier.rawValue] ?? "")
        case .chatImageConfig:
            wire["image_config.aspect_ratio"] = .string(chosen.text)
        case .aspectOnly:
            wire["aspect_ratio"] = .string(chosen.text)
        }

        // Quality: only a mapped tier is sent; a missing tier is reported when the user picked it.
        var quality: String?
        if let qualityKey = profile.route.qualityBodyKey, let qualityMap = profile.qualityMap {
            if let value = qualityMap[requestedQuality] {
                wire[qualityKey] = .string(value)
                quality = requestedQuality
            } else if let userQuality {
                adjustments.append(Adjustment(field: .quality, from: .string(userQuality), to: .null))
            }
        }

        // n: split by maxNPerCall, or n single requests when the route or profile sends no n.
        let batches: [Int]
        if let nKey = profile.route.nBodyKey, profile.nParam ?? true {
            let maxPerCall = profile.maxNPerCall
            var split = Array(repeating: maxPerCall, count: n / maxPerCall)
            if n % maxPerCall > 0 { split.append(n % maxPerCall) }
            batches = split
            wire[nKey] = .integer(split[0])
        } else {
            batches = Array(repeating: 1, count: n)
        }
        if batches.count > 1 {
            adjustments.append(Adjustment(field: .n, from: .integer(n), to: .integers(batches)))
        }

        return .success(Normalized(
            aspect: chosen.text,
            resolution: tier.rawValue,
            quality: quality,
            wire: wire,
            batches: batches,
            adjustments: adjustments
        ))
    }

    // MARK: - Helpers

    /// A W:H ratio matching `^[1-9][0-9]{0,3}:[1-9][0-9]{0,3}$`: each side 1...9999, no leading
    /// zero. Requests and profile.aspectRatios are checked alike.
    private struct Ratio: Equatable {
        let width: Int
        let height: Int

        init?(_ text: String) {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts.allSatisfy({ part in
                      (1...4).contains(part.count) && part.first != "0"
                          && part.allSatisfy { ("0"..."9").contains($0) }
                  }),
                  let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
            self.width = width
            self.height = height
        }

        var logValue: Double { log(Double(width) / Double(height)) }
    }

    private struct Size: Equatable {
        var width: Int
        var height: Int

        func text(_ separator: String) -> String { "\(width)\(separator)\(height)" }
    }

    private static func unset(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Tiers whose resolutions entry is a positive integer; aspect_resolution / gemini_image_config
    /// also need a resolutionValues string. Lowest first.
    private static func availableTiers(_ profile: ImageProfile) -> [ImageProfile.ResolutionTier] {
        ImageProfile.ResolutionTier.allCases.filter { tier in
            guard let edge = profile.resolutions[tier.rawValue], edge >= 1 else { return false }
            switch profile.sizeParam {
            case .aspectResolution, .geminiImageConfig:
                return profile.resolutionValues?[tier.rawValue] != nil
            default:
                return true
            }
        }
    }

    /// Long edge from the tier, short edge from the ratio, each rounded to the nearest multiple and
    /// kept at one multiple or more. Edges are computed in Double and converted with `edge(_:)`, so
    /// an oversized profile value never traps on Int overflow.
    private static func baseSize(longEdge: Int, ratio: Ratio, multiple: Int) -> Size {
        let step = Double(multiple)
        func round(_ value: Double) -> Int { max(multiple, edge((value / step).rounded() * step)) }
        let long = round(Double(longEdge))
        if ratio.width >= ratio.height {
            return Size(width: long, height: round(Double(longEdge) * Double(ratio.height) / Double(ratio.width)))
        }
        return Size(width: round(Double(longEdge) * Double(ratio.width) / Double(ratio.height)), height: long)
    }

    /// maxLongEdge (integer math, floor) -> maxPixels (floor) -> minPixels (ceil); after every step
    /// each edge is at least one multiple, so no edge reaches 0.
    private static func clamp(_ size: Size, _ constraints: ImageProfile.SizeConstraints?) -> Size {
        let multiple = constraints?.multipleOf ?? 1
        var size = size
        if let maxLongEdge = constraints?.maxLongEdge {
            let longEdge = max(size.width, size.height)
            if longEdge > maxLongEdge {
                func shrink(_ value: Int) -> Int {
                    let (product, overflow) = value.multipliedReportingOverflow(by: maxLongEdge)
                    if !overflow { return max(multiple, product / longEdge / multiple * multiple) }
                    let step = Double(multiple)
                    return max(multiple, edge((Double(value) * Double(maxLongEdge) / Double(longEdge) / step).rounded(.down) * step))
                }
                size = Size(width: shrink(size.width), height: shrink(size.height))
            }
        }
        let pixels = Double(size.width) * Double(size.height)
        if let maxPixels = constraints?.maxPixels, pixels > Double(maxPixels) {
            size = scaled(size, by: (Double(maxPixels) / pixels).squareRoot(), multiple, .down)
        }
        let scaledPixels = Double(size.width) * Double(size.height)
        if let minPixels = constraints?.minPixels, scaledPixels < Double(minPixels) {
            size = scaled(size, by: (Double(minPixels) / scaledPixels).squareRoot(), multiple, .up)
        }
        return size
    }

    private static func scaled(_ size: Size, by factor: Double, _ multiple: Int, _ rule: FloatingPointRoundingRule) -> Size {
        let step = Double(multiple)
        func scale(_ value: Int) -> Int { max(multiple, edge((Double(value) * factor / step).rounded(rule) * step)) }
        return Size(width: scale(size.width), height: scale(size.height))
    }

    /// Double -> Int edge, clamped to 0...2^53-1 instead of trapping.
    private static func edge(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return value < 9_007_199_254_740_991 ? Int(value) : 9_007_199_254_740_991
    }
}

private extension ImageProfile.ResolutionTier {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension ImageProfile.Route {
    /// `routes[route].bodyKeys.n` in image_profile.v2.
    var nBodyKey: String? {
        switch self {
        case .openaiImages, .xaiImages, .openrouterImages, .minimaxImageGeneration: return "n"
        case .dashscopeMultimodal: return "parameters.n"
        case .geminiGenerateContent, .chatModalities: return nil
        }
    }

    /// `routes[route].bodyKeys.quality` in image_profile.v2.
    var qualityBodyKey: String? {
        switch self {
        case .openaiImages, .openrouterImages: return "quality"
        default: return nil
        }
    }
}
