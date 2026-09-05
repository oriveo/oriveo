import type { ProviderKind } from '@oriveo/shared';

type JSONObject = Record<string, unknown>;

/**
 * Request body construction for the relay connection test (chat-ping).
 *
 * Relay (custom endpoint) only: a relay has no official metadata validation contract, so the
 * connection test goes through the real chat endpoint. BYOK key validation for official providers
 * does not live here - it uses the `validation` contract shipped by the backend plus
 * `/api/providers/validate` to probe a model-independent endpoint (see
 * `apps/app/app/api/_shared/key-validation.ts`).
 *
 * The bodies come from a static per-provider fallback; metadata carries no validation override for
 * them.
 */

export function buildOpenAICompatibleValidationBody(
  providerKind: ProviderKind,
  modelID: string,
  fallbackMaxTokens?: number,
): JSONObject {
  return applyDefaultValidationBodyParams(providerKind, {
    model: modelID,
    stream: false,
    ...validationMaxTokensParam(providerKind, fallbackMaxTokens),
    messages: [{ role: 'user', content: 'ping' }],
  });
}

export function buildAnthropicValidationBody(
  providerKind: ProviderKind,
  modelID: string,
): JSONObject {
  return applyDefaultValidationBodyParams(providerKind, {
    model: modelID,
    max_tokens: 1,
    messages: [{ role: 'user', content: 'ping' }],
  });
}

export function buildGeminiValidationBody(
  providerKind: ProviderKind,
): JSONObject {
  return applyDefaultValidationBodyParams(providerKind, {
    contents: [{ role: 'user', parts: [{ text: 'ping' }] }],
    generationConfig: {
      maxOutputTokens: 1,
    },
  });
}

function validationMaxTokensParam(
  providerKind: ProviderKind,
  fallbackMaxTokens?: number,
): JSONObject {
  const maxTokens = fallbackMaxTokens ?? defaultValidationMaxTokens(providerKind);
  return typeof maxTokens === 'number' ? { max_tokens: maxTokens } : {};
}

function applyDefaultValidationBodyParams(
  providerKind: ProviderKind,
  body: JSONObject,
): JSONObject {
  return mergeJSONObjects(body, defaultValidationBodyParams(providerKind));
}

function defaultValidationMaxTokens(providerKind: ProviderKind): number | undefined {
  if (providerKind === 'openAI') return undefined;
  if (providerKind === 'openRouter') return 16;
  return 1;
}

function defaultValidationBodyParams(providerKind: ProviderKind): JSONObject | undefined {
  if (providerKind === 'moonshot') {
    return { thinking: { type: 'disabled' } };
  }
  return undefined;
}

function mergeJSONObjects(
  base: JSONObject,
  overrides: JSONObject | undefined,
): JSONObject {
  if (!overrides) return base;
  const result: JSONObject = { ...base };
  for (const [key, value] of Object.entries(overrides)) {
    const current = result[key];
    if (isPlainObject(current) && isPlainObject(value)) {
      result[key] = mergeJSONObjects(current, value);
    } else {
      result[key] = value;
    }
  }
  return result;
}

function isPlainObject(value: unknown): value is JSONObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
