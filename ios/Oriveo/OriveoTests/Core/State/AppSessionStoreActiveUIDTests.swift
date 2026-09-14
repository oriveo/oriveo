import Foundation
import Testing
@testable import Oriveo

@Suite("AppSessionStore active uid", .serialized)
struct AppSessionStoreActiveUIDTests {
    @Test("the active uid is cached per process: repeated reads skip the file, writes are visible immediately and persisted")
    func activeUIDIsCachedAndWrittenThrough() throws {
        let previousUID = AppSessionStore.activeUID
        defer { AppSessionStore.activeUID = previousUID }

        let uid = "active-uid-cache-\(UUID().uuidString)"
        AppSessionStore.activeUID = uid
        let file = AppSessionStore.baseDir.appendingPathComponent("active-uid")
        #expect(try String(contentsOf: file, encoding: .utf8) == uid)

        // Opening the file on every read, for comparison. Wall time is only printed;
        // the assertions pin disk reads.
        let lookups = 10_000
        let uncachedStart = Date()
        for _ in 0..<lookups {
            AppSessionStore.dropActiveUIDCacheForTesting()
            _ = AppSessionStore.activeUID
        }
        let uncachedElapsed = Date().timeIntervalSince(uncachedStart)

        let readsBefore = AppSessionStore.debugActiveUIDDiskReadCount
        var mismatches = 0
        let cachedStart = Date()
        for _ in 0..<lookups where AppSessionStore.activeUID != uid {
            mismatches += 1
        }
        let cachedElapsed = Date().timeIntervalSince(cachedStart)
        print("""
        [HANG-COST] activeUID x \(lookups) reads: \
        file read each time \(String(format: "%.1f", uncachedElapsed * 1000))ms, cached \(String(format: "%.1f", cachedElapsed * 1000))ms
        """)
        #expect(mismatches == 0)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount - readsBefore <= 1)

        // A blank value and a missing file both normalize to guest, cached or read back from disk.
        AppSessionStore.activeUID = "  \n"
        #expect(AppSessionStore.activeUID == "guest")
        AppSessionStore.dropActiveUIDCacheForTesting()
        #expect(AppSessionStore.activeUID == "guest")

        let switched = "active-uid-switch-\(UUID().uuidString)"
        AppSessionStore.activeUID = switched
        #expect(AppSessionStore.activeUID == switched)
        AppSessionStore.dropActiveUIDCacheForTesting()
        #expect(AppSessionStore.activeUID == switched)
    }
}
