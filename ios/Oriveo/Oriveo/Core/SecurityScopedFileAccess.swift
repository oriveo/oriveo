import Foundation

nonisolated enum SecurityScopedFileAccess {
    static func withAccess<T>(to url: URL, _ work: () throws -> T) throws -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}
