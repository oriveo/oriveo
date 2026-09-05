import Foundation
import Testing
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Oriveo

@Suite("Image Store Tests")
struct ImageStoreTests {

    @Test("Same Image IDUses Partitioned Caches")
    func sameImageIDUsesPartitionedCaches() async {
        ImageStore.clearAllCaches()
        let uidA = "image-cache-a-\(UUID().uuidString)"
        let uidB = "image-cache-b-\(UUID().uuidString)"
        let imageID = "shared-image-id"
        ImageStore.save(
            imageData: makePNG(width: 80, height: 40, color: .systemRed),
            for: imageID,
            partitionUID: uidA
        )
        ImageStore.save(
            imageData: makePNG(width: 30, height: 90, color: .systemGreen),
            for: imageID,
            partitionUID: uidB
        )
        defer {
            ImageStore.deleteImage(for: imageID, partitionUID: uidA)
            ImageStore.deleteImage(for: imageID, partitionUID: uidB)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uidA))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uidB))
        }

        let imageA = await ImageStore.loadDisplayImage(for: imageID, partitionUID: uidA)
        let imageB = await ImageStore.loadDisplayImage(for: imageID, partitionUID: uidB)
        let ratioA = ImageStore.imageAspectRatio(for: imageID, partitionUID: uidA)
        let ratioB = ImageStore.imageAspectRatio(for: imageID, partitionUID: uidB)

        #expect(imageA != nil)
        #expect(imageB != nil)
        #expect(imageA !== imageB)
        #expect(abs((ratioA ?? 0) - 2) < 0.01)
        #expect(abs((ratioB ?? 0) - (1.0 / 3.0)) < 0.01)
        #expect(ImageStore.cachedUIImage(for: imageID, partitionUID: uidA) === imageA)
        #expect(ImageStore.cachedUIImage(for: imageID, partitionUID: uidB) === imageB)
    }

    @Test("Partition Delete Invalidates Only Target Caches")
    func partitionDeleteInvalidatesOnlyTargetCaches() async {
        ImageStore.clearAllCaches()
        let uidA = "image-delete-a-\(UUID().uuidString)"
        let uidB = "image-delete-b-\(UUID().uuidString)"
        let imageID = "shared-delete-id"
        let dataA = makePNG(width: 60, height: 30)
        let dataB = makePNG(width: 30, height: 60)
        ImageStore.save(imageData: dataA, for: imageID, partitionUID: uidA)
        ImageStore.save(imageData: dataB, for: imageID, partitionUID: uidB)
        ImageStore.saveThumbnail(imageData: dataA, for: imageID, partitionUID: uidA)
        ImageStore.saveThumbnail(imageData: dataB, for: imageID, partitionUID: uidB)
        defer {
            ImageStore.deleteImage(for: imageID, partitionUID: uidA)
            ImageStore.deleteImage(for: imageID, partitionUID: uidB)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uidA))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uidB))
        }

        _ = await ImageStore.loadDisplayImage(for: imageID, partitionUID: uidA)
        _ = await ImageStore.loadDisplayImage(for: imageID, partitionUID: uidB)
        _ = await ImageStore.loadOriginalImage(for: imageID, partitionUID: uidA)
        _ = await ImageStore.loadOriginalImage(for: imageID, partitionUID: uidB)
        _ = ImageStore.imageAspectRatio(for: imageID, thumbnail: true, partitionUID: uidA)
        _ = ImageStore.imageAspectRatio(for: imageID, thumbnail: true, partitionUID: uidB)
        ImageStore.cacheUIImage(makeImage(width: 20, height: 10), for: imageID, thumbnail: true, partitionUID: uidA)
        ImageStore.cacheUIImage(makeImage(width: 10, height: 20), for: imageID, thumbnail: true, partitionUID: uidB)

        ImageStore.deleteImage(for: imageID, partitionUID: uidA)

        #expect(ImageStore.imageExists(for: imageID, partitionUID: uidA) == false)
        #expect(ImageStore.cachedUIImage(for: imageID, partitionUID: uidA) == nil)
        #expect(ImageStore.cachedUIImage(for: imageID, thumbnail: true, partitionUID: uidA) == nil)
        #expect(await ImageStore.loadOriginalImage(for: imageID, partitionUID: uidA) == nil)
        #expect(ImageStore.imageAspectRatio(for: imageID, partitionUID: uidA) == nil)

        #expect(ImageStore.imageExists(for: imageID, partitionUID: uidB))
        #expect(ImageStore.cachedUIImage(for: imageID, partitionUID: uidB) != nil)
        #expect(ImageStore.cachedUIImage(for: imageID, thumbnail: true, partitionUID: uidB) != nil)
        #expect(await ImageStore.loadOriginalImage(for: imageID, partitionUID: uidB) != nil)
        #expect(abs((ImageStore.imageAspectRatio(for: imageID, partitionUID: uidB) ?? 0) - 0.5) < 0.01)
    }

    @Test("Base64 Aspect Ratio Uses Image Metadata")
    func base64AspectRatioUsesImageMetadata() {
        ImageStore.clearAllCaches()

        let data = makePNG(width: 40, height: 20)
        let base64 = data.base64EncodedString()

        let ratio = ImageStore.imageAspectRatio(forBase64Encoded: base64, cacheKey: "ratio-metadata")

        #expect(ratio != nil)
        #expect(abs((ratio ?? 0) - 2) < 0.001)
    }

    @Test("Base64 Thumbnail Uses Cache Key")
    func base64ThumbnailUsesCacheKey() {
        ImageStore.clearAllCaches()

        let data = makePNG(width: 240, height: 120)
        let base64 = data.base64EncodedString()

        let first = ImageStore.thumbnailImage(
            forBase64Encoded: base64,
            cacheKey: "thumb-cache",
            maxPixelSize: 48
        )
        let second = ImageStore.thumbnailImage(
            forBase64Encoded: base64,
            cacheKey: "thumb-cache",
            maxPixelSize: 48
        )

        #expect(first != nil)
        #expect(second != nil)
        #expect(first === second)
        #expect(max(first?.size.width ?? 0, first?.size.height ?? 0) <= 48.5)
    }

    @Test("Base64 Thumbnail Separates Different Pixel Sizes")
    func base64ThumbnailSeparatesDifferentPixelSizes() {
        ImageStore.clearAllCaches()

        let data = makePNG(width: 320, height: 160)
        let base64 = data.base64EncodedString()

        let small = ImageStore.thumbnailImage(
            forBase64Encoded: base64,
            cacheKey: "thumb-size-aware",
            maxPixelSize: 48
        )
        let large = ImageStore.thumbnailImage(
            forBase64Encoded: base64,
            cacheKey: "thumb-size-aware",
            maxPixelSize: 160
        )

        #expect(small != nil)
        #expect(large != nil)
        #expect(small !== large)
        #expect(max(small?.size.width ?? 0, small?.size.height ?? 0) <= 48.5)
        #expect(max(large?.size.width ?? 0, large?.size.height ?? 0) > 100)
    }

    @Test("Decode Image Downsamples Large Data")
    func decodeImageDownsamplesLargeData() async {
        ImageStore.clearAllCaches()

        let data = makePNG(width: 400, height: 200)
        let image = await ImageStore.decodeImage(data, maxPixelSize: 80)

        #expect(image != nil)
        #expect(max(image?.size.width ?? 0, image?.size.height ?? 0) <= 80.5)
    }

    @Test("Attachment Downsampling Bounds Pixels Without Upscaling")
    func attachmentDownsamplingBoundsPixelsWithoutUpscaling() {
        let large = ChatAttachmentPicker.downsampleImageData(makePNG(width: 800, height: 400), maxPixelSize: 120)
        // UIGraphicsImageRenderer uses the simulator's 3x scale, so 20x10pt encodes as 60x30px.
        let small = ChatAttachmentPicker.downsampleImageData(makePNG(width: 20, height: 10), maxPixelSize: 120)

        #expect(large != nil)
        #expect(max(large?.size.width ?? 0, large?.size.height ?? 0) <= 120.5)
        #expect(small != nil)
        #expect(max(small?.size.width ?? 0, small?.size.height ?? 0) <= 60.5)
    }

    @Test("Attachment Downsampling Rejects Invalid Input")
    func attachmentDownsamplingRejectsInvalidInput() {
        #expect(ChatAttachmentPicker.downsampleImageData(Data([0x00, 0x01]), maxPixelSize: 120) == nil)
        #expect(ChatAttachmentPicker.downsampleImageData(makePNG(width: 20, height: 20), maxPixelSize: 0) == nil)
    }

    @Test("Attachment Downsampling Applies Exif Orientation")
    func attachmentDownsamplingAppliesExifOrientation() {
        let data = makeJPEG(width: 60, height: 40, orientation: .right)
        let image = ChatAttachmentPicker.downsampleImageData(data, maxPixelSize: 120)

        #expect(image != nil)
        #expect((image?.size.height ?? 0) > (image?.size.width ?? 0))
        #expect(image?.imageOrientation == .up)
    }

    @Test("Load Original Image Keeps Full Resolution")
    func loadOriginalImageKeepsFullResolution() async {
        ImageStore.clearAllCaches()

        let uid = "image-store-tests-\(UUID().uuidString)"
        let imageID = UUID().uuidString
        let data = makePNG(width: 96, height: 64)

        ImageStore.save(imageData: data, for: imageID, partitionUID: uid)
        defer {
            ImageStore.deleteImage(for: imageID, partitionUID: uid)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        let image = await ImageStore.loadOriginalImage(for: imageID, partitionUID: uid)

        #expect(image != nil)
        #expect(abs(((image?.size.width ?? 0) / max(image?.size.height ?? 1, 1)) - 1.5) < 0.01)
        #expect(max(image?.size.width ?? 0, image?.size.height ?? 0) > 200)
    }

    @Test("Load Original Image Preserves UIImage Data Orientation")
    func loadOriginalImagePreservesUIImageDataOrientation() async {
        ImageStore.clearAllCaches()

        let uid = "image-store-orientation-\(UUID().uuidString)"
        let imageID = UUID().uuidString
        let data = makeJPEG(width: 60, height: 40, orientation: .right)
        let expected = UIImage(data: data)

        ImageStore.save(imageData: data, for: imageID, partitionUID: uid)
        defer {
            ImageStore.deleteImage(for: imageID, partitionUID: uid)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        let image = await ImageStore.loadOriginalImage(for: imageID, partitionUID: uid)

        #expect(expected != nil)
        #expect(image != nil)
        #expect(image?.imageOrientation == expected?.imageOrientation)
    }

    @Test("Image Memory Cost Scales With Pixels")
    func imageMemoryCostScalesWithPixels() {
        let small = makeImage(width: 40, height: 40)
        let large = makeImage(width: 160, height: 160)

        let smallCost = ImageStore.imageMemoryCost(small)
        let largeCost = ImageStore.imageMemoryCost(large)

        #expect(smallCost > 0)
        #expect(largeCost > smallCost)
        let ratio = Double(largeCost) / Double(smallCost)
        #expect(ratio > 8 && ratio < 32)
    }

    private func makeImage(width: CGFloat, height: CGFloat, color: UIColor = .systemBlue) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }

    private func makePNG(width: CGFloat, height: CGFloat, color: UIColor = .systemBlue) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
        return image.pngData() ?? Data()
    }

    private func makeJPEG(
        width: CGFloat,
        height: CGFloat,
        color: UIColor = .systemBlue,
        orientation: CGImagePropertyOrientation
    ) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }

        let data = NSMutableData()
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithData(
                  data as CFMutableData,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            return Data()
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return Data()
        }
        return data as Data
    }
}
