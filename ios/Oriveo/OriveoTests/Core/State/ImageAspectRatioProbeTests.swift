import Foundation
import UIKit
import Testing
@testable import Oriveo

@Suite("ImageAspectRatioProbe", .serialized)
struct ImageAspectRatioProbeTests {

    @Test("init-time aspect ratio only hits the cache; an empty cache does not probe disk")
    @MainActor
    func initialAspectRatioIsCacheOnly() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "image-aspect-\(UUID().uuidString)"
        defer {
            AppSessionStore.switchToUser(previousUID)
            ImageStore.clearAllCaches()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        ImageStore.clearAllCaches()

        let image = Self.makeImage(width: 40, height: 20)
        let data = try #require(image.pngData())
        let imageID = UUID().uuidString
        ImageStore.save(imageData: data, for: imageID, partitionUID: uid)
        ImageStore.clearAllCaches()

        let attachment = TestFactories.makeImageAttachment(
            localImageID: imageID,
            thumbnailBase64: nil
        )

        #expect(
            CachedAttachmentImage.cachedPreferredAspectRatio(
                for: attachment,
                partitionUID: uid
            ) == nil
        )

        let probed = CachedAttachmentImage.preferredAspectRatio(for: attachment, partitionUID: uid)
        #expect(abs(probed - 2.0) < 0.01)

        let cached = try #require(
            CachedAttachmentImage.cachedPreferredAspectRatio(for: attachment, partitionUID: uid)
        )
        #expect(abs(cached - 2.0) < 0.01)
    }

    @Test("with no clues, fall back to the fixed placeholder ratio")
    @MainActor
    func fallsBackToPlaceholderRatio() {
        let uid = "image-aspect-empty-\(UUID().uuidString)"
        defer {
            ImageStore.clearAllCaches()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        ImageStore.clearAllCaches()

        let attachment = TestFactories.makeImageAttachment(
            localImageID: UUID().uuidString,
            thumbnailBase64: nil
        )
        #expect(
            CachedAttachmentImage.cachedPreferredAspectRatio(for: attachment, partitionUID: uid) == nil
        )
        #expect(
            CachedAttachmentImage.preferredAspectRatio(for: attachment, partitionUID: uid)
                == CachedAttachmentImage.fallbackAspectRatio
        )
    }

    @Test("a failed probe is negatively cached so layout does not repeat disk IO; saving invalidates it")
    @MainActor
    func missingFileIsCachedThenInvalidatedOnSave() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "image-aspect-miss-\(UUID().uuidString)"
        defer {
            AppSessionStore.switchToUser(previousUID)
            ImageStore.clearAllCaches()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        ImageStore.clearAllCaches()

        let imageID = UUID().uuidString
        let attachment = TestFactories.makeImageAttachment(
            localImageID: imageID,
            thumbnailBase64: nil
        )

        _ = CachedAttachmentImage.preferredAspectRatio(for: attachment, partitionUID: uid)
        let probesAfterFirstMiss = ImageStore.aspectRatioDiskProbeCount
        #expect(probesAfterFirstMiss > 0)

        for _ in 0..<20 {
            _ = CachedAttachmentImage.preferredAspectRatio(for: attachment, partitionUID: uid)
        }
        #expect(ImageStore.aspectRatioDiskProbeCount == probesAfterFirstMiss)

        let image = Self.makeImage(width: 40, height: 20)
        let data = try #require(image.pngData())
        ImageStore.save(imageData: data, for: imageID, partitionUID: uid)

        let probed = CachedAttachmentImage.preferredAspectRatio(for: attachment, partitionUID: uid)
        #expect(abs(probed - 2.0) < 0.01)
        #expect(ImageStore.aspectRatioDiskProbeCount > probesAfterFirstMiss)
    }

    private static func makeImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
