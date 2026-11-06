/**
 * Metadata decode of the ImageProfile wire fields: profiles.image, model
 * imageProfile / imageProfileOverride and providers.<kind>.imageModels, through
 * the split (index + catalog) and lean shapes, then the MetadataResponse -> slice
 * adapter feeding resolveImageProfile. Corpus is the shared
 * metadata_catalog_contract.v1.json fixture.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { MetadataResponse } from '../../metadata/metadata-client';
import {
  assembleLeanFromSplit,
  expandMetadataCatalog,
  indexCatalogRevision,
  type ExpandedMetadataCatalog,
  type MetadataIndexPayload,
} from '../../metadata/metadata-split';
import { imageMetadataSliceFromMetadata, resolveImageProfile } from '../image-profile';

const ROOT = resolve(__dirname, '../../../../../../..');
const CONTRACTS = resolve(ROOT, 'shared/model-contracts');

type JsonRecord = Record<string, unknown>;

interface CatalogContractFixture {
  leanEquivalent: { data: JsonRecord & { providers: Record<string, { models: Record<string, JsonRecord> }> } };
  schema3: {
    indexResponse: { data: JsonRecord & { profiles: { image: Record<string, JsonRecord> } } };
    catalogResponses: Record<string, { data: JsonRecord & { models: Record<string, JsonRecord> } }>;
  };
}

function loadFixture(): CatalogContractFixture {
  return JSON.parse(
    readFileSync(resolve(CONTRACTS, 'metadata_catalog_contract.v1.json'), 'utf8'),
  ) as CatalogContractFixture;
}

const IMAGE_PROVIDER = 'openRouter';
const IMAGE_MODEL = 'openai/gpt-image-2';
const IMAGE_PROFILE_REF = 'openrouter_gpt_images';

function expandOk(index: MetadataIndexPayload, kind: string, data: unknown): ExpandedMetadataCatalog {
  const result = expandMetadataCatalog(data, { provider: kind, revision: indexCatalogRevision(index, kind) });
  if (!result.ok) throw new Error(`catalog ${kind} rejected: ${result.reason}`);
  return result.catalog;
}

/** Expands every schema 3 catalog (with optional per-kind overrides) and assembles the lean view. */
function assembleSchema3(
  fixture: CatalogContractFixture,
  overrides: Record<string, unknown> = {},
): { assembled: MetadataResponse; catalogs: Map<string, ExpandedMetadataCatalog> } {
  const index = fixture.schema3.indexResponse.data as unknown as MetadataIndexPayload;
  const catalogs = new Map<string, ExpandedMetadataCatalog>();
  for (const [kind, response] of Object.entries(fixture.schema3.catalogResponses)) {
    catalogs.set(kind, expandOk(index, kind, overrides[kind] ?? response.data));
  }
  const assembled = assembleLeanFromSplit(index, catalogs) as unknown as MetadataResponse;
  return { assembled: JSON.parse(JSON.stringify(assembled)) as MetadataResponse, catalogs };
}

describe('image_profile_metadata_decode', () => {
  it('split path carries catalog imageModels and resolves the OpenRouter image model', () => {
    const fixture = loadFixture();
    const rawCatalog = fixture.schema3.catalogResponses[IMAGE_PROVIDER].data;
    const { assembled, catalogs } = assembleSchema3(fixture);

    expect(catalogs.get(IMAGE_PROVIDER)?.imageModels).toEqual(rawCatalog.imageModels);
    const slice = imageMetadataSliceFromMetadata(assembled);
    expect(Object.keys(slice.profiles?.image ?? {}))
      .toEqual(Object.keys(fixture.schema3.indexResponse.data.profiles.image));

    const resolution = resolveImageProfile(slice, IMAGE_PROVIDER, IMAGE_MODEL);
    expect(resolution.reason).toBeNull();
    expect(resolution.profileRef).toBe(IMAGE_PROFILE_REF);
    expect(resolution.profile?.route).toBe('openrouter_images');
    expect(resolution.appliedOverride).toBeNull();
  });

  it('catalog modelDefaults imageProfile reaches every expanded model', () => {
    const fixture = loadFixture();
    const rawCatalog = fixture.schema3.catalogResponses[IMAGE_PROVIDER].data;
    const injected = {
      ...rawCatalog,
      modelDefaults: { ...(rawCatalog.modelDefaults as JsonRecord), imageProfile: IMAGE_PROFILE_REF },
    };
    const { assembled } = assembleSchema3(fixture, { [IMAGE_PROVIDER]: injected });
    const slice = imageMetadataSliceFromMetadata(assembled);

    const modelIds = Object.keys(rawCatalog.models);
    expect(modelIds.length).toBeGreaterThan(0);
    for (const modelId of modelIds) {
      const resolution = resolveImageProfile(slice, IMAGE_PROVIDER, modelId);
      expect({ modelId, reason: resolution.reason, profileRef: resolution.profileRef })
        .toEqual({ modelId, reason: null, profileRef: IMAGE_PROFILE_REF });
    }
  });

  it('lean payload model imageProfile and imageProfileOverride merge through the adapter', () => {
    const fixture = loadFixture();
    const lean = JSON.parse(JSON.stringify(fixture.leanEquivalent.data)) as JsonRecord & {
      profiles: JsonRecord;
      providers: Record<string, { models: Record<string, JsonRecord> }>;
    };
    lean.profiles = { ...lean.profiles, image: fixture.schema3.indexResponse.data.profiles.image };
    const [providerKind, provider] = Object.entries(lean.providers)[0];
    const [overriddenId, plainId] = Object.keys(provider.models);
    const override = { timeoutSeconds: 240 };
    provider.models[overriddenId] = {
      ...provider.models[overriddenId],
      imageProfile: IMAGE_PROFILE_REF,
      imageProfileOverride: override,
    };
    provider.models[plainId] = {
      ...provider.models[plainId],
      imageProfile: IMAGE_PROFILE_REF,
      imageProfileOverride: 'not-an-object',
    };

    const slice = imageMetadataSliceFromMetadata(lean as unknown as MetadataResponse);
    const overridden = resolveImageProfile(slice, providerKind, overriddenId);
    expect(overridden.reason).toBeNull();
    expect(overridden.profileRef).toBe(IMAGE_PROFILE_REF);
    expect(overridden.appliedOverride).toEqual(override);
    expect(overridden.profile?.timeoutSeconds).toBe(240);

    const plain = resolveImageProfile(slice, providerKind, plainId);
    expect(plain.reason).toBeNull();
    expect(plain.appliedOverride).toBeNull();
    expect(plain.profile?.timeoutSeconds)
      .toBe(fixture.schema3.indexResponse.data.profiles.image[IMAGE_PROFILE_REF].timeoutSeconds);
  });
});
