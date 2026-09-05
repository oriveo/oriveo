import SwiftUI

struct ImageViewerSheet: View {
    let attachments: [Attachment]
    let partitionUID: String
    @State private var currentIndex: Int
    @State private var savedToPhotos = false
    @State private var pageFullImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    init(attachment: Attachment, partitionUID: String) {
        self.attachments = [attachment]
        self.partitionUID = partitionUID
        _currentIndex = State(initialValue: 0)
    }

    init(attachments: [Attachment], initialIndex: Int, partitionUID: String) {
        self.attachments = attachments
        self.partitionUID = partitionUID
        let safeIndex = max(0, min(initialIndex, attachments.count - 1))
        _currentIndex = State(initialValue: safeIndex)
    }

    private var currentAttachment: Attachment {
        attachments[max(0, min(currentIndex, attachments.count - 1))]
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TabView(selection: $currentIndex) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, att in
                        ImageViewerPage(
                            attachment: att,
                            partitionUID: partitionUID,
                            onFullImageLoaded: { img in
                                if index == currentIndex { pageFullImage = img }
                            }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 ? .always : .never))
                .indexViewStyle(.page(backgroundDisplayMode: attachments.count > 1 ? .always : .never))

                if attachments.count > 1 {
                    Text("\(currentIndex + 1) / \(attachments.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(.bottom, 36)
                }
            }
            .background(OriveoTheme.Palette.scrim.ignoresSafeArea())
            .onChange(of: currentIndex) { _, _ in
                pageFullImage = nil
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            guard let image = pageFullImage else { return }
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                            withAnimation { savedToPhotos = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { savedToPhotos = false }
                            }
                        } label: {
                            Image(systemName: savedToPhotos ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 20))
                        }
                        .disabled(pageFullImage == nil)
                        if let img = pageFullImage {
                            ShareLink(
                                item: Image(uiImage: img),
                                preview: SharePreview(currentAttachment.fileName, image: Image(uiImage: img))
                            ) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 20))
                            }
                        }
                    }
                }
            }
        }
    }
}


private struct ImageViewerPage: View {
    let attachment: Attachment
    let partitionUID: String
    let onFullImageLoaded: (UIImage) -> Void

    @State private var fullImage: UIImage?
    @State private var previewImage: UIImage?
    @State private var isLoading = false
    @State private var finishedLoadingOriginal = false

    init(
        attachment: Attachment,
        partitionUID: String,
        onFullImageLoaded: @escaping (UIImage) -> Void
    ) {
        self.attachment = attachment
        self.partitionUID = partitionUID
        self.onFullImageLoaded = onFullImageLoaded
    }

    var body: some View {
        GeometryReader { proxy in
            let displayImage = fullImage ?? previewImage
            if let displayImage {
                let aspect = displayImage.size.width / max(displayImage.size.height, 1)
                let fitWidth = min(proxy.size.width, displayImage.size.width)
                let fitHeight = fitWidth / aspect

                ZStack {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: displayImage)
                            .resizable()
                            .frame(width: fitWidth, height: fitHeight)
                    }
                    if isLoading && fullImage == nil {
                        originalLoadingBadge
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                        Text(L10n.tr("Loading full image…"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: partitionUID) {
            await loadPreviewImage()
            await loadFullImage()
        }
    }

    private var originalLoadingBadge: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.white)
            Text(L10n.tr("Loading full image…"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.62)))
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func loadFullImage() async {
        guard !finishedLoadingOriginal else { return }
        let boundUID = partitionUID

        if let lid = attachment.localImageID,
           let img = await ImageStore.loadOriginalImage(for: lid, partitionUID: boundUID) {
            guard !Task.isCancelled, AppSessionStore.activeUID == boundUID else { return }
            fullImage = img
            isLoading = false
            finishedLoadingOriginal = true
            onFullImageLoaded(img)
            return
        }


        finishedLoadingOriginal = true
    }

    private func loadPreviewImage() async {
        guard previewImage == nil, fullImage == nil else { return }
        let attachment = self.attachment
        let uid = partitionUID
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.makePreviewImage(for: attachment, partitionUID: uid)
        }.value
        guard !Task.isCancelled, fullImage == nil else { return }
        previewImage = decoded
    }

    nonisolated private static func makePreviewImage(for attachment: Attachment, partitionUID: String) -> UIImage? {
        guard let tb = attachment.thumbnailBase64 else { return nil }
        return ImageStore.thumbnailImage(
            forBase64Encoded: tb,
            cacheKey: attachment.localImageID ?? attachment.id.uuidString,
            maxPixelSize: 320,
            partitionUID: partitionUID
        )
    }
}


@ViewBuilder
func imageContextMenuItems(
    attachment: Attachment,
    partitionUID: String,
    savedToPhotos: Binding<Bool>
) -> some View {
    Button {
        saveImageToPhotos(
            attachment: attachment,
            partitionUID: partitionUID,
            saved: savedToPhotos
        )
    } label: {
        Label(L10n.tr("Save to Photos"), systemImage: "square.and.arrow.down")
    }

    ImageContextMenuImageActions(attachment: attachment, partitionUID: partitionUID)
}

private struct ImageContextMenuImageActions: View {
    let attachment: Attachment
    let partitionUID: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ShareLink(
                    item: Image(uiImage: image),
                    preview: SharePreview(attachment.fileName, image: Image(uiImage: image))
                ) {
                    Label(L10n.tr("Share"), systemImage: "square.and.arrow.up")
                }

                Button {
                    UIPasteboard.general.image = image
                } label: {
                    Label(L10n.tr("Copy Image"), systemImage: "doc.on.doc")
                }
            }
        }
        .task(id: "\(partitionUID)|\(attachment.id)") {
            guard image == nil else { return }
            let attachment = self.attachment
            let uid = partitionUID
            image = await Task.detached(priority: .userInitiated) {
                resolveImage(for: attachment, partitionUID: uid)
            }.value
        }
    }
}

nonisolated func resolveImage(for attachment: Attachment, partitionUID: String) -> UIImage? {
    if let lid = attachment.localImageID,
       let data = ImageStore.loadImageData(for: lid, partitionUID: partitionUID),
       let img = UIImage(data: data) {
        return img
    }
    if let tb = attachment.thumbnailBase64,
       let data = Data(base64Encoded: tb),
       let img = UIImage(data: data) {
        return img
    }
    return nil
}

func saveImageToPhotos(
    attachment: Attachment,
    partitionUID: String,
    saved: Binding<Bool>
) {
    guard let image = resolveImage(for: attachment, partitionUID: partitionUID) else { return }
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    withAnimation { saved.wrappedValue = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        withAnimation { saved.wrappedValue = false }
    }
}
