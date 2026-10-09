import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// Native file allowlist of catalog models: the nativeFileMimes / pdfNativeDefault delivered by metadata
// reach the AIModel through the production decode path (cache -> initMetadata -> resolveCatalogModel ->
// buildCatalogModel), and routing decides native upload vs text injection from them.

import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
  resolveCatalogModel,
} from '../metadata-client';
import { buildCatalogModel, enrichStoredModel } from '../../providers/catalog-model';
import { decideAttachmentRoute } from '../../attachments/attachment-router';

const PDF = 'application/pdf';

const METADATA_FIXTURE = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-10-09T00:00:00Z',
  profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
  providers: {
    gemini: {
      resolveMap: { 'gemini-doc': 'gemini-doc', 'gemini-plain': 'gemini-plain' },
      models: {
        'gemini-doc': {
          canonicalModelId: 'gemini-doc',
          capabilities: ['text', 'image', 'file'],
          profiles: {},
          nativeFileMimes: [' Application/PDF ', '', 7],
          pdfNativeDefault: true,
        },
        'gemini-plain': { canonicalModelId: 'gemini-plain', capabilities: ['text'], profiles: {} },
      },
    },
  },
  providerConfigs: [],
};

beforeAll(async () => {
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({ data: METADATA_FIXTURE as never, timestamp: Date.now() });
  await initMetadata();
});

afterAll(() => {
  __resetMetadataClientForTest();
});

describe('metadata -> AIModel native file allowlist', () => {
  it('decoding: keeps only non-empty strings and lower-cases them', () => {
    const resolved = resolveCatalogModel('gemini-doc', 'gemini');
    expect(resolved?.nativeFileMimes).toEqual([PDF]);
    expect(resolved?.pdfNativeDefault).toBe(true);
    const plain = resolveCatalogModel('gemini-plain', 'gemini');
    expect(plain?.nativeFileMimes).toBeUndefined();
    expect(plain?.pdfNativeDefault).toBeUndefined();
  });

  it('a catalog model carries the allowlist, and a text PDF goes native on the generateContent line', () => {
    const model = buildCatalogModel({ providerKind: 'gemini', runtimeModelId: 'gemini-doc', fallbackName: 'x' });
    expect(model.nativeFileMimes).toEqual([PDF]);
    expect(model.pdfNativeDefault).toBe(true);
    const attachment = {
      id: 'a', kind: 'file' as const, fileName: 'a.pdf', mimeType: PDF,
      originalBase64Data: 'ZmFrZQ==', base64Data: 'text',
    };
    expect(decideAttachmentRoute(attachment, { transport: 'gemini_generate' }, model)).toBe('native');
    expect(decideAttachmentRoute(attachment, { transport: 'gemini_interactions' }, model)).toBe('client_extract');
  });

  it('a stored model follows catalog refreshes; a catalog hit that no longer delivers it means withdrawn, and does not fall back to the stored value', () => {
    const stored = buildCatalogModel({ providerKind: 'gemini', runtimeModelId: 'gemini-plain', fallbackName: 'x' });
    const stale = { ...stored, nativeFileMimes: [PDF], pdfNativeDefault: true };
    const refreshed = enrichStoredModel(stale, 'gemini');
    expect(refreshed.nativeFileMimes).toBeUndefined();
    expect(refreshed.pdfNativeDefault).toBeUndefined();

    const gained = enrichStoredModel({ ...stored, id: 'gemini-doc' }, 'gemini');
    expect(gained.nativeFileMimes).toEqual([PDF]);

    // A model not in the catalog (added by hand) keeps its local value
    const manual = enrichStoredModel({ ...stale, id: 'not-in-catalog' }, 'gemini');
    expect(manual.nativeFileMimes).toEqual([PDF]);
  });
});
