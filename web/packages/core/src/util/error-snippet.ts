import { redactRelayCredentials } from '@oriveo/shared/relay/endpoint-policy';

interface UpstreamErrorShape {
  error?: {
    message?: unknown;
    code?: unknown;
    type?: unknown;
  } | unknown;
  message?: unknown;
  msg?: unknown;
}

export function extractErrorSnippet(
  body: string,
  maxLength = 500,
  credentials: readonly string[] = [],
): string | undefined {
  const parsed = parseUpstreamError(body, credentials);
  if (!parsed) return undefined;
  return truncate(parsed, maxLength);
}

function parseUpstreamError(body: string, credentials: readonly string[]): string | undefined {
  try {
    const value = JSON.parse(body) as UpstreamErrorShape;
    if (typeof value.error === 'string') return redactSensitiveErrorText(value.error, credentials);

    const error = isRecord(value.error) ? value.error : undefined;
    const parts = [
      stringifyIfPrimitive(error?.code, credentials),
      stringifyIfPrimitive(error?.type, credentials),
      stringifyIfPrimitive(error?.message, credentials),
      stringifyIfPrimitive(value.message, credentials),
      stringifyIfPrimitive(value.msg, credentials),
    ].filter(Boolean);

    return parts.length > 0 ? parts.join(' | ') : undefined;
  } catch {
    // The shape of a non-JSON upstream body is unpredictable; even regex redaction could leak a prompt or a credential, so degrade safely to showing nothing.
    return undefined;
  }
}

function stringifyIfPrimitive(value: unknown, credentials: readonly string[]): string | undefined {
  if (typeof value === 'string') return redactSensitiveErrorText(value, credentials);
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function redactSensitiveErrorText(value: string, credentials: readonly string[]): string {
  return redactRelayCredentials(value
    .replace(
      /(["'])(api[_-]?key|x-api-key|x-goog-api-key|authorization|bearer|token|secret|password)\1\s*:\s*(["'])(?:\\.|(?!\3).)*\3/gi,
      '$1$2$1:"[redacted]"',
    )
    .replace(
      /(["'])(prompt|messages?|content|request(?:\s+body)?|body|input)\1\s*:\s*(\[[\s\S]*?\]|\{[\s\S]*?\}|(["'])(?:\\.|(?!\4).)*\4|[^,;}]+)/gi,
      '$1$2$1:"[redacted]"',
    )
    .replace(
      /\b(api[_-]?key|x-api-key|x-goog-api-key|authorization|bearer|token|secret|password)\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;|}]+)/gi,
      '$1=[redacted]',
    )
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, 'Bearer [redacted]')
    .replace(/\b(?:sk|sk-proj)-[A-Za-z0-9_-]{8,}/g, '[redacted]')
    .replace(
      /\b(prompt|messages?|content|request(?:\s+body)?|body|input)\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|\[[^\]]*\]|\{[^}]*\}|[^,;|]+)/gi,
      '$1=[redacted]',
    ), credentials);
}

function truncate(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value;
  if (maxLength <= 3) return value.slice(0, maxLength);
  return `${value.slice(0, maxLength - 3)}...`;
}
