package ai.oriveo.community.core.search

/**
 * Production signature verification public keys for the external search catalog (GET /api/metadata?view=search): keyId → base64 of the 32-byte raw Ed25519 public key.
 * Matches productionKeys in shared/search-contracts/search_catalog_contract.v1.json (checked by search-contracts-check);
 * testKeys in the fixture are trusted only in tests. The private key lives only in the maintainer's keychain (scripts/search-catalog-sign.mjs).
 */
object SearchCatalogKeys {
    val production: Map<String, String> = mapOf(
        "prod-2026-10" to "5Fo/ncB5euOXDYwMN8s8SWDkPPTw5itMBa10j1/JoFU=",
    )
}
