/**
 * Client-side mechanical model id normalization (shared fixture
 * model_id_normalization.v1.json): trim, lowercase, drop everything up to the last
 * "/", drop one trailing date suffix (-YYYY-MM-DD or -YYYYMMDD). Nothing else:
 * -preview / -latest / -all and community names are resolved by the Server alias
 * table, never here. The result is only a lookup key; the wire always sends the id
 * exactly as the connection lists it.
 */

const TRAILING_DATE_SUFFIX = /-(?:\d{4}-\d{2}-\d{2}|\d{8})$/;

export function normalizeModelId(modelId: string): string {
  const lowered = modelId.trim().toLowerCase();
  const lastSlash = lowered.lastIndexOf('/');
  const withoutPrefix = lastSlash >= 0 ? lowered.slice(lastSlash + 1) : lowered;
  return withoutPrefix.replace(TRAILING_DATE_SUFFIX, '');
}
