import CryptoKit
import Foundation

enum DeterministicProviderID {

    private static let namespaceBytes: [UInt8] = [
        0x9A, 0x11, 0x95, 0xDE, 0x3A, 0xF9, 0x58, 0x88,
        0xAB, 0xC8, 0xB8, 0x17, 0x7C, 0x45, 0x8C, 0x07,
    ]

    /// - Parameters:
    static func make(kind: ProviderKind, regionID: String) -> UUID {
        let identityRegionID = kind == .siliconFlow && regionID == "cn" ? "" : regionID
        let name = "\(kind.rawValue)|\(identityRegionID)"
        return makeV5(name: name)
    }

    /// The region segment of the deterministic id (shared by registration and migration grouping): looks only at the frozen identity table.
    /// A `region:<id>` source whose id is in the table wins; otherwise the baseURLText is normalized and looked up
    /// (falling back to the first entry on a miss); a provider outside the table returns an empty string.
    static func regionID(
        for kind: ProviderKind,
        baseURLText: String?,
        endpointSource: ProviderEndpointSource? = nil,
        setupCatalog: ProviderSetupCatalog
    ) -> String {
        setupCatalog.identityRegionID(for: kind, baseURLText: baseURLText, endpointSource: endpointSource)
    }

    // MARK: - UUIDv5(SHA-1)

    static func makeV5(name: String) -> UUID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(namespaceBytes))
        hasher.update(data: Data(name.utf8))
        let digest = hasher.finalize()

        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let uuidString =
            "\(hex.prefix(8))-"
            + "\(hex.dropFirst(8).prefix(4))-"
            + "\(hex.dropFirst(12).prefix(4))-"
            + "\(hex.dropFirst(16).prefix(4))-"
            + "\(hex.dropFirst(20))"
        return UUID(uuidString: uuidString)!
    }
}
