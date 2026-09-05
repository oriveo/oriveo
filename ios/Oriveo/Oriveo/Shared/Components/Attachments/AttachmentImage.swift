import SwiftUI


struct CachedAttachmentImage: View {
    let attachment: Attachment
    let partitionUID: String
    var maxPixelSize: CGFloat = 960
    var placeholderColor: Color = OriveoTheme.Palette.surfaceChrome
    var placeholderForegroundColor: Color = OriveoTheme.Palette.textTertiary

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var aspectRatio: CGFloat

    init(
        attachment: Attachment,
        partitionUID: String = AppSessionStore.activeUID,
        maxPixelSize: CGFloat = 960,
        placeholderColor: Color = OriveoTheme.Palette.surfaceChrome,
        placeholderForegroundColor: Color = OriveoTheme.Palette.textTertiary
    ) {
        self.attachment = attachment
        self.partitionUID = partitionUID
        self.maxPixelSize = maxPixelSize
        self.placeholderColor = placeholderColor
        self.placeholderForegroundColor = placeholderForegroundColor
        _aspectRatio = State(
            initialValue: Self.cachedPreferredAspectRatio(for: attachment, partitionUID: partitionUID)
                ?? Self.fallbackAspectRatio
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(placeholderColor)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(placeholderForegroundColor)

                if isLoading {
                    ProgressView()
                        .tint(placeholderForegroundColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
        .task(id: "\(partitionUID)|\(attachment.id)") {
            await resolvePlaceholderAspectRatio()
            await loadImage()
        }
    }

    private func resolvePlaceholderAspectRatio() async {
        guard image == nil,
              Self.cachedPreferredAspectRatio(for: attachment, partitionUID: partitionUID) == nil else { return }
        let attachment = self.attachment
        let uid = partitionUID
        let resolved = await Task.detached(priority: .userInitiated) {
            Self.preferredAspectRatio(for: attachment, partitionUID: uid)
        }.value
        guard !Task.isCancelled, image == nil else { return }
        aspectRatio = resolved
    }

    private func loadImage() async {
        let boundUID = partitionUID
        let previewKey = Self.previewCacheKey(for: attachment)

        if let lid = attachment.localImageID {
            if let cached = ImageStore.cachedUIImage(for: lid, partitionUID: boundUID) {
                aspectRatio = Self.aspectRatio(for: cached)
                image = cached
                return
            }

            isLoading = true
            if let loaded = await ImageStore.loadDisplayImage(
                for: lid,
                maxPixelSize: maxPixelSize,
                partitionUID: boundUID
            ) {
                guard !Task.isCancelled, AppSessionStore.activeUID == boundUID else { return }
                aspectRatio = Self.aspectRatio(for: loaded)
                image = loaded
                isLoading = false
                return
            }
            isLoading = false
        }

        if let tb = attachment.thumbnailBase64,
           let decoded = ImageStore.thumbnailImage(
               forBase64Encoded: tb,
               cacheKey: previewKey,
               maxPixelSize: maxPixelSize,
               partitionUID: boundUID
           ) {
            guard !Task.isCancelled, AppSessionStore.activeUID == boundUID else { return }
            aspectRatio = Self.aspectRatio(for: decoded)
            image = decoded
        }
    }

    nonisolated static let fallbackAspectRatio: CGFloat = 4 / 3

    nonisolated static func cachedPreferredAspectRatio(
        for attachment: Attachment,
        partitionUID: String
    ) -> CGFloat? {
        if let lid = attachment.localImageID {
            if let ratio = ImageStore.cachedImageAspectRatio(for: lid, thumbnail: true, partitionUID: partitionUID) {
                return ratio
            }
            if let ratio = ImageStore.cachedImageAspectRatio(for: lid, partitionUID: partitionUID) {
                return ratio
            }
        }
        return ImageStore.cachedInlineAspectRatio(
            cacheKey: previewCacheKey(for: attachment),
            partitionUID: partitionUID
        )
    }

    nonisolated static func preferredAspectRatio(for attachment: Attachment, partitionUID: String) -> CGFloat {
        let previewKey = previewCacheKey(for: attachment)

        if let lid = attachment.localImageID {
            if let ratio = ImageStore.imageAspectRatio(
                for: lid,
                thumbnail: true,
                partitionUID: partitionUID
            ) { return ratio }
            if let ratio = ImageStore.imageAspectRatio(for: lid, partitionUID: partitionUID) { return ratio }
        }

        if let tb = attachment.thumbnailBase64,
           let ratio = ImageStore.imageAspectRatio(
               forBase64Encoded: tb,
               cacheKey: previewKey,
               partitionUID: partitionUID
           ) {
            return ratio
        }

        return fallbackAspectRatio
    }

    nonisolated private static func previewCacheKey(for attachment: Attachment) -> String {
        attachment.localImageID ?? attachment.id.uuidString
    }

    nonisolated private static func aspectRatio(for image: UIImage) -> CGFloat {
        image.size.width / max(image.size.height, 1)
    }
}


struct ThumbnailImageView: View {
    let attachment: Attachment
    let partitionUID: String
    var placeholderColor: Color = OriveoTheme.Palette.surfaceChrome

    @State private var uiImage: UIImage?

    init(
        attachment: Attachment,
        partitionUID: String = AppSessionStore.activeUID,
        placeholderColor: Color = OriveoTheme.Palette.surfaceChrome
    ) {
        self.attachment = attachment
        self.partitionUID = partitionUID
        self.placeholderColor = placeholderColor
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(placeholderColor)
            }
        }
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        let previewKey = attachment.localImageID ?? attachment.id.uuidString

        guard let lid = attachment.localImageID else {
            if let tb = attachment.thumbnailBase64,
               let decoded = ImageStore.thumbnailImage(
                   forBase64Encoded: tb,
                   cacheKey: previewKey,
                   maxPixelSize: 160,
                   partitionUID: partitionUID
               ) {
                uiImage = decoded
            }
            return
        }
        if let cached = ImageStore.cachedUIImage(
            for: lid,
            thumbnail: true,
            partitionUID: partitionUID
        ) {
            uiImage = cached
            return
        }
        if let tb = attachment.thumbnailBase64,
               let img = ImageStore.thumbnailImage(
                   forBase64Encoded: tb,
                   cacheKey: lid,
                   maxPixelSize: 160,
                   partitionUID: partitionUID
               ) {
            uiImage = img
        }
    }
}
