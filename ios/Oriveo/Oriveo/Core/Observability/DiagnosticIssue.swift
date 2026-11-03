import Foundation

/// Diagnostic registry for the issue channel: matches the shared fixture `diagnostics.issue` (iOS entries) entry for entry; contract tests check both directions.
///
/// Only user-perceivable failures, possible data loss, or anything that needs a human fix open an issue (design doc §4); a successful self-heal counts as a metric,
/// and troubleshooting parameters go to the log. The title is a fixed literal with no interpolated variables; grouping relies on the fingerprint registered here (`SentryReporter.captureMessage`
/// applies the level / fingerprint / module registered here when it receives a registered title, so callers need not (and must not) write them again.
nonisolated enum DiagnosticIssue: String, CaseIterable, Sendable {
    case subscriptionClientVersionRejected = "subscription_client_version_rejected"
    case providerSelfHealExhausted = "provider self-heal param retry exhausted"
    case generatedImageRejected = "Generated image payload was rejected before persistence."
    case firestoreQueueDrainTimeout = "firestore.queue_drain_timeout"
    case firebaseConfigurationInvalid = "Firebase configuration is missing or invalid"
    case syncClockSkew = "sync.clock_skew"
    case backupConvergeDegraded = "backup.converge_degraded"
    case syncConflictCopyMigrationRetry = "sync.conflict_copy_migration_retry"
    /// The main thread asked for a partition database that was not pre-opened in the background (a leak-through path): the DB is temporarily unavailable and the feature degrades; grouped by caller.
    case databaseNotPreparedOnMain = "db.not_prepared_on_main"
    /// A retired partition pool failed its real `close()` (e.g. BUSY): the connection stays open, grouped by store.
    case databaseCloseFailed = "db.close_failed"
    /// A partition directory was removed while its uid still had a database connection open, grouped by partition kind.
    case databasePartitionRemovedWhileOpen = "db.partition_removed_while_open"

    var level: ObservabilityLevel {
        switch self {
        case .firebaseConfigurationInvalid: return .error
        default: return .warning
        }
    }

    var module: String {
        switch self {
        case .subscriptionClientVersionRejected: return "subscription"
        case .providerSelfHealExhausted: return "provider.self_heal"
        case .generatedImageRejected: return "chat"
        case .firestoreQueueDrainTimeout: return "sync.recovery"
        case .firebaseConfigurationInvalid: return "auth"
        case .syncClockSkew, .syncConflictCopyMigrationRetry: return "sync"
        case .backupConvergeDegraded: return "backup"
        case .databaseNotPreparedOnMain, .databaseCloseFailed, .databasePartitionRemovedWhileOpen: return "persistence"
        }
    }

    /// Fingerprint template; `{key}` is filled from the tag with the same name (filled with `unknown` when missing).
    var fingerprintTemplate: [String] {
        switch self {
        case .subscriptionClientVersionRejected: return ["subscription_client_version_rejected"]
        case .providerSelfHealExhausted: return ["provider.self_heal.exhausted"]
        case .generatedImageRejected: return ["chat.generated_image_rejected"]
        case .firestoreQueueDrainTimeout: return ["firestore.queue_drain_timeout"]
        case .firebaseConfigurationInvalid: return ["firebase.configuration_invalid"]
        case .syncClockSkew: return ["sync.clock_skew"]
        case .backupConvergeDegraded: return ["backup.converge_degraded", "{stage}"]
        case .syncConflictCopyMigrationRetry: return ["sync.conflict_copy_migration_retry"]
        case .databaseNotPreparedOnMain: return ["db.not_prepared_on_main", "{db.caller}"]
        case .databaseCloseFailed: return ["db.close_failed", "{db.store}"]
        case .databasePartitionRemovedWhileOpen: return ["db.partition_removed_while_open", "{db.partition}"]
        }
    }

    func fingerprint(tags: [String: String]) -> [String] {
        fingerprintTemplate.map { part in
            guard part.hasPrefix("{"), part.hasSuffix("}") else { return part }
            return tags[String(part.dropFirst().dropLast())] ?? "unknown"
        }
    }
}

/// Outcome of the previous process (crashed or not). Business code only uses this type and never touches the SDK's `SentryLastRunStatus` directly.
nonisolated enum ObservabilityLastRunStatus: Sendable, CustomStringConvertible {
    case didCrash
    case didNotCrash
    case unknown

    var description: String {
        switch self {
        case .didCrash: return "didCrash"
        case .didNotCrash: return "didNotCrash"
        case .unknown: return "unknown"
        }
    }
}
