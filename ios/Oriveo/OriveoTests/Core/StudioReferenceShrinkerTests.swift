import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Oriveo

/// Reference image shrinker cases, same names on every client (contract
/// `byok_reference_budget.v1`). Sources are encoded on the fly with CGImageDestination.
@Suite("StudioReferenceShrinkerTests")
struct StudioReferenceShrinkerTests {
    struct Decoded {
        let width: Int
        let height: Int
        let type: String?
        let orientation: UInt32?
    }

    /// Solid opaque fill, or fully transparent when `fill` is nil.
    static func makeImage(width: Int, height: Int, fill: CGColor?) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        if let fill {
            context.setFillColor(fill)
            context.fill(bounds)
        }
        return try #require(context.makeImage())
    }

    static func encode(_ image: CGImage, type: String, orientation: CGImagePropertyOrientation? = nil) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation.rawValue }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func decode(_ data: Data) throws -> Decoded {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return Decoded(
            width: try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue),
            height: try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue),
            type: CGImageSourceGetType(source) as String?,
            orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        )
    }

    /// RGB of the center pixel, read by drawing the decoded image into a 1x1 bitmap.
    static func centerRGB(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(
                x: -CGFloat(image.width / 2),
                y: -CGFloat(image.height / 2),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            ))
            return true
        }
        #expect(drawn)
        return Array(pixel.prefix(3))
    }

    static let blue = CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)

    @Test("shrink.downscales_long_edge")
    func downscalesLongEdge() async throws {
        let png = try Self.encode(Self.makeImage(width: 3000, height: 1500, fill: Self.blue), type: "public.png")
        let result = try #require(await StudioReferenceShrinker.shrink(png, mime: "image/png"))
        #expect(result.mime == "image/jpeg")
        #expect(result.data.starts(with: [0xFF, 0xD8]))
        let decoded = try Self.decode(result.data)
        #expect(decoded.type == "public.jpeg")
        #expect(abs(decoded.width - 2048) <= 1, "width \(decoded.width)")
        #expect(abs(decoded.height - 1024) <= 1, "height \(decoded.height)")
    }

    @Test("shrink.small_not_upscaled")
    func smallNotUpscaled() async throws {
        let png = try Self.encode(Self.makeImage(width: 800, height: 600, fill: Self.blue), type: "public.png")
        let result = try #require(await StudioReferenceShrinker.shrink(png, mime: "image/png"))
        #expect(result.mime == "image/jpeg")
        let decoded = try Self.decode(result.data)
        #expect(decoded.type == "public.jpeg")
        #expect(decoded.width == 800)
        #expect(decoded.height == 600)
    }

    @Test("shrink.alpha_flattened_white")
    func alphaFlattenedWhite() async throws {
        let png = try Self.encode(Self.makeImage(width: 64, height: 64, fill: nil), type: "public.png")
        let result = try #require(await StudioReferenceShrinker.shrink(png, mime: "image/png"))
        #expect(result.mime == "image/jpeg")
        let rgb = try Self.centerRGB(result.data)
        #expect(rgb.allSatisfy { $0 >= 250 }, "center RGB \(rgb)")
    }

    @Test("shrink.exif_applied")
    func exifApplied() async throws {
        let jpeg = try Self.encode(
            Self.makeImage(width: 300, height: 100, fill: Self.blue),
            type: "public.jpeg",
            orientation: .right
        )
        #expect(try Self.decode(jpeg).orientation == CGImagePropertyOrientation.right.rawValue)
        let result = try #require(await StudioReferenceShrinker.shrink(jpeg, mime: "image/jpeg"))
        #expect(result.mime == "image/jpeg")
        let decoded = try Self.decode(result.data)
        #expect(decoded.width == 100)
        #expect(decoded.height == 300)
        #expect((decoded.orientation ?? CGImagePropertyOrientation.up.rawValue) == CGImagePropertyOrientation.up.rawValue)
    }

    @Test("shrink.undecodable_returns_null")
    func undecodableReturnsNull() async {
        #expect(await StudioReferenceShrinker.shrink(Data("not an image".utf8), mime: "image/png")?.data == nil)
        #expect(await StudioReferenceShrinker.shrink(Data(), mime: "image/jpeg")?.data == nil)
    }
}
