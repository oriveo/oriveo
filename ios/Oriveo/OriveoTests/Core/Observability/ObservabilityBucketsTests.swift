import Foundation
import Testing
@testable import Oriveo

/// Bucket boundaries and labels align entry by entry with the shared fixture `buckets`: both sides read the same cases, and bucket names match character for character.
@Suite("ObservabilityBuckets")
struct ObservabilityBucketsTests {
    private func spec(_ name: String) throws -> [String: Any] {
        let fixture = try TelemetryContractFixture.load()
        let buckets = try #require(fixture["buckets"] as? [String: Any])
        return try #require(buckets[name] as? [String: Any])
    }

    private func check(_ name: String, edges: [Double], labels: [String], bucket: (Double) -> String) throws {
        let spec = try spec(name)
        #expect((spec["edges"] as? [Double]) == edges)
        #expect((spec["labels"] as? [String]) == labels)
        let cases = try #require(spec["cases"] as? [[Any]])
        #expect(!cases.isEmpty)
        for entry in cases {
            let value = try #require((entry.first as? NSNumber)?.doubleValue)
            let label = try #require(entry.last as? String)
            #expect(bucket(value) == label, "\(name)(\(value)) should be \(label)")
        }
    }

    @Test("count buckets")
    func countBuckets() throws {
        try check(
            "count",
            edges: ObservabilityBuckets.countEdges,
            labels: ObservabilityBuckets.countLabels
        ) { ObservabilityBuckets.count(Int($0)) }
    }

    @Test("size (MB) buckets")
    func sizeBuckets() throws {
        try check(
            "size_mb",
            edges: ObservabilityBuckets.sizeMBEdges,
            labels: ObservabilityBuckets.sizeMBLabels
        ) { ObservabilityBuckets.sizeMB($0) }
    }

    @Test("height (pt) buckets; non-finite values form their own bucket")
    func heightBuckets() throws {
        try check(
            "height_pt",
            edges: ObservabilityBuckets.heightPtEdges,
            labels: ObservabilityBuckets.heightPtLabels
        ) { ObservabilityBuckets.heightPt($0) }
        let spec = try spec("height_pt")
        #expect(spec["non_finite_label"] as? String == ObservabilityBuckets.nonFiniteLabel)
        #expect(ObservabilityBuckets.heightPt(.nan) == ObservabilityBuckets.nonFiniteLabel)
        #expect(ObservabilityBuckets.heightPt(.infinity) == ObservabilityBuckets.nonFiniteLabel)
    }
}
