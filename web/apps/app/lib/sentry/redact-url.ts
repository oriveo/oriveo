/**
 * Replace URL query parameters that may carry credentials with a placeholder.
 *
 * Used by:
 * - `beforeSend` / `beforeSendSpan` in sentry.{server,edge}.config.ts
 * - `beforeSendSpan` in instrumentation-client.ts
 *
 * What triggered it: the Gemini adapter used to append `?key=AIza...` to the outgoing fetch URL.
 * Sentry's default PII scrubber only filters headers such as `Authorization` and leaves non-standard
 * parameter names in the URL query alone, so a BYOK key ended up in the Sentry trace every time.
 *
 * Gemini now uses the `x-goog-api-key` header (see chat/stream/route.ts and gemini.ts), and this
 * function stays as defense in depth for any future adapter, a Relay query_key mode, or a third-party SDK default.
 */
const SENSITIVE_URL_PARAMS = [
  'key',
  'api_key',
  'apiKey',
  'apikey',
  'access_token',
  'token',
  'auth',
  'authorization',
  'password',
  'secret',
] as const;

const REDACTED = '<redacted>';
const REDACTED_RELAY_ORIGIN = 'https://<relay-direct>';
const registeredRelayOrigins: string[] = [];
const MAX_REGISTERED_RELAY_ORIGINS = 128;

/** Register only origins actually used by the browser Relay direct transport. */
export function registerRelayRequestURL(raw: string): void {
  try {
    const origin = new URL(raw).origin;
    if (registeredRelayOrigins.includes(origin)) return;
    registeredRelayOrigins.push(origin);
    if (registeredRelayOrigins.length > MAX_REGISTERED_RELAY_ORIGINS) {
      registeredRelayOrigins.shift();
    }
  } catch {
    // The endpoint policy rejects invalid URLs before this function is reached.
  }
}

export function redactRegisteredRelayOrigins(input: string): string {
  let redacted = input;
  for (const origin of registeredRelayOrigins) {
    redacted = redacted.split(origin).join(REDACTED_RELAY_ORIGIN);
  }
  return redacted;
}

// Sensitive query parameters are replaced by regex rather than parsed with new URL(), because a
// span.description can be `"GET https://..."` or `"http.client GET https://..."` and carries prefix text.
const SENSITIVE_QUERY_PATTERN = new RegExp(
  `([?&](?:${SENSITIVE_URL_PARAMS.join('|')})=)[^&\\s"'<>]+`,
  'gi',
);

export function redactSensitiveQuery(input: string): string {
  if (!input) return input;
  return input.replace(SENSITIVE_QUERY_PATTERN, `$1${REDACTED}`);
}

/**
 * Sentry event hook: sanitizes request.url.
 * Usage: sentry.init({ beforeSend: redactSentryEvent })
 */
export function redactSentryEvent<T extends { request?: { url?: string } | undefined }>(event: T): T {
  if (event.request?.url) {
    event.request.url = redactRegisteredRelayOrigins(redactSensitiveQuery(event.request.url));
  }
  return event;
}

export function redactSentryBreadcrumb<
  T extends { data?: Record<string, unknown> | undefined },
>(breadcrumb: T): T {
  if (breadcrumb.data && typeof breadcrumb.data.url === 'string') {
    breadcrumb.data.url = redactRegisteredRelayOrigins(
      redactSensitiveQuery(breadcrumb.data.url),
    );
  }
  return breadcrumb;
}

/**
 * Sentry span hook: sanitizes description and data['http.url'].
 * Usage: sentry.init({ beforeSendSpan: redactSentrySpan })
 */
export function redactSentrySpan<
  T extends {
    description?: string | undefined;
    data?: Record<string, unknown> | undefined;
  },
>(span: T): T {
  if (span.description) {
    span.description = redactRegisteredRelayOrigins(redactSensitiveQuery(span.description));
  }
  if (span.data && typeof span.data['http.url'] === 'string') {
    span.data['http.url'] = redactRegisteredRelayOrigins(
      redactSensitiveQuery(span.data['http.url'] as string),
    );
  }
  return span;
}
