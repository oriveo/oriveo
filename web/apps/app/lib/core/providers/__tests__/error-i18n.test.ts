import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, it, expect } from 'vitest';
import { toProviderError } from '@oriveo/core/providers/errors';
import { classifyRelayHTTPError, type RelayErrorContext } from '@oriveo/core/providers/relay-error-classifier';
import { RELAY_HTML_PAGE_ERROR, createRelayJSONStream } from '@oriveo/core/providers/relay-stream';
import { localizeProviderError } from '../error-i18n';

describe('localizeProviderError', () => {
  const mockT = (key: string) => `[translated:${key}]`;

  it('maps invalidKey message to i18n key', () => {
    const raw = 'The API key you entered is invalid or has been revoked. Please check your key and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:invalidKey.message]');
  });

  it('maps rateLimited message to i18n key', () => {
    const raw = 'You have exceeded the rate limit. Please wait a moment and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:rateLimited.message]');
  });

  it('maps network message to i18n key', () => {
    const raw = 'Unable to connect. Please check your internet connection and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:network.message]');
  });

  it('maps upstream message to i18n key', () => {
    const raw = 'The AI provider is experiencing issues. Please try again later.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:upstream.message]');
  });

  it('maps emptyResponse message to i18n key', () => {
    const raw = 'The model catalog response was invalid. Please try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:emptyResponse.message]');
  });

  it('maps emptyModelCatalog message to i18n key', () => {
    const raw = 'The model catalog is empty. Please try again later or enter a model ID manually.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:emptyModelCatalog.message]');
  });

  it('maps badRequest message to i18n key', () => {
    const raw = 'The request was malformed. Please check your input and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:requestFailed.message]');
  });

  it('maps dynamic "Request failed with status" to requestFailed key', () => {
    const raw = 'Request failed with status 502. Please try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:requestFailed.message]');
  });

  it('returns raw message for unknown error strings', () => {
    const raw = 'Some unknown error occurred.';
    expect(localizeProviderError(raw, mockT)).toBe(raw);
  });

  it('falls back to raw message when translation throws', () => {
    const throwingT = () => { throw new Error('missing key'); };
    const raw = 'The API key you entered is invalid or has been revoked. Please check your key and try again.';
    expect(localizeProviderError(raw, throwingT)).toBe(raw);
  });
});

/*
 * Aligned with the other clients: relay error guidance uses the same English source sentences; input goes through the production classification function classifyRelayHTTPError,
 * then localizeProviderError + the real en.json render, asserting that what the user sees is the en sentence for the corresponding key
 * (for anthropicAuthRequired the key is written as Auth Mode while the en display value is Authentication; take the display value, same name as the Web UI).
 */
const IOS_GUIDANCE = {
  codexIdentityRequiredSwitch: "This connection requires a Codex client identity. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.",
  codexIdentityRejected: "This connection still rejects Oriveo's Codex client identity. Open Providers → this connection → Edit connection → Headers & query params and set a custom User-Agent or header, or switch to another connection.",
  imageGenerationEndpointUnavailable: "This connection doesn't offer a separate image generation API. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses. Oriveo will then generate images inside the chat instead.",
  chatCompletionsRejectedByCodexHost: "This connection only exposes /v1/responses and rejects /chat/completions. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.",
  imageResponseFormatRejected: "This image model doesn't accept the response_format parameter. Try a different image model ID.",
  upstreamUnavailable: "This connection could not reach its upstream provider. This is not your configuration — its administrator's upstream account may be invalid, out of credits, or rate-limited. Switch to another connection or contact its administrator.",
  modelUnavailable: "This connection's upstream does not offer this model. Open Providers → this connection → Model Library and enable a model it actually offers. You can ask its administrator for the exact list of available model IDs.",
  responsesProtocolRequired: "This connection requires the OpenAI Responses protocol for this model. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.",
  storeRejected: "This connection rejects the “store/disable_response_storage” field. Open Providers → this connection → Edit connection → Compatibility and turn off “Don't keep responses in the cloud”, then retry.",
  serviceTierRejected: "This connection does not accept the current service tier value. Open Providers → this connection → Edit connection → Compatibility and clear “Service Tier”, then retry.",
  maxTokensRequired: "This connection requires the “max_tokens” parameter. Open Providers → this connection → Parameters and set “Max Tokens” (e.g. 4096), then retry.",
  anthropicAuthRequired: "This connection expects an Anthropic-style x-api-key header. Open Providers → this connection → Edit connection → Authentication and choose “x-api-key”, then retry.",
  imageSchemaMismatch: "Image attachments use a schema that doesn't match this model's protocol. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to one that fits this model, then retry.",
  clientGated: "This key's group only accepts the official Claude CLI. In the account console of the site that issued this key, move the key to a group that allows API access, or create a new key and add it in Providers → this connection → API Keys. Then retry.",
  webPageReturned: "This connection returned a web page instead of a model response. Check the request URL and the protocol set for this model.",
} as const;

type GuidanceKey = keyof typeof IOS_GUIDANCE;

const enErrors = (JSON.parse(readFileSync(path.join(process.cwd(), 'messages', 'en.json'), 'utf8')) as {
  errors: Record<string, unknown>;
}).errors;

function enT(key: string): string {
  const value = key.split('.').reduce<unknown>((node, part) => (node as Record<string, unknown> | undefined)?.[part], enErrors);
  if (typeof value !== 'string') throw new Error(`missing errors.${key}`);
  return value;
}

const RELAY = 'https://relay.example/v1';
const MESSAGES_CTX: RelayErrorContext = { transport: 'anthropic_messages' };
const CHAT_CTX: RelayErrorContext = { transport: 'openai_chat_completions' };

interface GuideCase {
  id: string;
  status: number;
  body: string;
  url?: string;
  context?: RelayErrorContext;
  expect: GuidanceKey;
}

const GUIDE_CASES: GuideCase[] = [
  { id: 'RL2-GUIDE-01', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: `${RELAY}/chat/completions`, context: CHAT_CTX, expect: 'codexIdentityRequiredSwitch' },
  { id: 'RL2-GUIDE-01 (Messages)', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: `${RELAY}/messages`, context: MESSAGES_CTX, expect: 'codexIdentityRequiredSwitch' },
  { id: 'RL2-GUIDE-02', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: `${RELAY}/responses`, context: { transport: 'openai_responses' }, expect: 'codexIdentityRejected' },
  { id: 'RL2-GUIDE-02 (the streaming chain only knows the request path)', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: `${RELAY}/responses`, expect: 'codexIdentityRejected' },
  { id: 'RL2-GUIDE-03', status: 404, body: '{"error":{"message":"Invalid URL (POST /v1/images/generations)"}}', url: `${RELAY}/images/generations`, expect: 'imageGenerationEndpointUnavailable' },
  { id: 'RL2-GUIDE-04', status: 404, body: '{"error":"not found"}', url: 'https://codex.relay.example/v1/chat/completions', expect: 'chatCompletionsRejectedByCodexHost' },
  { id: 'RL2-GUIDE-05', status: 400, body: '{"error":{"message":"Unknown parameter: \'response_format\'."}}', url: `${RELAY}/images/generations`, expect: 'imageResponseFormatRejected' },
  { id: 'RL2-GUIDE-06', status: 502, body: '{"error":{"type":"upstream_error","message":"Upstream authentication failed"}}', url: `${RELAY}/chat/completions`, expect: 'upstreamUnavailable' },
  { id: 'RL2-GUIDE-07 (404)', status: 404, body: '{"error":{"message":"The model `x-1` does not exist","code":"model_not_found"}}', url: `${RELAY}/chat/completions`, expect: 'modelUnavailable' },
  { id: 'RL2-GUIDE-07 (400)', status: 400, body: '{"error":{"message":"no such model","code":"model_not_found"}}', url: `${RELAY}/chat/completions`, expect: 'modelUnavailable' },
  { id: 'RL2-GUIDE-08', status: 400, body: '{"error":{"message":"Unknown parameter: \'input[4].content[1].url\'."}}', url: `${RELAY}/chat/completions`, context: CHAT_CTX, expect: 'responsesProtocolRequired' },
  { id: 'RL2-GUIDE-09', status: 400, body: '{"error":{"message":"Unknown parameter: \'store\'."}}', url: `${RELAY}/responses`, expect: 'storeRejected' },
  { id: 'RL2-GUIDE-10', status: 400, body: '{"error":{"message":"Invalid value for service_tier"}}', url: `${RELAY}/responses`, expect: 'serviceTierRejected' },
  { id: 'RL2-GUIDE-11', status: 400, body: '{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: Field required"}}', url: `${RELAY}/messages`, context: MESSAGES_CTX, expect: 'maxTokensRequired' },
  { id: 'RL2-GUIDE-12', status: 401, body: '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}', url: `${RELAY}/messages`, context: MESSAGES_CTX, expect: 'anthropicAuthRequired' },
  { id: 'RL2-GUIDE-01 (the streaming chain only knows the request path - Gemini)', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: 'https://relay.example/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse', expect: 'codexIdentityRequiredSwitch' },
  { id: 'RL2-GUIDE-01 (the streaming chain only knows the request path - llama.cpp native)', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: 'http://192.168.1.20:8080/completion', expect: 'codexIdentityRequiredSwitch' },
  { id: 'RL2-GUIDE-19', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: `${RELAY}/models`, expect: 'codexIdentityRejected' },
  { id: 'RL2-GUIDE-19 (request address unavailable)', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', expect: 'codexIdentityRejected' },
  { id: 'RL2-GUIDE-20', status: 403, body: '{"error":{"message":"Only Codex official clients are allowed"}}', url: `${RELAY}/images/generations`, expect: 'codexIdentityRejected' },
  { id: 'RL2-GUIDE-13', status: 400, body: '{"error":{"message":"Invalid image_url: expected an object."}}', url: `${RELAY}/messages`, expect: 'imageSchemaMismatch' },
];

interface ClientGateCase { caseId: string; status: number; body: string; expect: 'client_gated' | 'none' }

function fixturePath(name: string): string {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', name);
    if (existsSync(candidate)) return candidate;
    dir = path.dirname(dir);
  }
  throw new Error(`${name} not found`);
}

const clientGateCases = (JSON.parse(readFileSync(fixturePath('negative-cache.v1.json'), 'utf8')) as {
  clientGateCases: ClientGateCase[];
}).clientGateCases;

/** The guidance sentence produced by the production classification function, rendered to en through the localization entry. */
function relayGuidance(status: number, body: string, url: string | undefined, context: RelayErrorContext | undefined): string | undefined {
  const classified = classifyRelayHTTPError(status, body, url, context);
  return classified ? localizeProviderError(classified.message, enT) : undefined;
}

/** The body the production send chain finally hands to the error card (toProviderError; the existing concatenation that prefers the upstream original text is unchanged). */
function relayUserMessage(status: number, body: string, url: string | undefined, context: RelayErrorContext | undefined): string {
  return localizeProviderError(toProviderError(status, body, url, context).message, enT);
}

const IOS_SENTENCES = new Set<string>(Object.values(IOS_GUIDANCE));

describe('relay error guidance (same sentences as the other clients)', () => {
  it.each(GUIDE_CASES)('$id relay payload lands on the same guidance sentence as the other clients', (item) => {
    expect(relayGuidance(item.status, item.body, item.url, { isRelay: true, ...item.context }))
      .toBe(IOS_GUIDANCE[item.expect]);
  });

  it.each(clientGateCases.filter((item) => item.expect === 'client_gated'))('RL2-GUIDE-14 $caseId official CLI gating lands on the gating sentence, not judged as an invalid key', (item) => {
    expect(relayGuidance(item.status, item.body, `${RELAY}/messages`, { isRelay: true, ...MESSAGES_CTX })).toBe(IOS_GUIDANCE.clientGated);
    expect(toProviderError(item.status, item.body, `${RELAY}/messages`, { isRelay: true, ...MESSAGES_CTX }).kind).not.toBe('invalidKey');
  });

  it.each(clientGateCases.filter((item) => item.expect === 'none'))('RL2-GUIDE-14 $caseId is not gating and shows no gating sentence', (item) => {
    expect(relayGuidance(item.status, item.body, `${RELAY}/messages`, { isRelay: true, ...MESSAGES_CTX }))
      .not.toBe(IOS_GUIDANCE.clientGated);
  });

  it('RL2-GUIDE-15 relay 429 shows no relay guidance and lands on the generic "rate limited"', () => {
    expect(relayUserMessage(429, '', `${RELAY}/chat/completions`, { isRelay: true })).toBe(enT('rateLimited.message'));
    expect(toProviderError(429, '{"error":{"message":"rate limit exceeded"}}', `${RELAY}/chat/completions`, { isRelay: true }).kind).toBe('rateLimited');
    expect(classifyRelayHTTPError(429, 'rate limit exceeded', `${RELAY}/chat/completions`, { isRelay: true })).toBeNull();
    expect((enErrors.relay as Record<string, unknown>).rateLimited).toBeUndefined();
    expect((enErrors.relay as Record<string, unknown>).codexIdentityEnable).toBeUndefined();
  });

  it.each([
    ...GUIDE_CASES,
    ...clientGateCases.filter((item) => item.expect === 'client_gated')
      .map((item) => ({ id: `RL2-CLIGATE-${item.caseId}`, status: item.status, body: item.body, url: `${RELAY}/messages`, context: MESSAGES_CTX })),
  ])('RL2-GUIDE-16 an official provider receiving the same payload $id shows no relay guidance', (item) => {
    expect(classifyRelayHTTPError(item.status, item.body, item.url, item.context)).toBeNull();
    expect(IOS_SENTENCES.has(relayUserMessage(item.status, item.body, item.url, item.context))).toBe(false);
  });

  it.each([
    {
      id: 'packyapi CLI gating 403',
      status: 403,
      body: '{"type":"error","error":{"type":"permission_error","message":"This API endpoint is only accessible via the official Claude CLI"}}',
      expect: 'clientGated' as const,
      upstream: 'This API endpoint is only accessible via the official Claude CLI',
    },
    {
      id: 'x-api-key 401',
      status: 401,
      body: '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
      expect: 'anthropicAuthRequired' as const,
      upstream: 'invalid x-api-key',
    },
  ])('RL2-GUIDE-17 when toProviderError hits relay guidance the body is the guidance sentence and the upstream original goes into detail: $id', (item) => {
    const error = toProviderError(item.status, item.body, `${RELAY}/messages`, { isRelay: true, ...MESSAGES_CTX });
    expect(localizeProviderError(error.message, enT)).toBe(IOS_GUIDANCE[item.expect]);
    expect(error.detail).toContain(item.upstream);
  });

  it('RL2-GUIDE-17 toProviderError for a non-guidance relay 403 still takes the upstream original text', () => {
    const error = toProviderError(
      403,
      '{"error":{"message":"\u8be5\u4ee4\u724c\u65e0\u6743\u8bbf\u95ee\u6a21\u578b claude-sonnet-4-5","type":"new_api_error"}}',
      `${RELAY}/messages`,
      { isRelay: true, ...MESSAGES_CTX },
    );
    expect(error.message).toContain('\u8be5\u4ee4\u724c\u65e0\u6743\u8bbf\u95ee\u6a21\u578b claude-sonnet-4-5');
    expect(error.detail).toBe(error.message);
  });

  it('RL2-GUIDE-20 standalone image generation /images/generations receiving a Codex identity 403 via the production JSON stream wrapper -> still rejected', async () => {
    const stream = createRelayJSONStream(
      async () => new Response('{"error":{"message":"Only Codex official clients are allowed"}}', {
        status: 403,
        headers: { 'X-Relay-Upstream-URL': `${RELAY}/images/generations` },
      }),
      () => [],
    );
    const reader = stream.getReader();
    const first = await reader.read();
    expect(first.value).toMatchObject({ type: 'error', status: 403 });
    const event = first.value as { error: string };
    expect(localizeProviderError(event.error, enT)).toBe(IOS_GUIDANCE.codexIdentityRejected);
  });

  it('RL2-GUIDE-21 relay 429 body insufficient quota -> quota exhausted', () => {
    const error = toProviderError(429, '{"error":{"message":"insufficient quota","type":"insufficient_quota"}}', `${RELAY}/chat/completions`, { isRelay: true });
    expect(error.kind).toBe('quotaExceeded');
    expect(classifyRelayHTTPError(429, 'insufficient quota', `${RELAY}/chat/completions`, { isRelay: true })).toBeNull();
  });

  it('RL2-WEBPAGE-01 web page sentence goes through the same localization entry', () => {
    expect(localizeProviderError(RELAY_HTML_PAGE_ERROR, enT)).toBe(IOS_GUIDANCE.webPageReturned);
  });
});
