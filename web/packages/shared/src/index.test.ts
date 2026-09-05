import { describe, expect, it } from 'vitest';

import {
  formatApiKeyPreview,
  FOLDER_COLOR_ORDER,
  getFolderColorPair,
  getNextFolderColor,
  isValidProviderKind,
  PROVIDER_KINDS,
  siteNavigation,
  starterTasks,
  type Folder,
  type Skill,
} from './index';

function folder(overrides: Partial<Folder>): Folder {
  return {
    id: 'folder-1',
    name: 'Folder',
    sortOrder: 0,
    createdAt: '2026-04-10T00:00:00Z',
    updatedAt: '2026-04-10T00:00:00Z',
    ...overrides,
  };
}

describe('@oriveo/shared', () => {
  it('exports the provider kind contract used by other packages', () => {
    expect(PROVIDER_KINDS).toContain('deepseek');
    expect(PROVIDER_KINDS).toContain('grok');
    expect(PROVIDER_KINDS).toContain('mistral');
    expect(PROVIDER_KINDS).toContain('moonshot');
    expect(PROVIDER_KINDS).toContain('openAI');
    expect(PROVIDER_KINDS).toContain('relay');
    expect(PROVIDER_KINDS).toHaveLength(16);
    expect(isValidProviderKind('openAI')).toBe(true);
    expect(isValidProviderKind('deepseek')).toBe(true);
    expect(isValidProviderKind('openAI')).toBe(true);
    expect(isValidProviderKind('anthropic')).toBe(true);
    expect(isValidProviderKind('relay')).toBe(true);
    expect(isValidProviderKind('Relay')).toBe(false);
  });

  it('formats API keys and folder colors with safe fallbacks', () => {
    expect(formatApiKeyPreview('  sk-abc123xyz7890  ')).toBe('sk-a...7890');
    expect(formatApiKeyPreview('short-key')).toBe('••••••••');
    expect(formatApiKeyPreview('')).toBe('');
    expect(getFolderColorPair('purple')).toEqual(['#8B5CF6', '#7C3AED']);
    expect(getFolderColorPair('unknown')).toEqual(['#3B82F6', '#2563EB']);
  });

  it('rotates folder colors from the highest sort order and wraps cleanly', () => {
    expect(getNextFolderColor([])).toBe('blue');
    expect(
      getNextFolderColor([
        folder({ id: 'b', sortOrder: 20, colorTag: 'purple' }),
        folder({ id: 'a', sortOrder: 10, colorTag: 'orange' }),
      ]),
    ).toBe('pink');
    expect(
      getNextFolderColor([
        folder({ sortOrder: 99, colorTag: FOLDER_COLOR_ORDER[FOLDER_COLOR_ORDER.length - 1] }),
      ]),
    ).toBe('blue');
    expect(getNextFolderColor([folder({ sortOrder: 1, colorTag: 'missing' })])).toBe('blue');
  });

  it('exports shared marketing/navigation constants consumed by apps', () => {
    expect(siteNavigation.map((item) => item.href)).toEqual([
      '#features',
      '#download',
      '/privacy',
      '/terms',
    ]);
    expect(starterTasks).toHaveLength(4);
    expect(starterTasks[0]?.title).toBe('Configure a Provider');
    expect(starterTasks[3]?.title).toBe('Track spend');
  });

  it('exports the stage A skill knowledge contract used across platforms', () => {
    const skill: Skill = {
      id: 'skill-1',
      name: 'Knowledge',
      description: '',
      icon: '📚',
      color: '#111111',
      systemPrompt: 'Prompt',
      modelCapabilityHint: 'any',
      starterMessages: [],
      knowledgeFiles: [
        {
          id: 'file-1',
          name: 'rules.md',
          mimeType: 'text/markdown',
          sourceType: 'text',
          content: 'Always explain why.',
          charCount: 19,
          createdAt: '2026-04-12T00:00:00Z',
          updatedAt: '2026-04-12T00:00:00Z',
        },
      ],
      knowledgeBase: {
        provider: 'openai',
        retrievalModel: 'gpt-5.4-mini',
        vectorStoreId: 'vs_123',
        expiresAfterDays: 90,
        files: [
          {
            id: 'kb-file-1',
            name: 'manual.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 2048,
            ingestionMode: 'native_file',
            status: 'ready',
            errorCode: 'knowledge_index_failed',
            createdAt: '2026-04-12T00:00:00Z',
            updatedAt: '2026-04-12T00:00:00Z',
          },
        ],
        updatedAt: '2026-04-12T00:00:00Z',
      },
      useMemory: true,
      isPinned: false,
      pinOrder: 0,
      source: 'user',
      sortOrder: 0,
      usageCount: 0,
      createdAt: '2026-04-12T00:00:00Z',
      updatedAt: '2026-04-12T00:00:00Z',
    };

    expect(skill.knowledgeFiles[0]?.mimeType).toBe('text/markdown');
    expect(skill.knowledgeBase?.files[0]?.status).toBe('ready');
    expect(skill.knowledgeBase?.files[0]?.errorCode).toBe('knowledge_index_failed');
  });
});
