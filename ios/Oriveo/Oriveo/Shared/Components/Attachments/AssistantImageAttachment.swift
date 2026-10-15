import SwiftUI


struct AssistantImageAttachment: View {
    let attachment: Attachment

    @State private var showFullScreen = false
    @State private var savedToPhotos = false

    var body: some View {
        CachedAttachmentImage(
            attachment: attachment,
            partitionUID: AppSessionStore.activeUID
        )
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hoverEffect(.lift)
            .onTapGesture { showFullScreen = true }
            // Drags out the original image file (the same one as the UIKit `UIKitAssistantImageView`); without a local original it drags an empty item
            .onDrag {
                AssistantImageDrag.itemProvider(for: attachment, partitionUID: AppSessionStore.activeUID)
                    ?? NSItemProvider()
            }
            .contextMenu {
                imageContextMenuItems(
                    attachment: attachment,
                    partitionUID: AppSessionStore.activeUID,
                    savedToPhotos: $savedToPhotos
                )
            }
            .fullScreenCover(isPresented: $showFullScreen) {
                ImageViewerSheet(
                    attachment: attachment,
                    partitionUID: AppSessionStore.activeUID
                )
            }
    }
}
