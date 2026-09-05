import CoreText
import Testing
import UIKit
@testable import Oriveo

@Suite("Brand Font Installation Tests")
struct BrandFontInstallationTests {
    private static let fontFileName = "PlusJakartaSans-Bold"
    private static let fontExtension = "ttf"
    private static let postScriptName = "PlusJakartaSans-Bold"

    @Test("App Bundle Contains Plus Jakarta Sans Bold Font File")
    func appBundleContainsPlusJakartaSansBoldFontFile() throws {
        let fontURL = try #require(
            Self.appBundle.url(forResource: Self.fontFileName, withExtension: Self.fontExtension)
        )

        #expect(fontURL.lastPathComponent == "\(Self.fontFileName).\(Self.fontExtension)")
    }

    @Test("Plus Jakarta Sans Bold Font Can Be Loaded")
    func plusJakartaSansBoldFontCanBeLoaded() throws {
        let fontURL = try #require(
            Self.appBundle.url(forResource: Self.fontFileName, withExtension: Self.fontExtension)
        )
        Self.registerFontIfNeeded(at: fontURL)
        let font = UIFont(name: Self.postScriptName, size: 22)

        #expect(font != nil)
    }

    private static var appBundle: Bundle {
        let testBundle = Bundle(for: BrandFontBundleLocator.self)
        let embeddedAppURL = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        if embeddedAppURL.pathExtension == "app",
           let bundle = Bundle(url: embeddedAppURL) {
            return bundle
        }

        return Bundle.allBundles.first(where: { $0.bundleURL.pathExtension == "app" }) ?? Bundle.main
    }

    private static func registerFontIfNeeded(at fontURL: URL) {
        guard UIFont(name: postScriptName, size: 22) == nil else { return }
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }
}

private final class BrandFontBundleLocator {}
