import CoreGraphics
import Foundation
import ImageIO

/// Re-encodes one BYOK reference image so it fits the request budget: applies the EXIF
/// orientation, scales the long edge down to `StudioReferenceBudget.shrinkMaxLongEdge`
/// (never up), flattens alpha onto opaque white and writes a metadata-free JPEG at
/// `StudioReferenceBudget.shrinkJPEGQuality`. ImageIO / CoreGraphics only; `@concurrent`
/// so decoding and encoding never run on the caller's (main) actor.
nonisolated enum StudioReferenceShrinker {
    /// Returns nil when the bytes cannot be decoded as an image or any CoreGraphics /
    /// ImageIO step fails. `mime` is the declared source type; decoding sniffs the bytes,
    /// so it is informational only.
    @concurrent
    nonisolated static func shrink(_ data: Data, mime: String) async -> (data: Data, mime: String)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }

        let maxPixelSize = min(max(width, height), StudioReferenceBudget.shrinkMaxLongEdge)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let outputWidth = oriented.width
        let outputHeight = oriented.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(oriented, in: bounds)
        guard let flattened = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        // Only the encoder quality is passed; no source properties, so no EXIF / GPS / orientation tag.
        let encodeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: StudioReferenceBudget.shrinkJPEGQuality,
        ]
        CGImageDestinationAddImage(destination, flattened, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, StudioReferenceBudget.shrinkMime)
    }
}
