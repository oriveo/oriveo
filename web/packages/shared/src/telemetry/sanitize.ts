import { TELEMETRY_PII_BLACKLIST, type TelemetryProperties } from './events';

const BLACKLIST_LOWER = new Set(
  TELEMETRY_PII_BLACKLIST.map((k) => k.toLowerCase()),
);
const SENSITIVE_KEY_PARTS = [
  'apikey',
  'api_key',
  'key',
  'authorization',
  'auth',
  'bearer',
  'password',
  'token',
  'secret',
  'message',
  'messages',
  'content',
  'prompt',
  'completion',
  'input',
  'output',
  'oob',
  'code',
];

// Exact allowlist: these contract fields have names containing a sensitive-looking fragment, but
// their values are only aggregate numbers, booleans or normalised slugs. No fuzzy matching, so
// credential variants such as accessToken / oobCode / provider_api_key cannot slip through.
const SAFE_KEY_ALLOWLIST = new Set([
  'error_code',
  'last_error_code',
  'prompt_tokens',
  'completion_tokens',
  'input_tokens',
  'output_tokens',
  'message_count',
  'message_length',
  'has_image_output',
  'is_authenticated',
  // The connection method submitted during setup (api_key / subscription). The name contains the
  // "auth" fragment, so without this exact allowance the substring scrubber silently drops it and
  // subscription links become invisible on the dashboard. The value is a fixed slug and carries no
  // credential.
  'auth_mode',
]);

function normalizeKey(key: string): string {
  return key.replace(/[^a-zA-Z0-9]/g, '').toLowerCase();
}

function isSensitiveKey(key: string): boolean {
  const lower = key.toLowerCase();
  if (SAFE_KEY_ALLOWLIST.has(lower)) return false;
  if (BLACKLIST_LOWER.has(lower)) return true;
  const normalized = normalizeKey(key);
  return SENSITIVE_KEY_PARTS.some((part) => {
    const normalizedPart = normalizeKey(part);
    return normalized === normalizedPart || normalized.includes(normalizedPart);
  });
}

function sanitizeValue(value: unknown, maxStringLength: number): unknown {
  if (typeof value === 'string') {
    return value.length > maxStringLength
      ? `${value.slice(0, maxStringLength)}…`
      : value;
  }
  if (Array.isArray(value)) {
    return value
      .map((item) => sanitizeValue(item, maxStringLength))
      .filter((item) => item !== undefined);
  }
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(value)) {
      if (isSensitiveKey(key)) continue;
      const sanitized = sanitizeValue(child, maxStringLength);
      if (sanitized !== undefined) out[key] = sanitized;
    }
    return out;
  }
  return value;
}

// Removes blacklisted fields and truncates over-long strings, so sensitive data and large payloads are never reported.
export function sanitizeProperties(
  props: TelemetryProperties | undefined,
  maxStringLength = 1024,
): TelemetryProperties | undefined {
  if (!props) return props;
  const out: TelemetryProperties = {};
  for (const [key, value] of Object.entries(props)) {
    if (isSensitiveKey(key)) continue;
    const sanitized = sanitizeValue(value, maxStringLength);
    if (sanitized !== undefined) {
      out[key] = sanitized as TelemetryProperties[string];
    }
  }
  return out;
}

export function sanitizeTelemetryPath(path: string): string {
  try {
    const url = new URL(path, 'https://oriveo.local');
    for (const key of Array.from(url.searchParams.keys())) {
      if (isSensitiveKey(key)) {
        url.searchParams.delete(key);
      }
    }
    const query = url.searchParams.toString();
    return `${url.pathname}${query ? `?${query}` : ''}${url.hash}`;
  } catch {
    return path.split('?')[0] ?? path;
  }
}
