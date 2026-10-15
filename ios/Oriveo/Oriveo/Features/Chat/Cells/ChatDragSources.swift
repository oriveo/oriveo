import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Text blocks that can be dragged out of a conversation (user bubbles, code block cards): the drag carries the same source text as each one's Copy.
///
/// `UIDragInteraction` holds its delegate weakly, so the host view keeps a strong reference to this object.
final class ChatTextDragSource: NSObject, UIDragInteractionDelegate {
    private let text: () -> String?
    private let canBegin: (UIDragSession) -> Bool

    /// - Parameters:
    ///   - text: reads the source text when the drag starts; blank text is not dragged.
    ///   - canBegin: decides from the press location whether to yield (to text selection when it lands on selectable text).
    init(text: @escaping () -> String?, canBegin: @escaping (UIDragSession) -> Bool = { _ in true }) {
        self.text = text
        self.canBegin = canBegin
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard canBegin(session),
              let text = text(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: text as NSString))
        item.localObject = text
        return [item]
    }
}

/// Dragging an assistant image out: the drag carries the original file stored on the device (shared by the UIKit and SwiftUI views).
enum AssistantImageDrag {
    /// nil when there is no local original yet, so no drag starts.
    static func itemProvider(for attachment: Attachment, partitionUID: String) -> NSItemProvider? {
        let key = attachment.localImageID ?? attachment.id.uuidString
        guard let data = ImageStore.loadImageData(for: key, partitionUID: partitionUID) else { return nil }
        let type = imageType(of: data) ?? UTType(mimeType: attachment.mimeType) ?? .jpeg
        let fileName = fileName(for: attachment.fileName, type: type)

        let provider = NSItemProvider()
        provider.suggestedName = fileName
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("AssistantImageDrag", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = folder.appendingPathComponent(fileName)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url)
                completion(url, false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    /// The stored bytes may not match the attachment's MIME type (imports are converted to JPEG), so the bytes decide.
    private static func imageType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    private static func fileName(for original: String, type: UTType) -> String {
        let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let name = base.isEmpty ? "image" : base
        guard let ext = type.preferredFilenameExtension else { return name }
        return name + "." + ext
    }
}

/// The drag source for the UIKit assistant image view.
final class AssistantImageDragSource: NSObject, UIDragInteractionDelegate {
    private let attachment: Attachment
    private let partitionUID: String

    init(attachment: Attachment, partitionUID: String) {
        self.attachment = attachment
        self.partitionUID = partitionUID
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let provider = AssistantImageDrag.itemProvider(for: attachment, partitionUID: partitionUID) else { return [] }
        return [UIDragItem(itemProvider: provider)]
    }
}
