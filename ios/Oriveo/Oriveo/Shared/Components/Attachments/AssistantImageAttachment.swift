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
            .onTapGesture { showFullScreen = true }
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
