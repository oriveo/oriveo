import Foundation

enum BoundedFileReadError: Error, Equatable {
    case notRegularFile
    case tooLarge
}

nonisolated enum BoundedFileReader {
    static func data(at url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw BoundedFileReadError.tooLarge }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw BoundedFileReadError.notRegularFile
        }
        if let fileSize = values.fileSize, fileSize > maxBytes {
            throw BoundedFileReadError.tooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = Data()
        result.reserveCapacity(min(max(values.fileSize ?? 0, 0), maxBytes))
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            guard chunk.count <= maxBytes,
                  result.count <= maxBytes - chunk.count else {
                throw BoundedFileReadError.tooLarge
            }
            result.append(chunk)
        }
        return result
    }
}
