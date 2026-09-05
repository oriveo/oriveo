import SwiftUI
import QuickLook

// MARK: -

enum UserImageAttachmentLayout {
    case hero
    case grid
    case compact
}

struct HeroCornerRadii: Equatable {
    let topLeading: CGFloat
    let topTrailing: CGFloat
    let bottomLeading: CGFloat
    let bottomTrailing: CGFloat
}

struct UserAttachmentsGroup: View {
    let attachments: [Attachment]
    var immersiveHero: Bool = false
    var hasText: Bool = false

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files  = attachments.filter { $0.kind != .image }

        VStack(alignment: .trailing, spacing: OriveoTheme.Spacing.sm) {
            if !images.isEmpty {
                imagesContent(images)
            }
            if !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files) { UserFileAttachment(attachment: $0) }
                }
            }
        }
    }

    private var heroCornerRadii: HeroCornerRadii? {
        guard immersiveHero else { return nil }
        if hasText {
            return HeroCornerRadii(topLeading: 20, topTrailing: 20, bottomLeading: 0, bottomTrailing: 0)
        } else {
            return HeroCornerRadii(topLeading: 20, topTrailing: 20, bottomLeading: 20, bottomTrailing: 6)
        }
    }

    @ViewBuilder
    private func imagesContent(_ images: [Attachment]) -> some View {
        switch images.count {
        case 1:
            UserImageAttachment(
                attachment: images[0],
                layout: .hero,
                heroCornerRadii: heroCornerRadii,
                galleryImages: images,
                galleryIndex: 0
            )
        case 2:
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, att in
                    UserImageAttachment(
                        attachment: att,
                        layout: .grid,
                        galleryImages: images,
                        galleryIndex: idx
                    )
                }
            }
        case 3:
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, att in
                    UserImageAttachment(
                        attachment: att,
                        layout: .compact,
                        galleryImages: images,
                        galleryIndex: idx
                    )
                }
            }
        default:
            twoByTwoGrid(images: images)
        }
    }

    @ViewBuilder
    private func twoByTwoGrid(images: [Attachment]) -> some View {
        let firstFour = Array(images.prefix(4))
        let remaining = images.count - 4
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                UserImageAttachment(attachment: firstFour[0], layout: .grid, galleryImages: images, galleryIndex: 0)
                UserImageAttachment(attachment: firstFour[1], layout: .grid, galleryImages: images, galleryIndex: 1)
            }
            HStack(spacing: 6) {
                UserImageAttachment(attachment: firstFour[2], layout: .grid, galleryImages: images, galleryIndex: 2)
                if remaining > 0 {
                    UserImageAttachment(
                        attachment: firstFour[3],
                        layout: .grid,
                        overflowCount: remaining,
                        galleryImages: images,
                        galleryIndex: 3
                    )
                } else {
                    UserImageAttachment(
                        attachment: firstFour[3],
                        layout: .grid,
                        galleryImages: images,
                        galleryIndex: 3
                    )
                }
            }
        }
    }
}

struct UserImageAttachment: View {
    let attachment: Attachment
    var layout: UserImageAttachmentLayout = .compact
    var heroCornerRadii: HeroCornerRadii? = nil
    var overflowCount: Int = 0
    var galleryImages: [Attachment]? = nil
    var galleryIndex: Int = 0

    @State private var showFullScreen = false
    @State private var savedToPhotos = false

    private var clipShape: AnyShape {
        if let r = heroCornerRadii {
            return AnyShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: r.topLeading,
                    bottomLeadingRadius: r.bottomLeading,
                    bottomTrailingRadius: r.bottomTrailing,
                    topTrailingRadius: r.topTrailing,
                    style: .continuous
                )
            )
        }
        let radius: CGFloat = layout == .hero ? 14 : 12
        return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    var body: some View {
        imageView
            .overlay {
                if overflowCount > 0 {
                    ZStack {
                        clipShape
                            .fill(.black.opacity(0.55))
                        Text("+\(overflowCount)")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .clipShape(clipShape)
            .contentShape(clipShape)
            .onTapGesture { showFullScreen = true }
            .contextMenu {
                imageContextMenuItems(
                    attachment: attachment,
                    partitionUID: AppSessionStore.activeUID,
                    savedToPhotos: $savedToPhotos
                )
            }
            .fullScreenCover(isPresented: $showFullScreen) {
                if let gallery = galleryImages, gallery.count > 1 {
                    ImageViewerSheet(
                        attachments: gallery,
                        initialIndex: galleryIndex,
                        partitionUID: AppSessionStore.activeUID
                    )
                } else {
                    ImageViewerSheet(
                        attachment: attachment,
                        partitionUID: AppSessionStore.activeUID
                    )
                }
            }
    }

 /// fillMaxWidth + maxHeight aspect-fit
    @ViewBuilder
    private func heroImage(aspect: CGFloat) -> some View {
        let heroMaxHeight: CGFloat = 240
        if heroCornerRadii != nil {
            CachedAttachmentImage(
                attachment: attachment,
                partitionUID: AppSessionStore.activeUID,
                maxPixelSize: 1280,
                placeholderColor: .white.opacity(0.18),
                placeholderForegroundColor: .white.opacity(0.6)
            )
            .frame(maxHeight: heroMaxHeight)
        } else {
            let isPortrait = aspect < 0.7
            CachedAttachmentImage(
                attachment: attachment,
                partitionUID: AppSessionStore.activeUID,
                maxPixelSize: 1280,
                placeholderColor: .white.opacity(0.18),
                placeholderForegroundColor: .white.opacity(0.6)
            )
            .frame(
                maxWidth: isPortrait ? heroMaxHeight * aspect : .infinity,
                maxHeight: heroMaxHeight
            )
        }
    }

    @ViewBuilder
    private var imageView: some View {
        switch layout {
        case .hero:
            heroImage(
                aspect: CachedAttachmentImage.preferredAspectRatio(
                    for: attachment,
                    partitionUID: AppSessionStore.activeUID
                )
            )
        case .grid:
            ThumbnailImageView(
                attachment: attachment,
                partitionUID: AppSessionStore.activeUID,
                placeholderColor: .white.opacity(0.18)
            )
                .frame(width: 128, height: 128)
        case .compact:
            ThumbnailImageView(
                attachment: attachment,
                partitionUID: AppSessionStore.activeUID,
                placeholderColor: .white.opacity(0.18)
            )
                .frame(width: 96, height: 96)
        }
    }
}

struct UserFileAttachment: View {
    let attachment: Attachment

    @State private var showQuickLook = false
    @State private var tempFileURL: URL?
    @State private var isDownloading = false

    /// The file payload was dropped (for example after an import that did not carry it).
    private var isUnavailable: Bool {
        attachment.base64Data == nil || attachment.base64Data?.isEmpty == true
    }

    private var iconName: String {
        if isUnavailable { return "doc.badge.ellipsis" }
        return AttachmentIconResolver.symbolName(mime: attachment.mimeType, fileName: attachment.fileName)
    }

    var body: some View {
        Button {
            Task { await prepareAndPreview() }
        } label: {
            HStack(spacing: 4) {
                if isDownloading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.7))
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 12))
                }
                Text(attachment.fileName)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(isUnavailable ? 0.5 : 0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(isUnavailable ? 0.08 : 0.18))
            )
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable || isDownloading)
        .help(isUnavailable ? L10n.tr("Only available on original device") : "")
        .quickLookPreview($tempFileURL)
    }

    private func prepareAndPreview() async {
        var fileData: Data?

        if let b64 = attachment.base64Data, !b64.isEmpty {
            fileData = Data(base64Encoded: b64)
        }

        guard let fileData else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(attachment.fileName)
        try? fileData.write(to: tmp)
        tempFileURL = tmp
    }
}

// MARK: - icon

enum AttachmentIconResolver {
    static func symbolName(mime: String, fileName: String) -> String {
        let mimeLower = mime.lowercased()
        let ext = (fileName as NSString).pathExtension.lowercased()

        if mimeLower == "application/pdf" || ext == "pdf" {
            return "doc.richtext.fill"
        }
        if mimeLower.contains("wordprocessingml") || mimeLower == "application/msword" ||
           ext == "doc" || ext == "docx" || ext == "odt" || ext == "rtf" {
            return "doc.text.fill"
        }
        if mimeLower.contains("spreadsheetml") || mimeLower == "application/vnd.ms-excel" ||
           ext == "xls" || ext == "xlsx" || ext == "csv" || ext == "ods" {
            return "tablecells.fill"
        }
        if mimeLower.contains("presentationml") || mimeLower == "application/vnd.ms-powerpoint" ||
           ext == "ppt" || ext == "pptx" || ext == "key" || ext == "odp" {
            return "chart.bar.doc.horizontal.fill"
        }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(ext) ||
           mimeLower.contains("zip") || mimeLower.contains("compressed") {
            return "doc.zipper"
        }
        let codeExts: Set<String> = [
            "swift", "kt", "java", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "cpp", "h", "hpp",
            "cs", "rb", "php", "sh", "bash", "zsh", "html", "css", "scss", "less", "vue", "svelte",
            "json", "xml", "yaml", "yml", "toml", "ini", "env", "lock", "gradle", "groovy",
        ]
        if codeExts.contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if mimeLower.hasPrefix("text/") || ext == "txt" || ext == "md" || ext == "markdown" {
            return "doc.plaintext.fill"
        }
        if mimeLower.hasPrefix("audio/") {
            return "music.note"
        }
        if mimeLower.hasPrefix("video/") {
            return "video.fill"
        }
        return "doc.fill"
    }
}
