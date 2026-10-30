/**
 * Production signature-verification public keys for the external search catalog (GET /api/metadata?view=search): keyId -> base64 of the raw 32-byte Ed25519 public key.
 * Must match productionKeys in search_catalog_contract.v1.json in the shared search-contracts directory (checked by search-contracts-check);
 * testKeys in the fixture are trusted in tests only. The private key lives only in the maintainer's keychain (scripts/search-catalog-sign.mjs).
 */
export const SEARCH_CATALOG_PRODUCTION_KEYS: Readonly<Record<string, string>> = Object.freeze({
  'prod-2026-10': '5Fo/ncB5euOXDYwMN8s8SWDkPPTw5itMBa10j1/JoFU=',
});
