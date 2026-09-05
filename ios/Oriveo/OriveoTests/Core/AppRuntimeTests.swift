import Foundation
import Testing
@testable import Oriveo

@Suite("App Runtime", .serialized)
struct AppRuntimeTests {
    @Test("Recognizes Hosted Tests Without Environment Variable")
    func recognizesHostedTestsWithoutEnvironmentVariable() {
        let key = "XCTestConfigurationFilePath"
        let previousValue = getenv(key).map { String(cString: $0) }

        unsetenv(key)
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            }
        }

        #expect(AppRuntime.isRunningTests == true)
    }

    @Test("Recognizes Hosted Tests With Empty Configuration Path")
    func recognizesHostedTestsWithEmptyConfigurationPath() {
        #expect(
            AppRuntime.isRunningTests(
                environment: [
                    "XCTestConfigurationFilePath": "   ",
                    "XCTestBundlePath": "PlugIns/OriveoTests.xctest",
                ],
                hasXCTestCaseClass: false
            ) == true
        )
    }

    @Test("Recognizes Hosted Tests With Session Identifier")
    func recognizesHostedTestsWithSessionIdentifier() {
        #expect(
            AppRuntime.isRunningTests(
                environment: [
                    "XCTestConfigurationFilePath": "",
                    "XCTestSessionIdentifier": "D817B665-202C-47B0-931D-11B5B3CCB16A",
                ],
                hasXCTestCaseClass: false
            ) == true
        )
    }

    @Test("Recognizes Preview Runtime")
    func recognizesPreviewRuntime() {
        #expect(
            AppRuntime.isRunningPreviews(
                environment: [
                    "XCODE_RUNNING_FOR_PREVIEWS": "1",
                ]
            ) == true
        )
    }

    @Test("Declared Fonts Exist In Main Bundle")
    func declaredFontsExistInMainBundle() {
        let declaredFonts = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String] ?? []

        for fontFile in declaredFonts {
            let fontPath = fontFile as NSString
            let url = Bundle.main.url(
                forResource: fontPath.deletingPathExtension,
                withExtension: fontPath.pathExtension
            )
            #expect(url != nil)
        }
    }
}
