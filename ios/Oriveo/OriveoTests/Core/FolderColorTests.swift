import Testing
import Foundation
@testable import Oriveo

@Suite("FolderColor")
struct FolderColorTests {


    @Test("All Colors Exist")
    func allColorsExist() {
        #expect(FolderColor.allCases.count == 10)
        #expect(FolderColor.ordered.count == 10)
    }

    @Test("From Valid Tag")
    func fromValidTag() {
        #expect(FolderColor.from("blue") == .blue)
        #expect(FolderColor.from("pink") == .pink)
        #expect(FolderColor.from("gray") == .gray)
    }

    @Test("from fallback: nil → blue")
    func fromNil() {
        #expect(FolderColor.from(nil) == .blue)
    }

    @Test("From Unknown")
    func fromUnknown() {
        #expect(FolderColor.from("neon") == .blue)
    }

    // MARK: - nextColor

    @Test("Next Color Empty")
    func nextColorEmpty() {
        #expect(FolderColor.nextColor(after: []) == .blue)
    }

    @Test("Next Color After Blue")
    func nextColorAfterBlue() {
        let folders = [Folder(id: UUID(), name: "A", sortOrder: 1000, colorTag: "blue")]
        #expect(FolderColor.nextColor(after: folders) == .purple)
    }

    @Test("Next Color Wraps Around")
    func nextColorWrapsAround() {
        let folders = [Folder(id: UUID(), name: "A", sortOrder: 1000, colorTag: "gray")]
        #expect(FolderColor.nextColor(after: folders) == .blue)
    }

    @Test("Next Color Uses Sort Order")
    func nextColorUsesSortOrder() {
        let folders = [
            Folder(id: UUID(), name: "A", sortOrder: 2000, colorTag: "red"),
            Folder(id: UUID(), name: "B", sortOrder: 1000, colorTag: "blue"),
            Folder(id: UUID(), name: "C", sortOrder: 3000, colorTag: "green"),
        ]
        #expect(FolderColor.nextColor(after: folders) == .teal)
    }

    @Test("Sequential Ten Folders")
    func sequentialTenFolders() {
        var folders: [Folder] = []
        for i in 0..<10 {
            let color = FolderColor.nextColor(after: folders)
            folders.append(Folder(
                id: UUID(),
                name: "F\(i)",
                sortOrder: (i + 1) * 1000,
                colorTag: color.rawValue
            ))
        }
        let tags = folders.map(\.colorTag)
        let expected = FolderColor.ordered.map(\.rawValue)
        #expect(tags == expected)
    }


    @Test("Gradient Colors Length")
    func gradientColorsLength() {
        for color in FolderColor.allCases {
            #expect(color.gradientColors.count == 2)
        }
    }
}
