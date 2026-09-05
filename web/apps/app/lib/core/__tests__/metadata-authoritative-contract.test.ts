/**
 * @vitest-environment jsdom
 *
 * Contract test for authoritative metadata resolution.
 *
 * The suite reads a shared fixture and asserts that the same query always produces the same resolved
 * result, so any drift in metadata-client behavior is caught here first.
 *
 * Note: this suite only consumes the fixture; it exercises no production code changes of its own.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it, vi } from 'vitest';

interface AttachmentSupport {
  image: boolean;
  nativeFile: boolean;
  textFileInline: boolean;
}

interface ProviderExpectation {
  id: string;
  providerKind: string;
  expectedDefaultModelId: string;
  expectedCanonicalModelCount: number;
  expectedAttachmentSupport: AttachmentSupport;
}

interface ModelExpectation {
  id: string;
  providerKind: string;
  query: string;
  expectedCanonicalModelId: string;
  expectedDisplayName: string;
  expectedContextLength: number | null;
  expectedMaxOutputTokens: number | null;
  expectedSupportsTemperature: boolean | null;
  expectedPricingStatus: 'priced' | 'free' | 'unknown';
  expectedPromptPerMToken: number | null;
  expectedCompletionPerMToken: number | null;
  expectedCachedInputPerMToken: number | null;
  expectedCapabilities: string[];
  expectedReasoningProfile: string | null;
  expectedWebSearchProfile: string | null;
  expectedImageGenProfile: string | null;
  expectedVendorKey: string | null;
  expectedVendorName: string | null;
  expectedGroupKey: string;
  expectedGroupName: string;
  expectedRecommended: boolean;
  expectedBadgeOrder: string[];
  expectedIsDefault: boolean;
}

interface NegativeExpectation {
  id: string;
  providerKind: string;
  query: string;
  expectedResolved: false;
}

interface VendorExpectation {
  providerKind: string;
  modelId: string;
  vendorKey: string | null;
  vendorName: string | null;
}

interface ContractFile {
  contractVersion: number;
  version: number;
  metadata: {
    version: number;
    contractVersion: number;
    updatedAt: string;
    profiles: Record<string, unknown>;
    providers: Record<string, {
      displayName?: string;
      attachmentSupport?: AttachmentSupport;
      defaultModelId?: string;
      validation?: {
        probe?: string;
        probePath?: string;
        authMode?: string;
        headerProfile?: string;
        invalidKeySignals?: Array<{ status?: number; bodyIncludes?: string[] }>;
      };
      resolveMap?: Record<string, string>;
      models: Record<string, {
        canonicalModelId?: string;
        vendorKey?: string | null;
        vendorName?: string | null;
        [key: string]: unknown;
      }>;
    }>;
  };
  topLevelExpectations: {
    expectedContractVersion: number;
    expectedVersion: number;
    requiredTopLevelFields: string[];
    requiredProviderFields: string[];
  };
  providerExpectations: ProviderExpectation[];
  modelExpectations: ModelExpectation[];
  negativeExpectations: NegativeExpectation[];
  vendorIntegrityExpectations: {
    aggregatorProviders: string[];
    directProviders: string[];
    expectations: VendorExpectation[];
  };
}

// The path is resolved relative to this test file rather than the cwd, so the fixture is found whether
// the suite runs through the workspace test script or a direct vitest invocation.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const contractPath = path.resolve(
  __dirname,
  '../../../../../../shared/model-contracts/metadata_authoritative_contract.v1.json',
);
const contract = JSON.parse(readFileSync(contractPath, 'utf8')) as ContractFile;

/** Wrap a payload in the backend response envelope: { code, message, data }. */
function makeOkResponse(payload: unknown): Response {
  return new Response(
    JSON.stringify({ code: 0, message: 'ok', data: payload }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
}

describe('metadata authoritative contract (Web)', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.restoreAllMocks();
    localStorage.clear();
  });

  /**
   * Load the fixture and initialize metadata-client.
   * Each test re-imports the module (vi.resetModules() already runs in beforeEach) so module-level
   * cached state stays isolated.
   */
  async function loadMetadataModule() {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(makeOkResponse(contract.metadata));
    const mod = await import('../metadata/metadata-client');
    await mod.initMetadata();
    return mod;
  }

  it('top-level contract: version and contractVersion match the fixture', async () => {
    const metadata = await loadMetadataModule();
    expect(metadata.getMetadataVersion()).toBe(contract.topLevelExpectations.expectedVersion);
    expect(metadata.getMetadataContractVersion()).toBe(
      contract.topLevelExpectations.expectedContractVersion,
    );
  });

  describe('providerExpectations', () => {
    for (const expectation of contract.providerExpectations) {
      it(`${expectation.id} — defaultModelId / attachmentSupport / canonicalCount`, async () => {
        const metadata = await loadMetadataModule();

        // defaultModelId has its own getter.
        expect(metadata.getProviderDefaultModelId(expectation.providerKind)).toBe(
          expectation.expectedDefaultModelId,
        );

        // attachmentSupport has its own getter.
        expect(metadata.getProviderAttachmentSupport(expectation.providerKind)).toEqual(
          expectation.expectedAttachmentSupport,
        );

        // Canonical model count.
        expect(metadata.listProviderModelIds(expectation.providerKind).length).toBe(
          expectation.expectedCanonicalModelCount,
        );
      });
    }
  });

  describe('validation contract (BYOK key checks)', () => {
    // Providers that carry a validation contract in the fixture (probe, probePath, authMode,
    // headerProfile, invalidKeySignals). Assert the current fields are published and shaped correctly.
    const providersWithValidation = Object.entries(contract.metadata.providers)
      .filter(([, provider]) => provider.validation != null);

    for (const [providerKind, providerData] of providersWithValidation) {
      it(`${providerKind} — getProviderValidation publishes the new contract fields and none of the old ones`, async () => {
        const metadata = await loadMetadataModule();
        const validation = metadata.getProviderValidation(providerKind);

        expect(validation).toBeDefined();
        // The current contract fields match the fixture.
        expect(validation?.probe).toBe(providerData.validation?.probe);
        expect(validation?.probePath).toBe(providerData.validation?.probePath);
        expect(validation?.authMode).toBe(providerData.validation?.authMode);
        expect(validation?.headerProfile).toBe(providerData.validation?.headerProfile);
        expect(validation?.invalidKeySignals).toEqual(
          providerData.validation?.invalidKeySignals,
        );

        // None of the legacy fields are published.
        const raw = validation as unknown as Record<string, unknown>;
        expect(raw.modelId).toBeUndefined();
        expect(raw.transport).toBeUndefined();
        expect(raw.maxTokens).toBeUndefined();
        expect(raw.tolerableErrors).toBeUndefined();
      });
    }
  });

  describe('modelExpectations', () => {
    for (const expectation of contract.modelExpectations) {
      it(`${expectation.id} — resolveCatalogModel(${expectation.query}, ${expectation.providerKind})`, async () => {
        const metadata = await loadMetadataModule();
        const resolved = metadata.resolveCatalogModel(
          expectation.query,
          expectation.providerKind,
        );

        expect(resolved).not.toBeNull();
        if (!resolved) return;

        // Base fields.
        expect(resolved.canonicalModelId).toBe(expectation.expectedCanonicalModelId);
        expect(resolved.displayName).toBe(expectation.expectedDisplayName);
        expect(resolved.contextLength ?? null).toBe(expectation.expectedContextLength);
        expect(resolved.maxOutputTokens ?? null).toBe(expectation.expectedMaxOutputTokens ?? null);
        expect(resolved.supportsTemperature ?? null).toBe(expectation.expectedSupportsTemperature ?? null);
        expect(resolved.pricingStatus).toBe(expectation.expectedPricingStatus);
        expect(resolved.isDefault).toBe(expectation.expectedIsDefault);

        // pricing: null when unknown; for priced/free, converted from perMToken to perToken.
        if (expectation.expectedPricingStatus === 'unknown') {
          expect(resolved.pricing).toBeNull();
        } else {
          expect(resolved.pricing).not.toBeNull();
          expect(resolved.pricing!.promptPerToken).toBeCloseTo(
            (expectation.expectedPromptPerMToken ?? 0) / 1_000_000,
            15,
          );
          expect(resolved.pricing!.completionPerToken).toBeCloseTo(
            (expectation.expectedCompletionPerMToken ?? 0) / 1_000_000,
            15,
          );
          // cachedInputPerMToken keeps its perMToken unit.
          if (expectation.expectedCachedInputPerMToken == null) {
            expect(resolved.pricing!.cachedInputPerMToken ?? null).toBeNull();
          } else {
            expect(resolved.pricing!.cachedInputPerMToken).toBe(
              expectation.expectedCachedInputPerMToken,
            );
          }
        }

        // capabilities: normalizeCapabilities always puts text first and sorts the rest by badgeOrder,
        // so the fixture's expectedCapabilities order does not necessarily match. Compare as sets to
        // check coverage and deduplication; tighten to strict ordering once the fixture and normalize
        // agree. Known mismatches: qwen3.5-plus, glm-4.7-plus and anthropic/claude-sonnet-4 list
        // capabilities in a different order than normalizeCapabilities emits.
        expect([...resolved.capabilities].sort()).toEqual(
          [...expectation.expectedCapabilities].sort(),
        );

        // profiles: null and undefined are equivalent.
        expect(resolved.profiles.reasoning ?? null).toBe(expectation.expectedReasoningProfile);
        expect(resolved.profiles.webSearch ?? null).toBe(expectation.expectedWebSearchProfile);
        expect(resolved.profiles.imageGen ?? null).toBe(expectation.expectedImageGenProfile);

        // uiHints
        expect(resolved.uiHints?.groupKey).toBe(expectation.expectedGroupKey);
        expect(resolved.uiHints?.groupName).toBe(expectation.expectedGroupName);
        expect(resolved.uiHints?.recommended ?? false).toBe(expectation.expectedRecommended);
        // badgeOrder is order-sensitive: normalizeUIHints only filters out text and does not reorder.
        expect(resolved.uiHints?.badgeOrder ?? []).toEqual(expectation.expectedBadgeOrder);
      });
    }
  });

  describe('vendorIntegrityExpectations', () => {
    /**
     * vendor is not exposed through ResolvedModelMetadata, so read it from the raw snapshot fields.
     * This contract keeps the backend as the single source of vendor information; clients must never
     * infer it from the model id slug.
     */
    for (const expectation of contract.vendorIntegrityExpectations.expectations) {
      it(`${expectation.providerKind}/${expectation.modelId} — vendorKey=${
        expectation.vendorKey ?? 'null'
      } vendorName=${expectation.vendorName ?? 'null'}`, async () => {
        const metadata = await loadMetadataModule();
        const snapshot = metadata.getMetadataSnapshot();
        expect(snapshot).not.toBeNull();
        const provider = (snapshot?.providers as Record<
          string,
          { models?: Record<string, { vendorKey?: string | null; vendorName?: string | null }> }
        >)[expectation.providerKind];
        const model = provider?.models?.[expectation.modelId];
        expect(model).toBeDefined();
        expect((model?.vendorKey ?? null) || null).toBe(expectation.vendorKey);
        expect((model?.vendorName ?? null) || null).toBe(expectation.vendorName);
      });
    }

    it('every model of an aggregating provider has a non-empty vendorKey', async () => {
      const metadata = await loadMetadataModule();
      const snapshot = metadata.getMetadataSnapshot();
      expect(snapshot).not.toBeNull();
      for (const providerKind of contract.vendorIntegrityExpectations.aggregatorProviders) {
        const provider = (snapshot?.providers as Record<
          string,
          { models?: Record<string, { vendorKey?: string | null }> }
        >)[providerKind];
        expect(provider).toBeDefined();
        for (const [modelId, model] of Object.entries(provider?.models ?? {})) {
          expect(
            typeof model.vendorKey === 'string' && model.vendorKey.length > 0,
            `aggregator ${providerKind}/${modelId} missing vendorKey`,
          ).toBe(true);
        }
      }
    });

    it('no model of a direct provider carries a vendorKey', async () => {
      const metadata = await loadMetadataModule();
      const snapshot = metadata.getMetadataSnapshot();
      expect(snapshot).not.toBeNull();
      for (const providerKind of contract.vendorIntegrityExpectations.directProviders) {
        const provider = (snapshot?.providers as Record<
          string,
          { models?: Record<string, { vendorKey?: string | null }> }
        >)[providerKind];
        expect(provider).toBeDefined();
        for (const [modelId, model] of Object.entries(provider?.models ?? {})) {
          expect(
            model.vendorKey == null || model.vendorKey === '',
            `direct ${providerKind}/${modelId} should not carry vendorKey, got ${String(
              model.vendorKey,
            )}`,
          ).toBe(true);
        }
      }
    });
  });

  describe('negativeExpectations', () => {
    for (const expectation of contract.negativeExpectations) {
      it(`${expectation.id} — resolveCatalogModel(${expectation.query}, ${expectation.providerKind}) === null`, async () => {
        const metadata = await loadMetadataModule();
        const resolved = metadata.resolveCatalogModel(
          expectation.query,
          expectation.providerKind,
        );
        expect(resolved).toBeNull();
      });
    }
  });

  describe('core contract', () => {
    /**
     * The official resolver does not rely on an adapter's chat-only filter.
     * Qwen's qwen-image only has the imageGeneration capability and is not a chat model, yet the
     * metadata resolver must still return its full field set; filtering for the chat path is the
     * adapter's job and is decoupled from authoritative metadata resolution.
     */
    it('an imageGeneration model is still fully resolved by the metadata resolver and not blocked by the chat-only filter', async () => {
      const metadata = await loadMetadataModule();
      const resolved = metadata.resolveCatalogModel('qwen-image', 'qwen');
      expect(resolved).not.toBeNull();
      expect(resolved?.canonicalModelId).toBe('qwen-image');
      expect(resolved?.profiles.imageGen).toBe('qwen_image_v1');
      expect(resolved?.capabilities).toContain('imageGeneration');
    });
  });
});
