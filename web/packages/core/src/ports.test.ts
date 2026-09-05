import { describe, expect, it } from 'vitest';
import type { MetadataLookupPort } from './ports';
import type { ProviderError } from './providers/errors';
import { createNoopTelemetryPort } from './ports';
import { extractErrorSnippet } from './util/error-snippet';

describe('core ports and pure utilities', () => {
  it('provides a no-op telemetry port that is safe for main and tests', async () => {
    const telemetry = createNoopTelemetryPort();
    expect(telemetry.isEnabled()).toBe(false);
    expect(() => telemetry.identify('user-1')).not.toThrow();
    expect(() => telemetry.track('chat_message_sent')).not.toThrow();
    expect(await telemetry.shutdown()).toBeUndefined();
  });

  it('extracts a bounded upstream error snippet without depending on renderer state', () => {
    const longBody = JSON.stringify({
      error: {
        message: 'x'.repeat(600),
        code: 'bad_request',
        type: 'invalid_request_error',
      },
    });

    const snippet = extractErrorSnippet(longBody, 120);

    expect(snippet).toBeDefined();
    expect(snippet?.length).toBeLessThanOrEqual(120);
    expect(snippet).toContain('bad_request');
  });

  it('does not fall back to raw upstream bodies that may contain secrets or prompts', () => {
    const snippet = extractErrorSnippet(
      'upstream echoed prompt="private health note" api_key="sk-secret"',
    );

    expect(snippet).toBeUndefined();
  });

  it('extracts only known top-level upstream error fields', () => {
    const snippet = extractErrorSnippet(
      JSON.stringify({
        message: 'Invalid API key',
        request: { prompt: 'do not leak this prompt' },
      }),
    );

    expect(snippet).toBe('Invalid API key');
    expect(snippet).not.toContain('prompt');
  });

  it('redacts secrets and prompt echoes inside whitelisted upstream error fields', () => {
    const snippet = extractErrorSnippet(
      JSON.stringify({
        error: {
          message: 'Upstream rejected request body prompt="private health note" api_key="sk-secret-token"',
          code: 'bad_request',
          type: 'invalid_request_error',
        },
      }),
    );

    expect(snippet).toContain('bad_request');
    expect(snippet).toContain('[redacted]');
    expect(snippet).not.toContain('private health note');
    expect(snippet).not.toContain('sk-secret-token');
  });

  it('redacts whitelisted string error fields before returning them', () => {
    const snippet = extractErrorSnippet(
      JSON.stringify({
        error: 'Gateway echoed prompt="private health note" api_key="sk-secret-token"',
      }),
    );

    expect(snippet).toContain('[redacted]');
    expect(snippet).not.toContain('private health note');
    expect(snippet).not.toContain('sk-secret-token');
  });

  it('redacts JSON-shaped prompt and key echoes inside whitelisted error messages', () => {
    const snippet = extractErrorSnippet(
      JSON.stringify({
        message: 'Upstream echoed {"messages":[{"role":"user","content":"private health note"}],"api_key":"sk-secret-token"}',
      }),
    );

    expect(snippet).toContain('[redacted]');
    expect(snippet).not.toContain('private health note');
    expect(snippet).not.toContain('sk-secret-token');
  });

  it('redacts Gemini x-goog-api-key echoes inside whitelisted error messages', () => {
    const snippet = extractErrorSnippet(
      JSON.stringify({
        message: 'Gemini echoed {"x-goog-api-key":"AIzaSySecretKeyValue"}',
      }),
    );

    expect(snippet).toContain('[redacted]');
    expect(snippet).not.toContain('AIzaSySecretKeyValue');
  });

  it('redacts Gemini x-goog-api-key assignment echoes inside whitelisted error messages', () => {
    const snippet = extractErrorSnippet(
      JSON.stringify({
        message: 'Gemini echoed x-goog-api-key=AIzaSySecretKeyValue',
      }),
    );

    expect(snippet).toContain('[redacted]');
    expect(snippet).not.toContain('AIzaSySecretKeyValue');
  });

  it('keeps metadata lookup ports centered on server-authoritative provider config', () => {
    const metadata: MetadataLookupPort = {
      lookupPricing: () => ({ promptPrice: 1, completionPrice: 2 }),
      resolveCatalogModel: () => ({ id: 'gpt-5.4', providerKind: 'openAI', transport: 'openai_responses' }),
      lookupProviderConfig: () => ({
        providerKind: 'openAI',
        displayName: 'OpenAI',
        endpoint: 'https://api.openai.com/v1',
        validation: {
          modelID: 'gpt-5.4-mini',
          authMode: 'bearer',
          probePath: '/models',
          invalidKeySignals: [
            {
              status: 401,
              bodyIncludes: ['invalid_api_key'],
            },
          ],
        },
      }),
      lookupRelayRuntimeConfig: () => ({
        version: '2026-06-02',
        officialProviderWhitelist: ['openAI', 'anthropic', 'gemini'],
        transportEnvelopes: {
          openai_responses: {
            image: true,
            nativeFile: true,
            textFileInline: true,
            webSearch: true,
            imageGeneration: true,
            reasoning: true,
          },
          openai_chat_completions: {
            image: true,
            nativeFile: false,
            textFileInline: true,
            webSearch: false,
            imageGeneration: false,
            reasoning: true,
          },
          anthropic_messages: {
            image: true,
            nativeFile: true,
            textFileInline: true,
            webSearch: true,
            imageGeneration: false,
            reasoning: true,
          },
          gemini_generate_content: {
            image: true,
            nativeFile: true,
            textFileInline: true,
            webSearch: true,
            imageGeneration: true,
            reasoning: true,
          },
        },
        transportRules: {
          openai_responses: {
            providerPriority: 'openAI',
            defaultAuthMode: 'bearer',
            defaultVersion: '',
            acceptedVersions: [],
            headerProfile: 'codex_responses',
            codexIdentityDefault: true,
            webSearchToolName: 'web_search',
            imageRoute: 'inline_responses_tool',
            forceStreamForImageGeneration: false,
          },
          openai_chat_completions: {
            providerPriority: 'openAI',
            defaultAuthMode: 'bearer',
            defaultVersion: '',
            acceptedVersions: [],
            headerProfile: 'none',
            codexIdentityDefault: false,
            webSearchToolName: 'disabled',
            imageRoute: 'images_endpoint',
            forceStreamForImageGeneration: false,
          },
          anthropic_messages: {
            providerPriority: 'anthropic',
            defaultAuthMode: 'x_api_key',
            defaultVersion: '2023-06-01',
            acceptedVersions: ['2023-06-01'],
            headerProfile: 'anthropic_v2023_06_01',
            codexIdentityDefault: false,
            webSearchToolName: 'disabled',
            imageRoute: 'unsupported',
            forceStreamForImageGeneration: false,
          },
          gemini_generate_content: {
            providerPriority: 'gemini',
            defaultAuthMode: 'x_goog_api_key',
            defaultVersion: '',
            acceptedVersions: [],
            headerProfile: 'gemini_key',
            codexIdentityDefault: false,
            webSearchToolName: 'google_search',
            imageRoute: 'gemini_modality',
            forceStreamForImageGeneration: true,
          },
        },
        verificationPolicy: {
          hardFailedExpiryDays: 7,
          softFailedRetryAfterSeconds: 300,
          verifiedCacheDays: 14,
        },
        featureGatingPolicy: {
          showActualModelIdHint: true,
          showSoftFailHint: true,
        },
      }),
      metadataContractVersion: () => 2,
    };

    expect(metadata.lookupProviderConfig('openAI')?.validation?.authMode).toBe('bearer');
    expect(metadata.lookupProviderConfig('openAI')?.validation?.invalidKeySignals?.[0]?.status).toBe(401);
    expect(metadata.lookupRelayRuntimeConfig()?.transportEnvelopes.gemini_generate_content.imageGeneration).toBe(true);
  });

  it('carries structured next action and source on provider errors', () => {
    const error: ProviderError = {
      kind: 'quotaExceeded',
      title: 'Provider quota reached',
      message: 'The upstream provider rejected the request.',
      nextAction: {
        kind: 'waitOrChangeProvider',
        labelKey: 'error.action.providerQuota',
      },
      retryable: false,
      source: 'provider',
      quotaSource: 'provider',
      status: 429,
    };

    expect(error.quotaSource).toBe('provider');
    expect(error.nextAction?.kind).toBe('waitOrChangeProvider');
  });
});
