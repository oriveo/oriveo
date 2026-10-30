import Foundation

/// Production signature-verification public keys for the external search catalog (GET /api/metadata?view=search): keyId -> base64 of the raw 32-byte Ed25519 public key.
/// Matches productionKeys in shared/search-contracts/search_catalog_contract.v1.json (checked by search-contracts-check);
/// testKeys in the fixtures are trusted only in tests. The private key lives only in the maintainer's keychain (scripts/search-catalog-sign.mjs).
nonisolated enum SearchCatalogKeys {
    static let production: [String: String] = [
        "prod-2026-10": "5Fo/ncB5euOXDYwMN8s8SWDkPPTw5itMBa10j1/JoFU=",
    ]
}
