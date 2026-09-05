import { describe, expect, it } from 'vitest';
import type { SkillKnowledgeBase } from '@oriveo/shared';
import {
  buildDraftKnowledgeCleanupPlan,
  requiresRemoteKnowledgeCleanup,
} from './knowledge-utils';

describe('knowledge-utils cleanup planning', () => {
  it('collects only draft-created remote files when replacing a persisted file', () => {
    const originalKnowledgeBase: SkillKnowledgeBase = {
      provider: 'openai',
      retrievalModel: 'gpt-5.4-mini',
      vectorStoreId: 'vs_123',
      expiresAfterDays: 90,
      files: [
        {
          id: 'kb-1',
          name: 'guide.txt',
          mimeType: 'text/plain',
          sizeBytes: 42,
          ingestionMode: 'native_file',
          openAIFileId: 'file-old-1',
          status: 'ready',
          createdAt: '2026-04-12T00:00:00.000Z',
          updatedAt: '2026-04-12T00:00:00.000Z',
        },
      ],
      updatedAt: '2026-04-12T00:00:00.000Z',
    };
    const currentKnowledgeBase: SkillKnowledgeBase = {
      ...originalKnowledgeBase,
      files: [
        {
          ...originalKnowledgeBase.files[0],
          openAIFileId: 'file-new-1',
          updatedAt: '2026-04-12T00:01:00.000Z',
        },
        {
          id: 'kb-2',
          name: 'appendix.txt',
          mimeType: 'text/plain',
          sizeBytes: 21,
          ingestionMode: 'native_file',
          openAIFileId: 'file-new-2',
          status: 'ready',
          createdAt: '2026-04-12T00:01:00.000Z',
          updatedAt: '2026-04-12T00:01:00.000Z',
        },
      ],
      updatedAt: '2026-04-12T00:01:00.000Z',
    };

    const plan = buildDraftKnowledgeCleanupPlan({
      originalKnowledgeBase,
      currentKnowledgeBase,
    });

    expect(plan).toEqual({
      vectorStoreId: 'vs_123',
      deleteVectorStore: false,
      openAIFileIds: ['file-new-1', 'file-new-2'],
    });
  });

  it('deletes the draft vector store when a new unsaved skill uploaded files', () => {
    const plan = buildDraftKnowledgeCleanupPlan({
      originalKnowledgeBase: null,
      currentKnowledgeBase: {
        provider: 'openai',
        retrievalModel: 'gpt-5.4-mini',
        vectorStoreId: 'vs_new',
        expiresAfterDays: 90,
        files: [
          {
            id: 'kb-1',
            name: 'guide.txt',
            mimeType: 'text/plain',
            sizeBytes: 42,
            ingestionMode: 'native_file',
            openAIFileId: 'file-temp-1',
            status: 'ready',
            createdAt: '2026-04-12T00:00:00.000Z',
            updatedAt: '2026-04-12T00:00:00.000Z',
          },
        ],
        updatedAt: '2026-04-12T00:00:00.000Z',
      },
    });

    expect(plan).toEqual({
      vectorStoreId: 'vs_new',
      deleteVectorStore: true,
      openAIFileIds: ['file-temp-1'],
    });
  });

  it('requires remote cleanup only when persisted resources are removed', () => {
    const originalKnowledgeBase: SkillKnowledgeBase = {
      provider: 'openai',
      retrievalModel: 'gpt-5.4-mini',
      vectorStoreId: 'vs_123',
      expiresAfterDays: 90,
      files: [
        {
          id: 'kb-1',
          name: 'guide.txt',
          mimeType: 'text/plain',
          sizeBytes: 42,
          ingestionMode: 'native_file',
          openAIFileId: 'file-old-1',
          status: 'ready',
          createdAt: '2026-04-12T00:00:00.000Z',
          updatedAt: '2026-04-12T00:00:00.000Z',
        },
      ],
      updatedAt: '2026-04-12T00:00:00.000Z',
    };

    expect(requiresRemoteKnowledgeCleanup({
      originalKnowledgeBase,
      currentKnowledgeBase: {
        ...originalKnowledgeBase,
        files: [
          {
            ...originalKnowledgeBase.files[0],
            openAIFileId: 'file-new-1',
            updatedAt: '2026-04-12T00:01:00.000Z',
          },
        ],
      },
    })).toBe(true);

    expect(requiresRemoteKnowledgeCleanup({
      originalKnowledgeBase,
      currentKnowledgeBase: originalKnowledgeBase,
    })).toBe(false);
  });
});
