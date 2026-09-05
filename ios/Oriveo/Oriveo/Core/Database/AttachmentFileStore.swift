import Foundation

final class AttachmentFileStore: @unchecked Sendable {
    private let rootDirectory: URL

    nonisolated init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    nonisolated func saveBase64(_ base64Data: String, for id: String) throws -> String {
        guard let data = Data(base64Encoded: base64Data) else {
            throw AttachmentFileStoreError.invalidBase64Data
        }
        try ensureDirectory()
        try data.write(to: fileURL(for: id), options: .atomic)
        return id
    }

    nonisolated func loadBase64(for id: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return data.base64EncodedString()
    }

    nonisolated func exists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    nonisolated func deleteFile(for id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    nonisolated func prune(keeping ids: Set<String>) {
        try? ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where !ids.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    nonisolated private func fileURL(for id: String) -> URL {
        rootDirectory.appendingPathComponent("\(id).bin")
    }

    nonisolated private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }
}

enum AttachmentFileStoreError: Error {
    case invalidBase64Data
}
