import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Web-side consumer test for the shared metadata fixture.
 *
 * Seeds the cache (IndexedDB) from `shared/test-fixtures/relay/metadata-fixture.json` and checks
 * that metadata-client parses the fixture's matched samples and relayRuntimeConfig correctly.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import { __seedMetadataCacheForTest as seedMetadataCache } from '../metadata-client';

// vitest runs with cwd = apps/app, so walk up three levels to the repository root.
const FIXTURE_PATH = resolve(
  process.cwd(),
  '../../..',
  'shared/test-fixtures/relay/metadata-fixture.json',
);

function loadFixture(): Record<string, unknown> {
  const raw = readFileSync(FIXTURE_PATH, 'utf-8');
  return JSON.parse(raw) as Record<string, unknown>;
}

describe('metadata-fixture (shared with iOS / Android)', () => {
  beforeEach(async () => {
    vi.resetModules();
    vi.restoreAllMocks();
    localStorage.clear();
    await pruneBlobs('oriveo:metadata:c', []);
    vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);
  });

  it('resolves gpt-5.4 / gpt-5.4-2026-04-01 / gpt-image-2 / claude-sonnet-4.5 / gemini-2.5-pro', async () => {
    const fixture = loadFixture();
    await seedMetadataCache({
      timestamp: Date.now(),
      data: fixture,
    });

    const metadata = await import('../metadata-client');
    await metadata.initMetadata();

    // Cross-provider match, in the specified order.
    const gpt = metadata.resolveCatalogModelAcrossProvidersWithProvider('gpt-5.4');
    expect(gpt?.matchedProviderKind).toBe('openAI');
    expect(gpt?.canonicalModelId).toBe('gpt-5.4');
    expect(gpt?.metadata.displayName).toBe('GPT-5.4');

    // Dated snapshot alias match.
    const gptDated = metadata.resolveCatalogModelAcrossProvidersWithProvider('gpt-5.4-2026-04-01');
    expect(gptDated?.canonicalModelId).toBe('gpt-5.4');

    // Standalone image generation model.
    const gptImage = metadata.resolveCatalogModelAcrossProvidersWithProvider('gpt-image-2');
    expect(gptImage?.matchedProviderKind).toBe('openAI');
    expect(gptImage?.canonicalModelId).toBe('gpt-image-2');
    expect(gptImage?.metadata.profiles.imageGen).toBe('openaiImageGen');

    const claude = metadata.resolveCatalogModelAcrossProvidersWithProvider('claude-sonnet-4.5');
    expect(claude?.matchedProviderKind).toBe('anthropic');
    expect(claude?.metadata.displayName).toBe('Claude Sonnet 4.5');

    // Claude dated snapshot.
    const claudeDated = metadata.resolveCatalogModelAcrossProvidersWithProvider(
      'claude-sonnet-4-5-2026-04-01',
    );
    expect(claudeDated?.canonicalModelId).toBe('claude-sonnet-4.5');

    const gemini = metadata.resolveCatalogModelAcrossProvidersWithProvider('gemini-2.5-pro');
    expect(gemini?.matchedProviderKind).toBe('gemini');
    expect(gemini?.metadata.profiles.webSearch).toBe('geminiGoogleSearch');

    // Unknown model.
    expect(metadata.resolveCatalogModelAcrossProvidersWithProvider('my-custom-model')).toBeNull();
  });

  it('expands fixture generation parameters consistently: model-level enumValues override the platform shared schema, and absent ones fall back to the global values', async () => {
    const fixture = loadFixture();
    await seedMetadataCache({
      timestamp: Date.now(),
      data: fixture,
    });

    const metadata = await import('../metadata-client');
    await metadata.initMetadata();

    // gpt-5.4 declares model-level enumValues (["low", "high"]) that must override the four
    // global values from the platform shared schema, or the expert parameter panel would offer
    // levels the level picker deliberately narrowed away.
    const gpt = metadata.resolveCatalogModelAcrossProvidersWithProvider('gpt-5.4');
    const gptProfile = metadata.resolveGenerationProfileRef(gpt?.metadata.profiles.generation);
    expect(gptProfile?.parameters?.find((p) => p.id === 'reasoning_effort')?.enumValues).toEqual(['low', 'high']);

    // The reasoning_effort reference on claude-sonnet-4.5 declares no model-level enumValues, so
    // it falls back to the four global values of the platform shared schema (legacy wire path).
    const claude = metadata.resolveCatalogModelAcrossProvidersWithProvider('claude-sonnet-4.5');
    const claudeProfile = metadata.resolveGenerationProfileRef(claude?.metadata.profiles.generation);
    expect(claudeProfile?.parameters?.find((p) => p.id === 'reasoning_effort')?.enumValues).toEqual(['low', 'medium', 'high', 'xhigh']);
  });

  it('matches the relayRuntimeConfig snapshot in the fixture with the fallback defaults', async () => {
    const fixture = loadFixture();
    await seedMetadataCache({
      timestamp: Date.now(),
      data: fixture,
    });

    const metadata = await import('../metadata-client');
    await metadata.initMetadata();

    const runtime = metadata.getRelayRuntimeConfig();
    // The fixture version is a value frozen by the backend and should be passed through unchanged.
    expect(runtime.version).toBe('2026-04-23-1');
    expect(runtime.officialProviderWhitelist).toEqual([
      'openAI', 'anthropic', 'gemini', 'deepseek', 'miniMax', 'zhipu', 'qwen',
    ]);
    // The four transport defaults.
    expect(runtime.transportEnvelopes.openai_responses).toEqual({
      image: true, nativeFile: true, textFileInline: true,
      webSearch: true, imageGeneration: true, reasoning: true,
    });
    expect(runtime.transportEnvelopes.openai_chat_completions).toEqual({
      image: true, nativeFile: false, textFileInline: true,
      webSearch: false, imageGeneration: false, reasoning: true,
    });
    expect(runtime.transportEnvelopes.anthropic_messages).toEqual({
      image: true, nativeFile: true, textFileInline: true,
      webSearch: false, imageGeneration: false, reasoning: true,
    });
    expect(runtime.transportEnvelopes.gemini_generate_content).toEqual({
      image: true, nativeFile: true, textFileInline: true,
      webSearch: true, imageGeneration: true, reasoning: true,
    });
    expect(runtime.verificationPolicy).toEqual({
      hardFailedExpiryDays: 7,
      softFailedRetryAfterSeconds: 60,
      verifiedCacheDays: 30,
    });
    expect(runtime.featureGatingPolicy).toEqual({
      showActualModelIdHint: true,
      showSoftFailHint: true,
    });
  });

  it('falls back to the built-in default when relayRuntimeConfig.officialProviderWhitelist is an empty array, guarding against a malformed backend payload', async () => {
    const fixture = loadFixture() as Record<string, unknown> & {
      relayRuntimeConfig: Record<string, unknown>;
    };
    fixture.relayRuntimeConfig = {
      ...fixture.relayRuntimeConfig,
      officialProviderWhitelist: [],
    };
    await seedMetadataCache({
      timestamp: Date.now(),
      data: fixture,
    });

    const metadata = await import('../metadata-client');
    await metadata.initMetadata();

    const runtime = metadata.getRelayRuntimeConfig();
    // An empty array must be read as 'not sent' and fall back to the seven official providers.
    expect(runtime.officialProviderWhitelist).toHaveLength(7);
    expect(runtime.officialProviderWhitelist).toContain('openAI');
    expect(runtime.officialProviderWhitelist).toContain('anthropic');
  });

  it('uses the fallback for all four transports when relayRuntimeConfig.transportEnvelopes is an empty object', async () => {
    const fixture = loadFixture() as Record<string, unknown> & {
      relayRuntimeConfig: Record<string, unknown>;
    };
    fixture.relayRuntimeConfig = {
      ...fixture.relayRuntimeConfig,
      transportEnvelopes: {},
    };
    await seedMetadataCache({
      timestamp: Date.now(),
      data: fixture,
    });

    const metadata = await import('../metadata-client');
    await metadata.initMetadata();

    const runtime = metadata.getRelayRuntimeConfig();
    expect(runtime.transportEnvelopes.openai_responses.webSearch).toBe(true);
    expect(runtime.transportEnvelopes.openai_chat_completions.webSearch).toBe(false);
    expect(runtime.transportEnvelopes.anthropic_messages.imageGeneration).toBe(false);
    expect(runtime.transportEnvelopes.gemini_generate_content.webSearch).toBe(true);
  });
});
