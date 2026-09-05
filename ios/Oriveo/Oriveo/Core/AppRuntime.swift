import Foundation

enum AppRuntime {
    private static let hostedTestEnvironmentKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
    ]
    private static let previewEnvironmentKey = "XCODE_RUNNING_FOR_PREVIEWS"

    static var isRunningTests: Bool {
        isRunningTests(
            environment: ProcessInfo.processInfo.environment,
            hasXCTestCaseClass: NSClassFromString("XCTestCase") != nil
        )
    }

    static var isRunningPreviews: Bool {
        isRunningPreviews(environment: ProcessInfo.processInfo.environment)
    }

    static func isRunningTests(
        environment: [String: String],
        hasXCTestCaseClass: Bool
    ) -> Bool {
        if hostedTestEnvironmentKeys.contains(where: { hasNonEmptyEnvironmentValue($0, in: environment) }) {
            return true
        }

        return hasXCTestCaseClass
    }

    static func isRunningPreviews(environment: [String: String]) -> Bool {
        normalizedEnvironmentValue(for: previewEnvironmentKey, in: environment) == "1"
    }

    private static func hasNonEmptyEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> Bool {
        guard let value = normalizedEnvironmentValue(for: key, in: environment) else {
            return false
        }

        return !value.isEmpty
    }

    private static func normalizedEnvironmentValue(
        for key: String,
        in environment: [String: String]
    ) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        return value
    }
}
