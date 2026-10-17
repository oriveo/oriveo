import XCTest
@testable import Oriveo

/// Attachments can carry a MIME that does not match their bytes; Anthropic validates bytes against media_type and returns 400.
final class ImageMediaTypeTests: XCTestCase {

    private func b64(_ head: [UInt8]) -> String {
        Data(head + [UInt8](repeating: 0, count: 16)).base64EncodedString()
    }

    private func b64(_ head: String) -> String {
        b64(Array(head.utf8))
    }

    func testRecognisesTheFourFormatsProvidersAccept() {
        XCTAssertEqual(ImageMediaType.sniff(base64: b64([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(ImageMediaType.sniff(base64: b64([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "image/png")
        XCTAssertEqual(ImageMediaType.sniff(base64: b64("GIF89a")), "image/gif")
        XCTAssertEqual(ImageMediaType.sniff(base64: b64("RIFF\0\0\0\0WEBPVP8 ")), "image/webp")
    }

    func testFallsBackToTheDeclaredMimeWhenBytesAreUnknown() {
        XCTAssertNil(ImageMediaType.sniff(base64: b64("RIFF\0\0\0\0WAVEfmt ")))
        XCTAssertEqual(ImageMediaType.resolve(base64: b64("\0\0\0\u{18}ftypheic"), declared: "image/heic"), "image/heic")
        XCTAssertEqual(ImageMediaType.resolve(base64: "", declared: "image/png"), "image/png")
        XCTAssertEqual(ImageMediaType.resolve(base64: "aGk=", declared: "image/png"), "image/png")
    }

    func testLineWrappedBase64StillSniffs() {
        let wrapped = Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 200))
            .base64EncodedString(options: [.lineLength64Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        XCTAssertEqual(ImageMediaType.sniff(base64: wrapped), "image/jpeg")
    }

    func testDataURLOfMislabeledImageCarriesTheRealMime() {
        let jpeg = b64([0xFF, 0xD8, 0xFF, 0xE0])
        let image = Oriveo.Attachment(id: UUID(), kind: .image, fileName: "shot.png", mimeType: "image/png", base64Data: jpeg)
        XCTAssertEqual(image.resolvedDataURL, "data:image/jpeg;base64,\(jpeg)")
    }
}
