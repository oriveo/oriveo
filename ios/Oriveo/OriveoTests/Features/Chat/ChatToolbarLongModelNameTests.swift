import Foundation
import Testing

@Suite("ChatToolbar long model names")
struct ChatToolbarLongModelNameTests {

    @Test("Toolbar Model Title Uses Two Lines")
    func toolbarModelTitleUsesTwoLines() throws {
        let source = try String(contentsOf: chatSourceURL("ChatToolbar.swift"), encoding: .utf8)
        let titleSource = try source.requiredSlice(
            from: "Text(currentModel?.name ?? L10n.tr(\"Choose Model\"))",
            to: "HStack(spacing: 4)"
        )

        #expect(titleSource.contains(".lineLimit(2)"))
        #expect(titleSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(titleSource.contains(".layoutPriority(1)"))
    }

    private func chatSourceURL(_ filename: String) -> URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Chat")
            .appendingPathComponent(filename)
    }
}

private extension String {
    func requiredSlice(from start: String, to end: String) throws -> String {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            throw SliceError.missingBoundary
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}

private enum SliceError: Error {
    case missingBoundary
}
