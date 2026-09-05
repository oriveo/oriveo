import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  compactContextText,
  buildModelsFromCatalog,
  type RemoteModel,
  type BuildModelsConfig,
} from '../openai-compatible';

vi.mock('../../../metadata/metadata-client', () => ({
  resolveCatalogModel: vi.fn(),
}));

import { resolveCatalogModel } from '../../../metadata/metadata-client';

const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);

describe('compactContextText', () => {
  it('shows millions as M', () => {
    expect(compactContextText(1_000_000)).toBe('1M');
    expect(compactContextText(2_500_000)).toBe('2M');
  });

  it('shows thousands as K', () => {
    expect(compactContextText(128_000)).toBe('128K');
    expect(compactContextText(8_192)).toBe('8K');
    expect(compactContextText(1_000)).toBe('1K');
  });

  it('returns undefined for undefined / 0 / negative values', () => {
    expect(compactContextText(undefined)).toBeUndefined();
    expect(compactContextText(0)).toBeUndefined();
    expect(compactContextText(-100)).toBeUndefined();
  });
});

describe('buildModelsFromCatalog', () => {
  const config: BuildModelsConfig = {
    contextLength: (remote) => remote.context_window,
  };

  beforeEach(() => {
    mockResolveCatalogModel.mockReset();
  });

  it('prefers the canonical / group / rank / default from metadata', () => {
    mockResolveCatalogModel.mockImplementation((modelID) => {
      if (modelID === 'llama-4-scout') {
        return {
          canonicalModelId: 'llama-4-scout',
          displayName: 'Llama 4 Scout',
          contextLength: 64_000,
          capabilities: ['text', 'image'],
          pricing: null,
          profiles: {},
          uiHints: {
            groupKey: 'llama-4',
            groupName: 'Llama 4',
            rank: 120,
            recommended: true,
            badgeOrder: ['image'],
          },
          isDefault: true,
        };
      }

      if (modelID === 'deepseek-r1-turbo') {
        return {
          canonicalModelId: 'deepseek-r1-turbo',
          displayName: 'DeepSeek R1 Turbo',
          contextLength: 128_000,
          capabilities: ['text', 'reasoning'],
          pricing: null,
          profiles: { reasoning: 'oai_chat' },
          uiHints: {
            groupKey: 'deepseek',
            groupName: 'DeepSeek',
            rank: 110,
            recommended: true,
            badgeOrder: ['reasoning'],
          },
          isDefault: false,
        };
      }

      return null;
    });

    const remotes: RemoteModel[] = [
      { id: 'deepseek-r1-turbo', context_window: 128_000 },
      { id: 'llama-4-scout', context_window: 64_000 },
      { id: 'unknown-model', context_window: 8_000 },
    ];

    const models = buildModelsFromCatalog(remotes, config, 'groq');
    expect(models).toHaveLength(3);

    expect(models[0]).toMatchObject({
      id: 'llama-4-scout',
      canonicalModelId: 'llama-4-scout',
      groupKey: 'llama-4',
      groupName: 'Llama 4',
      isDefault: true,
      isRecommended: true,
      sortRank: 120,
    });

    expect(models[1]).toMatchObject({
      id: 'deepseek-r1-turbo',
      reasoningModeAvailable: true,
      isRecommended: true,
      sortRank: 110,
    });

    expect(models[2]).toMatchObject({
      id: 'unknown-model',
      capabilities: ['text'],
      groupKey: undefined,
      groupName: undefined,
      isDefault: false,
    });
  });

  it('falls back conservatively to text and the remote context when metadata is missing', () => {
    mockResolveCatalogModel.mockReturnValue(null);

    const remotes: RemoteModel[] = [
      { id: 'model-a', context_window: 65_536 },
    ];

    const models = buildModelsFromCatalog(remotes, config, 'groq');
    expect(models[0]).toMatchObject({
      id: 'model-a',
      capabilities: ['text'],
      contextLength: 65_536,
      summary: '65K',
      reasoningModeAvailable: false,
    });
  });

  it('supports a custom displayName and createdAt', () => {
    mockResolveCatalogModel.mockReturnValue(null);

    const remotes: RemoteModel[] = [
      { id: 'accounts/fireworks/models/llama-4-scout', context_length: 64_000, created_at: 1234 },
    ];

    const models = buildModelsFromCatalog(remotes, {
      displayName: (remote) => remote.id.split('/').pop() ?? remote.id,
      contextLength: (remote) => remote.context_length,
      createdAt: (remote) => remote.created_at,
    }, 'fireworksAI');

    expect(models[0]).toMatchObject({
      name: 'llama-4-scout',
      createdAt: 1234,
      contextLength: 64_000,
    });
  });
});
