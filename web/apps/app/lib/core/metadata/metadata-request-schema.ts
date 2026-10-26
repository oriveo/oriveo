/**
 * The schema version Web requests from /api/metadata (see the model catalog and capability truth contract).
 *
 * Only applies to the index / catalog views: values >= 2 append `&schema=<value>`; =1 leaves the URL byte-for-byte unchanged;
 * lean / by-model / model-facts never carry it. It is not sent as a header (X-Oriveo-Metadata-Schema would trigger a CORS preflight).
 * The production value is 3 (compact catalog); older servers answer with 2 / 1, and every response is decoded by the body metadataSchema.
 */
export const METADATA_REQUEST_SCHEMA: number = 3;

/**
 * Schema suffix for index / catalog URLs; empty string when =1.
 * Callers pass `METADATA_REQUEST_SCHEMA` explicitly, so tests can mock the constant without replacing this function.
 */
export function metadataSchemaQuery(schema: number): string {
  return schema >= 2 ? `&schema=${schema}` : "";
}
