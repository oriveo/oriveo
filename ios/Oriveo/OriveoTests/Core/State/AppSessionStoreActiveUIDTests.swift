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

    @Test("Cold read with mirror: after dropping the process cache, reading the active uid does not read the file")
    func coldReadWithMirrorTouchesNoDisk() {
        let previousUID = AppSessionStore.activeUID
        defer { AppSessionStore.activeUID = previousUID }

        let uid = "active-uid-mirror-\(UUID().uuidString)"
        AppSessionStore.activeUID = uid
        #expect(UserDefaults.standard.string(forKey: AppSessionStore.activeUIDMirrorKey) == uid)

        AppSessionStore.dropActiveUIDCacheForTesting()
        let readsBefore = AppSessionStore.debugActiveUIDDiskReadCount
        #expect(AppSessionStore.activeUID == uid)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore)
    }

    @Test("First launch after upgrade with no mirror: read the file once and backfill the mirror; later cold reads do not read the file")
    func upgradeFirstLaunchReadsFileOnceThenMirrors() throws {
        let previousUID = AppSessionStore.activeUID
        defer { AppSessionStore.activeUID = previousUID }

        let uid = "active-uid-upgrade-\(UUID().uuidString)"
        AppSessionStore.activeUID = uid
        // Simulate old version: file only, no mirror.
        UserDefaults.standard.removeObject(forKey: AppSessionStore.activeUIDMirrorKey)
        AppSessionStore.dropActiveUIDCacheForTesting()

        let readsBefore = AppSessionStore.debugActiveUIDDiskReadCount
        #expect(AppSessionStore.activeUID == uid)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore + 1)
        #expect(UserDefaults.standard.string(forKey: AppSessionStore.activeUIDMirrorKey) == uid)

        AppSessionStore.dropActiveUIDCacheForTesting()
        #expect(AppSessionStore.activeUID == uid)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore + 1)

        // The file is still the source of truth: the setter writes both.
        let file = AppSessionStore.baseDir.appendingPathComponent("active-uid")
        #expect(try String(contentsOf: file, encoding: .utf8) == uid)
    }

    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    @Test("Mirror from another build: do not trust the mirror; read the file once and backfill mirror and build")
    func mirrorFromOtherBuildIsDistrusted_readsFileOnce() throws {
        let previousUID = AppSessionStore.activeUID
        defer { AppSessionStore.activeUID = previousUID }

        let fileUID = "active-uid-file-\(UUID().uuidString)"
        AppSessionStore.activeUID = fileUID
        // Simulate downgrading to an old version that only writes the file, then upgrading again: the mirror stays on the old account and build is a different version.
        let staleUID = "active-uid-stale-\(UUID().uuidString)"
        UserDefaults.standard.set(staleUID, forKey: AppSessionStore.activeUIDMirrorKey)
        UserDefaults.standard.set("other-build", forKey: AppSessionStore.activeUIDMirrorBuildKey)
        AppSessionStore.dropActiveUIDCacheForTesting()

        let readsBefore = AppSessionStore.debugActiveUIDDiskReadCount
        #expect(AppSessionStore.activeUID == fileUID)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore + 1)
        #expect(UserDefaults.standard.string(forKey: AppSessionStore.activeUIDMirrorKey) == fileUID)
        #expect(UserDefaults.standard.string(forKey: AppSessionStore.activeUIDMirrorBuildKey) == currentBuild)

        // A mirror missing the build field is treated as a different build.
        UserDefaults.standard.set(staleUID, forKey: AppSessionStore.activeUIDMirrorKey)
        UserDefaults.standard.removeObject(forKey: AppSessionStore.activeUIDMirrorBuildKey)
        AppSessionStore.dropActiveUIDCacheForTesting()
        #expect(AppSessionStore.activeUID == fileUID)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore + 2)

        // After backfill, later cold reads do not read the file.
        AppSessionStore.dropActiveUIDCacheForTesting()
        #expect(AppSessionStore.activeUID == fileUID)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore + 2)
    }

    @Test("Logged out but mirror points to an account: do not trust the mirror entry; read the file once and return to guest")
    func loggedOutWithAccountMirrorReadsFile() throws {
        let previousUID = AppSessionStore.activeUID
        defer { AppSessionStore.activeUID = previousUID }

        let accountUID = "active-uid-account-\(UUID().uuidString)"
        AppSessionStore.activeUID = accountUID
        // Simulate logout writing the file, with the mirror not flushed when power is lost: the file is guest, the mirror still points to the account.
        let file = AppSessionStore.baseDir.appendingPathComponent("active-uid")
        try "guest".write(to: file, atomically: true, encoding: .utf8)
        AppSessionStore.dropActiveUIDCacheForTesting()
        // Before cold start, earlier reads may have pulled the suspicious mirror into cache: the entry point must not trust the cache either.
        #expect(AppSessionStore.activeUID == accountUID)

        let readsBefore = AppSessionStore.debugActiveUIDDiskReadCount
        #expect(AppSessionStore.activeUIDDistrustingMirror() == "guest")
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore + 1)
        #expect(AppSessionStore.activeUID == "guest")
        #expect(UserDefaults.standard.string(forKey: AppSessionStore.activeUIDMirrorKey) == "guest")
    }

    @Test("Normal cold start: use the same-build mirror directly; logged out with mirror as guest also does not read the file")
    func normalColdReadStillTouchesNoDisk() {
        let previousUID = AppSessionStore.activeUID
        defer { AppSessionStore.activeUID = previousUID }

        let uid = "active-uid-normal-\(UUID().uuidString)"
        AppSessionStore.activeUID = uid
        #expect(UserDefaults.standard.string(forKey: AppSessionStore.activeUIDMirrorBuildKey) == currentBuild)
        AppSessionStore.dropActiveUIDCacheForTesting()
        let readsBefore = AppSessionStore.debugActiveUIDDiskReadCount
        #expect(AppSessionStore.activeUID == uid)
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore)

        AppSessionStore.activeUID = "guest"
        AppSessionStore.dropActiveUIDCacheForTesting()
        #expect(AppSessionStore.activeUIDDistrustingMirror() == "guest")
        #expect(AppSessionStore.activeUID == "guest")
        #expect(AppSessionStore.debugActiveUIDDiskReadCount == readsBefore)
    }

    @Test("baseDir only computes the path and does not create the directory")
    func baseDirDoesNotCreateDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("base-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = AppSessionStore.baseDir(under: root)
        #expect(dir.lastPathComponent == "Oriveo")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(AppSessionStore.baseDir == AppSessionStore.baseDir(under: appSupport))
    }
}
