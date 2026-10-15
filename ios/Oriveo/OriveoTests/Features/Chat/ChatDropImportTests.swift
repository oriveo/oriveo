import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Oriveo

/// Drops on the chat page: classification, slots and rejections use the same functions as the buttons, and text alone goes into the composer.
@Suite("ChatDropImport")
struct ChatDropImportTests {

    // MARK: - Classification

    @Test(
        "Split by type: image / file / text snippet / unknown",
        arguments: [
            (["public.png"], nil, false, ChatDropImport.Kind.image),
            (["public.jpeg", "public.url"], nil, false, .image),
            (["com.adobe.pdf"], "report.pdf", true, .file),
            (["public.mpeg-4"], "clip.mp4", false, .file),
            (["public.utf8-plain-text"], nil, false, .text),
            (["public.html", "public.utf8-plain-text"], nil, false, .text),
            (["public.url", "public.utf8-plain-text"], "example.com", false, .text),
            // Text files also report public.text: with a file representation, or a suggested name with a supported extension, they count as files
            (["public.plain-text"], "notes.txt", false, .file),
            (["public.plain-text"], nil, true, .file),
            (["public.zip-archive"], "bundle.zip", false, .file),
            (["com.apple.uikit.useractivity"], nil, false, .ignored),
        ] as [([String], String?, Bool, ChatDropImport.Kind)]
    )
    func classifiesByType(types: [String], name: String?, fileBacked: Bool, expected: ChatDropImport.Kind) {
        let item = ChatDropImport.Item(typeIdentifiers: types, suggestedName: name, isFileBacked: fileBacked)
        #expect(ChatDropImport.classify(item) == expected)
    }

    @Test("The current model takes no images: a dropped image ends like an image picked with the file button (unsupported format)")
    func imagesWithoutVisionAreUnsupported() {
        let items = [
            ChatDropImport.Item(typeIdentifiers: ["public.png"], suggestedName: nil),
            ChatDropImport.Item(typeIdentifiers: ["com.adobe.pdf"], suggestedName: "a.pdf", isFileBacked: true),
        ]
        let withoutVision = ChatDropImport.plan(items, supportsImage: false)
        #expect(withoutVision.imageIndices.isEmpty)
        #expect(withoutVision.unsupportedCount == 1)
        #expect(withoutVision.fileIndices == [1])

        let withVision = ChatDropImport.plan(items, supportsImage: true)
        #expect(withVision.imageIndices == [0])
        #expect(withVision.unsupportedCount == 0)
    }

    @Test("Only text alone goes into the composer; mixed with files the text is left; all-unknown drops are ignored")
    func onlyPureTextAppends() {
        let text = ChatDropImport.Item(typeIdentifiers: ["public.utf8-plain-text"], suggestedName: nil)
        let file = ChatDropImport.Item(typeIdentifiers: ["com.adobe.pdf"], suggestedName: "a.pdf", isFileBacked: true)
        let activity = ChatDropImport.Item(typeIdentifiers: ["com.apple.uikit.useractivity"], suggestedName: nil)

        #expect(ChatDropImport.plan([text, text], supportsImage: true).appendsText)
        let mixed = ChatDropImport.plan([text, file], supportsImage: true)
        #expect(!mixed.appendsText)
        #expect(mixed.fileIndices == [1])
        #expect(ChatDropImport.plan([activity], supportsImage: true).isEmpty)
    }

    // MARK: - Slots and file import (the same function as the file button)

    @Test("File slots: the same calculation as the file button, 0 when full", arguments: [(5, 3, 2), (5, 5, 0), (5, 7, 0), (0, 0, 0)])
    func fileSlots(maxFiles: Int, pending: Int, expected: Int) {
        #expect(ChatDropImport.availableFileSlots(maxFiles: maxFiles, pendingCount: pending) == expected)
    }

    /// Production entry point: the file button and drops both call `ChatDropImport.processFileURLs`.
    @Test("Oversized, unsupported and over-limit are counted separately; files beyond the slots are not read")
    @MainActor
    func fileImportCountsRejections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ text: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        let big = try write("big.txt", String(repeating: "x", count: 64))
        let unknown = try write("blob.xyz", "hello")
        let ok = try write("ok.txt", "hello")
        let extra = try write("extra.txt", "world")

        let result = await ChatDropImport.processFileURLs(
            [big, unknown, ok, extra],
            availableSlots: 1,
            importContext: .init(provider: nil, model: nil),
            byteLimit: 32,
            extractionLimits: .default
        )

        #expect(result.attachments.map(\.fileName) == ["ok.txt"])
        #expect(result.oversizedCount == 1)
        #expect(result.rejectedCount == 1)
        #expect(result.overLimitCount == 1)
    }

    @Test("With no slots nothing is read and everything counts as over the limit")
    @MainActor
    func noSlotsReadsNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: url)

        let result = await ChatDropImport.processFileURLs(
            [url, url],
            availableSlots: ChatDropImport.availableFileSlots(maxFiles: 3, pendingCount: 3),
            importContext: .init(provider: nil, model: nil),
            byteLimit: 1_024,
            extractionLimits: .default
        )
        #expect(result.attachments.isEmpty)
        #expect(result.overLimitCount == 2)
    }

    // MARK: - Reading dropped items

    @Test("A dropped file is copied to the temporary directory keeping its name, and the file import turns it into an attachment")
    @MainActor
    func copiedFileImportsLikeButton() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("drop-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = source.appendingPathComponent("draft notes.md")
        try Data("# Title\nbody".utf8).write(to: original)

        let provider = try #require(NSItemProvider(contentsOf: original))
        // Items dragged out of the Files app carry a suggested name; `NSItemProvider(contentsOf:)` does not, and the system names the temporary copy
        // after the type ("Markdown content.md" and the like), so the test adds one as the drag source would
        provider.suggestedName = "draft notes"
        let target = ChatDropLoader.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: target) }
        let copied = try #require(await ChatDropLoader.copyFile(from: provider, into: target))
        #expect(copied.lastPathComponent == "draft notes.md")
        #expect(copied.path.hasPrefix(target.path))

        let result = await ChatDropImport.processFileURLs(
            [copied],
            availableSlots: 1,
            importContext: .init(provider: nil, model: nil),
            byteLimit: 1_024,
            extractionLimits: .default
        )
        #expect(result.attachments.first?.fileName == "draft notes.md")
        #expect(result.attachments.first?.kind == .file)
    }

    @Test("A dropped image is decoded and takes the camera path: over the size limit it is oversized, otherwise it becomes a JPEG attachment")
    @MainActor
    func droppedImageUsesCameraPipeline() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let image = try #require(await ChatDropLoader.loadImage(from: provider))
        #expect(image.size.width == 64)

        guard case .oversized = ChatAttachmentPicker.processCapturedImage(image, byteLimit: 8, partitionUID: "drop-tests") else {
            Issue.record("Should be oversized with an 8-byte limit")
            return
        }
        guard case .imported(let attachment) = ChatAttachmentPicker.processCapturedImage(
            image, byteLimit: 1_024 * 1_024, partitionUID: "drop-tests"
        ) else {
            Issue.record("A normal-sized image should import")
            return
        }
        #expect(attachment.kind == .image)
        #expect(attachment.mimeType == "image/jpeg")
    }

    @Test("A dropped text snippet reads as a string; a link alone gives the link text")
    @MainActor
    func loadsDroppedText() async {
        #expect(await ChatDropLoader.loadText(from: NSItemProvider(object: "hello" as NSString)) == "hello")
        let link = NSItemProvider(object: URL(string: "https://oriveo.app/a")! as NSURL)
        #expect(await ChatDropLoader.loadText(from: link) == "https://oriveo.app/a")
    }

    // MARK: - Text into the composer

    @Test("Appended on a new line after the existing text; no blank line for an empty composer or at the start of a line")
    func appendsOnNewLine() {
        for (current, expected) in [("", "b"), ("a", "a\nb"), ("a\n", "a\nb")] {
            let result = ChatDropImport.appendingDroppedText("b", to: current, maxUTF16: 100)
            #expect(result.text == expected)
            #expect(!result.truncated)
        }
    }

    @Test("Bound by the input limit: what does not fit is cut and reported, without splitting graphemes")
    func respectsLengthLimit() {
        let cut = ChatDropImport.appendingDroppedText("bcdef", to: "a", maxUTF16: 4)
        #expect(cut.text == "a\nbc")
        #expect(cut.truncated)

        let full = ChatDropImport.appendingDroppedText("b", to: "abcd", maxUTF16: 4)
        #expect(full.text == "abcd")
        #expect(full.truncated)

        // 👍🏽 is one grapheme of 4 UTF-16 code units: with 3 units left it does not fit at all
        let emoji = ChatDropImport.appendingDroppedText("👍🏽x", to: "", maxUTF16: 3)
        #expect(emoji.text == "")
        #expect(emoji.truncated)
    }

    @Test("Temporary file name: the suggested name first, the extension from the loaded file or the type, without duplication")
    func fileNames() {
        #expect(ChatDropImport.fileName(suggestedName: "Report", loadedFileName: "tmp123.pdf", typeIdentifier: "com.adobe.pdf") == "Report.pdf")
        #expect(ChatDropImport.fileName(suggestedName: "Report.pdf", loadedFileName: "tmp123.pdf", typeIdentifier: "com.adobe.pdf") == "Report.pdf")
        #expect(ChatDropImport.fileName(suggestedName: nil, loadedFileName: "data", typeIdentifier: "public.comma-separated-values-text") == "data.csv")
        #expect(ChatDropImport.fileName(suggestedName: "a/b", loadedFileName: "x.txt", typeIdentifier: "public.plain-text") == "a-b.txt")
    }
}
