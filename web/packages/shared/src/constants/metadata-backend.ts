/**
 * Default host of the public model catalog.
 *
 * The catalog describes which models each provider offers and what they support, and it is
 * published so that a new model shows up without shipping a new build. Exactly two read-only
 * endpoints are ever requested from this host: `GET /api/metadata?view=lean` and
 * `GET /api/metadata/model-facts`. Both are conditional GETs carrying only `If-None-Match`; no
 * API key, conversation, or user identifier is sent with either, and nothing is ever posted back.
 *
 * Set NEXT_PUBLIC_BACKEND_URL to point the app at a self-hosted catalog instead.
 */
export const PUBLIC_METADATA_BASE_URL = 'https://api.oriveoai.com';
