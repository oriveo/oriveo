import Foundation

/// BYOK reference image budget before the request leaves the device: per-route
/// encoded-size limits, the bytes one image adds to the request body, and the
/// backwards shrink walk that brings an edit request under those limits.
///
/// Cases: the shared studio contracts fixture `byok_reference_budget.v1.json`, read by the
/// iOS / Android / Web contract tests alike.
nonisolated enum StudioReferenceBudget {
    /// Fixed allowance for JSON / multipart framing and every non-image field.
    static let overheadBytes = 65536
    static let shrinkMaxLongEdge = 2048
    static let shrinkJPEGQuality = 0.9
    static let shrinkMime = "image/jpeg"
    static let tooLargeErrorKind: StudioImageErrorKind = .invalidParam

    static let baseRole = "base"
    static let multipartTransport = "multipart"
    static let bareBase64Route = "gemini_generate_content"

    /// Encoded-size limits of one route; `maxImageBytes` nil = no per-image limit.
    struct Limits: Equatable, Sendable {
        let maxRequestBytes: Int
        let maxImageBytes: Int?
    }

    /// What the budget needs to know about one reference image.
    struct Item: Equatable, Sendable {
        var slot: Int
        var role: String
        var mime: String
        var byteCount: Int
    }

    enum Status: String, CaseIterable, Equatable, Sendable {
        case fits
        case tooLarge = "too_large"
    }

    struct FitResult<T> {
        let status: Status
        /// `tooLargeErrorKind` when the request still does not fit, otherwise nil.
        let errorKind: StudioImageErrorKind?
        let requestBytes: Int
        /// Final images in send order (base first, then ascending slot).
        let images: [T]
    }

    /// Every image route has a row; nil = the route cannot edit, nothing to shrink.
    static let routeLimits: [String: Limits?] = [
        "openai_images": Limits(maxRequestBytes: 50_000_000, maxImageBytes: 20_971_520),
        "xai_images": Limits(maxRequestBytes: 50_000_000, maxImageBytes: 20_971_520),
        "openrouter_images": Limits(maxRequestBytes: 50_000_000, maxImageBytes: nil),
        "chat_modalities": Limits(maxRequestBytes: 50_000_000, maxImageBytes: nil),
        "gemini_generate_content": Limits(maxRequestBytes: 20_000_000, maxImageBytes: nil),
        "dashscope_multimodal": Limits(maxRequestBytes: 16_777_216, maxImageBytes: 10_000_000),
        "minimax_image_generation": nil,
    ]

    static func limits(for route: String) -> Limits? {
        routeLimits[route] ?? nil
    }

    /// Bytes one image adds to the request body: multipart sends raw bytes, Gemini
    /// inline_data bare base64, every other route a data URI.
    static func encodedBytes(route: String, editTransport: String?, mime: String, byteCount: Int) -> Int {
        if editTransport == multipartTransport { return byteCount }
        let base64 = 4 * ((byteCount + 2) / 3)
        if route == bareBase64Route { return base64 }
        return "data:\(mime);base64,".utf8.count + base64
    }

    /// Walks the send order backwards, shrinking only what is needed: stops as soon as
    /// the whole request and every image are within limits; while the request is within
    /// its limit, images within the per-image limit are skipped. A shrink result is kept
    /// only when its encoded size is strictly smaller. Routes without limits fit as-is.
    static func fit<T>(
        route: String,
        editTransport: String?,
        prompt: String,
        images: [T],
        describe: (T) -> Item,
        shrink: (T) async -> T?
    ) async -> FitResult<T> {
        let described = images.map(describe)
        let order = images.indices.sorted { lhsIndex, rhsIndex in
            let lhs = described[lhsIndex]
            let rhs = described[rhsIndex]
            let lhsBase = lhs.role == baseRole
            let rhsBase = rhs.role == baseRole
            if lhsBase != rhsBase { return lhsBase }
            if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
            return lhsIndex < rhsIndex
        }
        var current = order.map { images[$0] }
        var sizes = order.map {
            encodedBytes(route: route, editTransport: editTransport, mime: described[$0].mime, byteCount: described[$0].byteCount)
        }
        let fixedBytes = overheadBytes + prompt.utf8.count

        guard let limits = limits(for: route) else {
            return FitResult(status: .fits, errorKind: nil, requestBytes: fixedBytes + sizes.reduce(0, +), images: current)
        }

        for index in current.indices.reversed() {
            let total = fixedBytes + sizes.reduce(0, +)
            if fits(total: total, sizes: sizes, limits: limits) { break }
            if total <= limits.maxRequestBytes && !isOverImageLimit(sizes[index], limits: limits) { continue }
            guard let shrunk = await shrink(current[index]) else { continue }
            let item = describe(shrunk)
            let size = encodedBytes(route: route, editTransport: editTransport, mime: item.mime, byteCount: item.byteCount)
            if size < sizes[index] {
                current[index] = shrunk
                sizes[index] = size
            }
        }

        let total = fixedBytes + sizes.reduce(0, +)
        let ok = fits(total: total, sizes: sizes, limits: limits)
        return FitResult(
            status: ok ? .fits : .tooLarge,
            errorKind: ok ? nil : tooLargeErrorKind,
            requestBytes: total,
            images: current
        )
    }

    private static func isOverImageLimit(_ size: Int, limits: Limits) -> Bool {
        guard let maxImageBytes = limits.maxImageBytes else { return false }
        return size > maxImageBytes
    }

    private static func fits(total: Int, sizes: [Int], limits: Limits) -> Bool {
        total <= limits.maxRequestBytes && !sizes.contains { isOverImageLimit($0, limits: limits) }
    }
}
