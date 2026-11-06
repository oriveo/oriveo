import Foundation

/// Runs one chat image send on the studio pipeline when `ChatImageDispatch` picks it: resolves
/// the image profile from the catalog slice, decides, builds the executor input with
/// `ChatImageDispatch.chatParams`, runs the BYOK executor and writes a thumbnail per delivered
/// image. Called on the legacy image branch only, so the legacy gate is already true. `nil` means
/// the legacy path runs unchanged.
struct ChatImageStudioRunner {
    struct Request {
        var provider: ProviderKind
        var modelId: String
        var apiKey: String
        /// nil or blank keeps the legacy path.
        var baseURL: String?
        /// The prompt the legacy path would send (style prefix + last user text).
        var prompt: String
        /// Attachments of the user message being sent, in order; images with local bytes become
        /// edit references when the profile supports edit.
        var attachments: [Attachment]
        /// Image library partition of the session (nil = current session).
        var partitionUID: String?
    }

    let executor: StudioByokExecutor
    let slice: () -> ImageProfileResolver.Slice?

    init(
        executor: StudioByokExecutor = ChatImageStudioRunner.defaultExecutor(),
        slice: @escaping () -> ImageProfileResolver.Slice? = { MetadataClient.shared.imageProfileSlice() }
    ) {
        self.executor = executor
        self.slice = slice
    }

    /// The shared background transfer is always enabled, so chat sends work with the Studio
    /// build flag off.
    static func defaultExecutor() -> StudioByokExecutor {
        StudioByokExecutor(transport: StudioBackgroundByokTransport(transfer: StudioBackgroundTransfer.shared))
    }

    /// One reference candidate: attachment id plus its bytes when they are on this device.
    nonisolated struct LoadedImage: Sendable {
        var id: String
        var mime: String
        var bytes: Data?
    }

    /// Returns the chat result, `nil` for the legacy path, or throws the mapped chat error;
    /// a cancelled round throws `CancellationError` with nothing delivered.
    func run(_ request: Request) async throws -> ProviderChatResult? {
        guard let connectionBaseURL = request.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !connectionBaseURL.isEmpty else {
            return nil
        }
        let profile = slice().flatMap { slice in
            ImageProfileResolver.resolve(
                slice, providerKind: MetadataClient.catalogKey(for: request.provider), modelId: request.modelId
            ).profile
        }
        // Attachments never change legacy vs studio, so bytes are read only for a studio send
        // whose profile can edit.
        guard case .studio = ChatImageDispatch.decide(
            providerKind: request.provider, legacyImageDispatch: true, profile: profile, attachments: []
        ), let profile else { return nil }
        // The studio base URL depends on the route, so it is derived once the profile is known.
        guard let baseURL = ChatImageDispatch.studioBaseURL(
            route: profile.route, connectionBaseURL: connectionBaseURL
        ) else { return nil }
        var loaded: [LoadedImage] = []
        if profile.operations.contains(.edit) {
            let candidates = request.attachments.compactMap { attachment -> LoadedImage? in
                guard attachment.kind == .image, let localID = attachment.localImageID, !localID.isEmpty else { return nil }
                return LoadedImage(id: localID, mime: attachment.mimeType, bytes: nil)
            }
            loaded = await Self.loadBytes(candidates, partitionUID: request.partitionUID)
        }
        guard case .studio(let operation, let picked) = ChatImageDispatch.decide(
            providerKind: request.provider,
            legacyImageDispatch: true,
            profile: profile,
            attachments: loaded.map { ChatImageDispatch.Attachment(id: $0.id, hasBytes: $0.bytes != nil) }
        ) else { return nil }
        let byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let references = picked.compactMap { image -> StudioByokInput.Image? in
            guard let source = byId[image.attachmentId], let bytes = source.bytes else { return nil }
            return StudioByokInput.Image(slot: image.slot, role: image.role, mime: source.mime, bytes: bytes)
        }

        let params = ChatImageDispatch.chatParams
        let result = await executor.run(StudioByokInput(
            roundId: UUID().uuidString.lowercased(),
            providerKind: request.provider.rawValue,
            apiKey: request.apiKey,
            baseURL: baseURL,
            modelId: request.modelId,
            profile: profile,
            operation: operation,
            prompt: request.prompt,
            params: ImageParamNormalizer.Request(
                aspect: params.aspect, resolution: params.resolution.rawValue, quality: params.quality.rawValue, n: params.n
            ),
            advanced: ImageRequestBuilder.Advanced(),
            images: references,
            partitionUID: request.partitionUID
        ))

        switch result.status {
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw result.errorKind.flatMap { ChatImageDispatch.chatFailure(kind: $0, message: result.message ?? "") }
                ?? ProviderServiceError.emptyResponse
        case .completed, .partial:
            // partial completes with the delivered images, no error.
            break
        }
        guard !result.images.isEmpty else { throw ProviderServiceError.emptyResponse }
        let thumbnails = await Self.writeThumbnails(result.images.map(\.id), partitionUID: request.partitionUID)
        let attachments = result.images.map { image in
            Attachment(
                id: UUID(),
                kind: .image,
                fileName: "generated_image.\(Self.fileExtension(image.mime))",
                mimeType: image.mime,
                localImageID: image.id,
                thumbnailBase64: thumbnails[image.id]
            )
        }
        return ProviderChatResult(
            text: "", promptTokens: 0, completionTokens: 0, estimatedCost: 0,
            attachments: attachments, usageReported: false
        )
    }

    nonisolated static func fileExtension(_ mime: String) -> String {
        if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
        return mime.contains("webp") ? "webp" : "png"
    }

    /// Reads the reference bytes off the main actor; the mime follows the bytes when they decode.
    @concurrent
    nonisolated static func loadBytes(_ images: [LoadedImage], partitionUID: String?) async -> [LoadedImage] {
        images.map { image in
            var copy = image
            if let data = ImageStore.loadImageData(for: image.id, partitionUID: partitionUID), !data.isEmpty {
                copy.bytes = data
                copy.mime = StudioImageResponse.decodeImageInfo(data)?.mime ?? image.mime
            }
            return copy
        }
    }

    /// Writes the thumbnail of every delivered image off the main actor; returns its base64 by id.
    @concurrent
    nonisolated static func writeThumbnails(_ ids: [String], partitionUID: String?) async -> [String: String] {
        var thumbnails: [String: String] = [:]
        for id in ids {
            guard let data = ImageStore.loadImageData(for: id, partitionUID: partitionUID),
                  let thumbnail = ImageStore.makeThumbnailData(from: data)
            else { continue }
            ImageStore.saveThumbnail(imageData: thumbnail, for: id, partitionUID: partitionUID)
            thumbnails[id] = thumbnail.base64EncodedString()
        }
        return thumbnails
    }
}
