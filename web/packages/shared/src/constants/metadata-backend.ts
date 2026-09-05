/**
 * Default host of the public model catalog.
 *
 * The catalog describes which models each provider offers and what they support, and it is
 * published so that a new model shows up without shipping a new build. Only the read-only
 * catalog endpoints are ever requested from this host: `/api/metadata`,
 * `/api/metadata/model-facts` and `/api/metadata/self-heal-events`. No API key, conversation or
 * user identifier is sent with them.
 *
 * Set NEXT_PUBLIC_BACKEND_URL to point the app at a self-hosted catalog instead.
 */
export const PUBLIC_METADATA_BASE_URL = 'https://api.oriveoai.com';
