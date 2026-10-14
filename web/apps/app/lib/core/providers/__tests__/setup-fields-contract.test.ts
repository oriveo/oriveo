import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 */
// setupFields fixture replayed per caseId. Decoding goes through the production metadata decode layer,
// the form uses the same build function as the setup page, and the request-time address goes through production resolveBaseURL.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import { __seedMetadataCacheForTest as seedMetadataCache } from '../../metadata/metadata-client';

type RawConfig = Record<string, unknown> & { kind: string; defaultBaseURL: string };
type Fixture = {
  config: RawConfig;
  decodeCases: Array<{
    caseId: string;
    configPatch?: Record<string, unknown>;
    expectRegionIds?: string[];
    dropped?: string;
  }>;
  formCases: Array<{
    caseId: string;
    configPatch?: Record<string, unknown>;
    regionId: string;
    expectFields: string[];
    value: string | null;
    expectSubmit: boolean;
    expect?: Record<string, unknown>;
  }>;
  resolveCases: Array<{
    caseId: string;
    stored: { baseURLText: string; endpointSource: string; setupValues: Record<string, string> | null };
    metadataPatch: Record<string, unknown>;
    expectBaseURL: string;
  }>;
};

const repositoryRoot = resolve(process.cwd(), '../../..');
const fixture = JSON.parse(readFileSync(
  resolve(repositoryRoot, 'shared/test-fixtures/provider-catalog/setup-fields.v1.json'),
  'utf8',
)) as Fixture;

function patched(config: RawConfig, patch: Record<string, unknown> = {}): RawConfig {
  const next: RawConfig = JSON.parse(JSON.stringify(config));
  for (const [path, value] of Object.entries(patch)) {
    const parts = path.split('.');
    if (parts[0] === 'regionOptions' && parts.length === 3) {
      next.regionOptions = (next.regionOptions as Array<Record<string, unknown>>).map((option) =>
        option.id === parts[1] ? { ...option, [parts[2]!]: value } : option);
    } else {
      next[path] = value;
    }
  }
  return next;
}

// Module instance imported by the previous case: its deferred idle-callback persistence may overwrite the next case's seeding, so afterEach waits for it to settle.
let lastMetadata: typeof import('../../metadata/metadata-client') | null = null;

async function loadMetadata(config: RawConfig) {
  vi.resetModules();
  await pruneBlobs(() => true);
  await seedMetadataCache({
    timestamp: Date.now(),
    data: {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-11T00:00:00Z',
      profiles: {},
      providers: {
        [config.kind]: { transport: { baseUrl: config.defaultBaseURL, endpoints: {} }, models: {} },
      },
      providerConfigs: [{ displayName: config.kind, ...config }],
    } as never,
  });
  vi.spyOn(globalThis, 'fetch').mockResolvedValue({ status: 304, ok: false, json: vi.fn() } as unknown as Response);
  const metadata = await import('../../metadata/metadata-client');
  lastMetadata = metadata;
  await metadata.initMetadata();
  const endpointSource = await import('../endpoint-source');
  const resolver = await import('../transport/endpoint-resolver');
  return { metadata, endpointSource, resolver };
}

describe('setup-fields.v1 fixture', () => {
  beforeEach(async () => {
    await pruneBlobs(() => true);
  });
  afterEach(async () => {
    await lastMetadata?.__settleMetadataBackgroundWorkForTest();
    lastMetadata = null;
    vi.restoreAllMocks();
  });

  for (const testCase of fixture.decodeCases) {
    it(`SETUP-FIELDS-${testCase.caseId}`, async () => {
      const { metadata } = await loadMetadata(patched(fixture.config, testCase.configPatch));
      const ids = metadata.getPublicProviderConfig('qwen')?.regionOptions?.map((option) => option.id) ?? [];
      if (testCase.expectRegionIds) expect(ids).toEqual(testCase.expectRegionIds);
      if (testCase.dropped) expect(ids).not.toContain(testCase.dropped);
    });
  }

  // defaultBaseURL template and regionOptions go through the same decode filtering: unusable means treated as missing, falling back to the built-in default.
  const defaultTemplateCases: Array<{ label: string; defaultBaseURL: string; setupFields?: null; kept: boolean }> = [
    { label: 'untrusted host', defaultBaseURL: 'https://{workspaceId}.example.com', kept: false },
    { label: 'unknown id', defaultBaseURL: 'https://{projectId}.ap-southeast-1.maas.aliyuncs.com', kept: false },
    { label: 'undeclared id', defaultBaseURL: 'https://{workspaceId}.ap-southeast-1.maas.aliyuncs.com', setupFields: null, kept: false },
    { label: 'trusted declared', defaultBaseURL: 'https://{workspaceId}.ap-southeast-1.maas.aliyuncs.com', kept: true },
  ];
  for (const testCase of defaultTemplateCases) {
    it(`SETUP-FIELDS-default_template_untrusted_dropped (${testCase.label})`, async () => {
      const { metadata, resolver } = await loadMetadata(patched(fixture.config, {
        defaultBaseURL: testCase.defaultBaseURL,
        regionOptions: null,
        ...(testCase.setupFields !== undefined ? { setupFields: testCase.setupFields } : {}),
      }));
      const decoded = metadata.getPublicProviderConfig('qwen');
      expect(decoded?.defaultBaseURL).toBe(testCase.kept ? testCase.defaultBaseURL : undefined);
      // Production resolver: with a default source and a value, the dropped template does not take part in computation, and it falls back to the literal
      const provider: Provider = {
        id: 'qwen-1',
        kind: 'qwen',
        status: { kind: 'connected' },
        models: [],
        catalogModels: [],
        apiKey: 'sk-test',
        apiKeyPreview: 'sk-…',
        baseURLText: 'https://dashscope-intl.aliyuncs.com',
        endpointSource: 'default',
        setupValues: { workspaceId: 'ws-1' },
      };
      expect(resolver.resolveBaseURL(provider, 'qwen')).toBe(testCase.kept
        ? 'https://ws-1.ap-southeast-1.maas.aliyuncs.com'
        : 'https://dashscope-intl.aliyuncs.com');
    });
  }

  for (const testCase of fixture.formCases) {
    it(`SETUP-FIELDS-${testCase.caseId}`, async () => {
      const { metadata, endpointSource } = await loadMetadata(patched(fixture.config, testCase.configPatch));
      const config = endpointSource.endpointConfigFromPublic(metadata.getPublicProviderConfig('qwen'));
      const form = endpointSource.buildOfficialSetupEndpoint({
        kind: 'qwen',
        config: config!,
        regionId: testCase.regionId,
        values: testCase.value === null ? undefined : { workspaceId: testCase.value },
      });
      expect(form.fields).toEqual(testCase.expectFields);
      expect(form.result !== null).toBe(testCase.expectSubmit);
      if (testCase.expect) expect(form.result).toMatchObject(testCase.expect);
    });
  }

  for (const testCase of fixture.resolveCases) {
    it(`SETUP-FIELDS-${testCase.caseId}`, async () => {
      const { resolver } = await loadMetadata(patched(fixture.config, testCase.metadataPatch));
      const provider: Provider = {
        id: 'qwen-1',
        kind: 'qwen',
        status: { kind: 'connected' },
        models: [],
        catalogModels: [],
        apiKey: 'sk-test',
        apiKeyPreview: 'sk-…',
        baseURLText: testCase.stored.baseURLText,
        endpointSource: testCase.stored.endpointSource as Provider['endpointSource'],
        ...(testCase.stored.setupValues ? { setupValues: testCase.stored.setupValues } : {}),
      };
      // Address actually produced by the production resolver (the template is filled from this machine's setupValues)
      expect(resolver.resolveBaseURL(provider, 'qwen')).toBe(testCase.expectBaseURL);
    });
  }
});
