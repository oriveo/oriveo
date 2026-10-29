import Foundation
import GRDB

/// The threshold for "the device is out of storage".
let storageFullThresholdBytes: Int64 = 10 * 1024 * 1024

/// The verdict on a storage failure.
enum StorageFailureVerdict: Equatable {
    /// The device really has no room. A device condition, not a bug in this app.
    case deviceStorageFull(freeBytesBucket: String)
    /// It failed with space to spare: a local fault (corruption, migration, permissions).
    case genuineFailure(freeBytesBucket: String)

    var freeBytesBucket: String {
        switch self {
        case let .deviceStorageFull(bucket), let .genuineFailure(bucket):
            return bucket
        }
    }

    /// Whether this is something in the app rather than the state of the device.
    var isLocalFault: Bool {
        switch self {
        case .deviceStorageFull: return false
        case .genuineFailure: return true
        }
    }
}

/// A bucket rather than the exact byte count: exact free space is part of a device fingerprint,
/// and a range is enough for anything this is used for.
func storageFreeBytesBucket(_ availableBytes: Int64?) -> String {
    guard let availableBytes else { return "unknown" }
    if availableBytes <= 0 { return "0" }
    if availableBytes < storageFullThresholdBytes { return "<10MB" }
    if availableBytes < 100 * 1024 * 1024 { return "<100MB" }
    return ">=100MB"
}

/// Cocoa file errors that really do mean "the write did not go through".
/// 640 = NSFileWriteOutOfSpaceError, 642 = NSFileWriteVolumeReadOnlyError,
/// 512 = NSFileWriteUnknownError (a full disk degrades into it on some paths).
private let storageRelatedCocoaCodes: Set<Int> = [512, 640, 642]

/// POSIX errno values that mean the same.
/// 28 = ENOSPC, 5 = EIO, 69 = EDQUOT, 30 = EROFS.
private let storageRelatedPOSIXCodes: Set<Int> = [5, 28, 30, 69]

/// Whether this error belongs to the "storage access failed" family.
///
/// This is the coarse filter: only this family is then judged by free space, so that an unrelated
/// bug is never written off as "the device is full" just because the device happens to be full.
///
/// ## Why not the whole NSCocoaErrorDomain
///
/// That domain is far more than file writes: Swift bridges `DecodingError` / `EncodingError` into
/// NSCocoaErrorDomain 4864–4866, and `NSPropertyListReadCorruptError`, `NSFileReadNoSuchFileError`
/// and permission errors all live there too. Let the whole domain through and a genuine encoding
/// bug on a low-space device is classified as "out of space" and quietly written off — exactly
/// what this file promises will not happen.
///
/// So the family is drawn narrowly: GRDB's `DatabaseError` passes as a whole (a full disk really
/// does surface as several SQLite codes — `SQLITE_FULL(13)` and `SQLITE_IOERR(10)` both occur),
/// while the file layer only accepts the codes that specifically mean "could not write".
func isStorageAccessFailure(_ error: Error) -> Bool {
    if error is DatabaseError { return true }

    var cursor: NSError? = error as NSError
    var depth = 0
    while let current = cursor, depth < 4 {
        switch current.domain {
        case NSCocoaErrorDomain where storageRelatedCocoaCodes.contains(current.code):
            return true
        case NSPOSIXErrorDomain where storageRelatedPOSIXCodes.contains(current.code):
            return true
        default:
            break
        }
        cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    return false
}

/// The errors that by themselves mean "the device is out of space": NSFileWriteOutOfSpaceError (640),
/// ENOSPC (28), EDQUOT (69) and `SQLITE_FULL` (13). They can only come from space running out at the
/// moment of the write, unlike `SQLITE_IOERR` / EIO, which also carry bad blocks and read-only
/// filesystems, so there is no need to guess from free space.
func isUnambiguousOutOfSpace(_ error: Error) -> Bool {
    if let dbError = error as? DatabaseError {
        return dbError.resultCode == .SQLITE_FULL
    }
    var cursor: NSError? = error as NSError
    var depth = 0
    while let current = cursor, depth < 4 {
        switch current.domain {
        case NSCocoaErrorDomain where current.code == NSFileWriteOutOfSpaceError:
            return true
        case NSPOSIXErrorDomain where current.code == Int(ENOSPC) || current.code == Int(EDQUOT):
            return true
        default:
            break
        }
        cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    return false
}

/// Judge a storage failure.
///
/// Past the coarse filter the error itself comes first: an unambiguous out-of-space code
/// (`isUnambiguousOutOfSpace`) reads as device storage full straight away. The rest of the family
/// (`SQLITE_IOERR` also carries bad blocks and read-only filesystems, and a full disk while WAL
/// creates its -shm file only shows 10) is judged by how much room the device has left.
///
/// ## A known, accepted misread
///
/// Below the threshold, a **corrupt database** also reads as "out of space": on a device that low
/// the two cannot be told apart from the error itself, and low space makes SQLite throw all sorts.
/// The cost is one missed signal; the offset is that once the user frees space and it still fails,
/// the next attempt lands as `.genuineFailure`.
///
/// - Returns: `nil` when the failure is not a storage access failure. The caller must then handle
///   it the way it otherwise would, and must not swallow it.
func triageStorageFailure(
    _ error: Error,
    availableBytes: @autoclosure () -> Int64?
) -> StorageFailureVerdict? {
    // Coarse filter first: outside the family this returns before `availableBytes` is evaluated.
    guard isStorageAccessFailure(error) else { return nil }
    let availableBytes = availableBytes()
    let bucket = storageFreeBytesBucket(availableBytes)
    // The kernel said "no space" at the moment of the write, which beats measuring again afterwards:
    // a failed atomic write deletes its temporary file and the system may have just purged caches,
    // so free space measured later can be far above what it was during the write.
    if isUnambiguousOutOfSpace(error) {
        return .deviceStorageFull(freeBytesBucket: bucket)
    }
    // With no reading for free space, treat it as "space to spare": better one extra report than
    // a real fault hidden away.
    guard let availableBytes, availableBytes < storageFullThresholdBytes else {
        return .genuineFailure(freeBytesBucket: bucket)
    }
    return .deviceStorageFull(freeBytesBucket: bucket)
}

/// How many bytes the app container can still write.
///
/// Uses `volumeAvailableCapacity`, the filesystem's plain free space right now. Not
/// `volumeAvailableCapacityForImportantUsage`: it counts caches the system *could* reclaim, but an
/// ordinary file write does not wait for that, so it can still report hundreds of MB after the kernel
/// has already returned ENOSPC, misreading a full disk as an app fault.
func availableStorageBytesForAppContainer() -> Int64? {
    guard let url = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    ) else { return nil }

    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    return values?.volumeAvailableCapacity.map(Int64.init)
}
