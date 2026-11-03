import Foundation

/// Diagnostic exit for "the main thread asked for a partition database that was not pre-opened"
/// (`DatabaseManager.openIfNeeded`): each caller records one issue (registered `db.not_prepared_on_main`,
/// grouped by caller) plus one count per process, without crashing.
@MainActor
enum DatabaseOpenDiagnostics {
    static let metric = "db.not_prepared_on_main"
    /// Tests swap in a recording sink.
    static var sink: ObservabilitySink = Observability.sink
    private static var reportedCallers = Set<String>()

    static func reportNotPreparedOnMain(caller: String) {
        guard reportedCallers.insert(caller).inserted else { return }
        let issue = DiagnosticIssue.databaseNotPreparedOnMain
        let tags = ["db.caller": caller]
        sink.issue(name: issue.rawValue, level: issue.level, fingerprint: issue.fingerprint(tags: tags), context: tags)
        sink.count("db.not_prepared_on_main", value: 1, tags: tags)
    }

    #if DEBUG
    static func resetForTesting() {
        reportedCallers = []
    }
    #endif
}
