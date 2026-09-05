/**
 * Success-shape decision for a relay 1-token generation.
 * HTTP 2xx is the primary signal, excluding only clearly identifiable HTML fallback pages. A real
 * relay may answer with SSE, an empty body or another non-JSON success response, so JSON shape,
 * let alone a 2xx error body, must not replace HTTP semantics.
 */
export function isRelayGenerationSuccessResponse(body: string, contentType?: string | null): boolean {
  const normalizedType = contentType?.toLowerCase() ?? '';
  if (normalizedType.includes('text/html') || normalizedType.includes('application/xhtml+xml')) return false;
  const text = body.replace(/^\uFEFF/, '').trim();
  return !/^(?:<!doctype\s+html\b|<html\b|<head\b|<body\b)/i.test(text);
}
