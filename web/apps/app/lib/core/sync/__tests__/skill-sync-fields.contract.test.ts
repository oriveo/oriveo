/**
 * skill_sync_fields.v1 contract: Web conversation / message Firestore mappings must produce the fixture's
 * expected skill keys byte for byte.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import type { ChatMessage, Conversation } from '@oriveo/shared';
import { conversationSkillIds } from '@oriveo/shared';

const mockSetDoc = vi.fn().mockResolvedValue(undefined);
vi.mock('firebase/firestore', async (importOriginal) => ({
  ...(await importOriginal<typeof import('firebase/firestore')>()),
  doc: (_db: unknown, ...segments: string[]) => ({ path: segments.join('/') }),
  setDoc: (...args: unknown[]) => mockSetDoc(...args),
  serverTimestamp: () => ({ _sentinel: 'serverTimestamp' }),
  deleteField: () => ({ _sentinel: 'deleteField' }),
}));

const mockAdapter = { didUpdateConversationDisabledAutoSkills: vi.fn() };
vi.mock('../../sync', () => ({
  getSyncAdapter: () => mockAdapter,
  deleteAttachments: vi.fn(),
  flushPendingConversationDeletions: vi.fn(),
}));

import {
  conversationFromFirestore,
  conversationToFirestore,
  conversationToFirestoreSentinelMerge,
  messageFromFirestore,
  messageToFirestore,
} from '../sync-mappings';
import { writeUpdateConversationDisabledAutoSkills } from '../sync-writer';
import { disableAutoSkill } from '../../conversation-ops';

const CONTRACT_FILE = 'skill_sync_fields.v1.json';
const CONTRACT = JSON.parse(readFileSync(
  resolve(__dirname, '../../../../../../../../\u5171\u4eab/skill-contracts', CONTRACT_FILE), 'utf8',
)) as {
  conversationWriteCases: Array<{ id: string; input: { skillIds: string[]; disabledAutoSkillIds: string[] }; expected: Record<string, unknown> }>;
  conversationReadCases: Array<{ id: string; input: Record<string, unknown>; expected: { skillIds: string[]; disabledAutoSkillIds: string[] } }>;
  messageWriteCases: Array<{ id: string; input: Record<string, unknown>; expected: Record<string, unknown> }>;
  messageReadCases: Array<{ id: string; input: Record<string, unknown>; expected: { attachedSkillIds: string[]; usedSkills: unknown[] } }>;
};

const CONVERSATION_SKILL_KEYS = ['skillIds', 'skillId', 'disabledAutoSkillIds'];
const MESSAGE_SKILL_KEYS = ['attachedSkillIds', 'usedSkills'];

function pick(data: Record<string, unknown>, keys: string[]): Record<string, unknown> {
  return Object.fromEntries(keys.filter((key) => key in data).map((key) => [key, data[key]]));
}

function makeConversation(patch: Partial<Conversation> = {}): Conversation {
  return {
    id: 'C0000000-0000-4000-8000-000000000001',
    title: 'Chat',
    hasCustomTitle: false,
    providerID: 'A0000000-0000-4000-8000-000000000001',
    providerKind: 'openAI',
    modelID: 'gpt-5',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-10-01T08:00:00.000Z',
    createdAt: '2026-10-01T07:00:00.000Z',
    ...patch,
  } as Conversation;
}

const FS_CONVERSATION_BASE = {
  title: 'Chat',
  providerID: 'A0000000-0000-4000-8000-000000000001',
  providerKind: 'openAI',
  modelID: 'gpt-5',
};

function makeMessage(input: Record<string, unknown>): ChatMessage {
  return {
    id: 'D0000000-0000-4000-8000-000000000001',
    text: 'hi',
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'GPT-5',
    estimatedCost: 0,
    state: 'delivered',
    createdAt: '2026-10-01T08:00:00.000Z',
    ...input,
  } as ChatMessage;
}

describe(`${CONTRACT_FILE} conversationWriteCases`, () => {
  for (const c of CONTRACT.conversationWriteCases) {
    it(c.id, () => {
      const data = conversationToFirestore(makeConversation(c.input));
      expect(pick(data, CONVERSATION_SKILL_KEYS)).toEqual(c.expected);
    });
  }
});

describe(`${CONTRACT_FILE} conversationReadCases`, () => {
  for (const c of CONTRACT.conversationReadCases) {
    it(c.id, () => {
      const conv = conversationFromFirestore('conv-1', { ...FS_CONVERSATION_BASE, ...c.input })!;
      expect({
        skillIds: conversationSkillIds(conv),
        disabledAutoSkillIds: conv.disabledAutoSkillIds ?? [],
      }).toEqual(c.expected);
      // Local dual write: the legacy column follows skillIds[0]
      expect(conv.skillId).toBe(c.expected.skillIds[0]);
    });
  }
});

describe(`${CONTRACT_FILE} messageWriteCases`, () => {
  for (const c of CONTRACT.messageWriteCases) {
    it(c.id, () => {
      const data = messageToFirestore(makeMessage(c.input));
      expect(pick(data, MESSAGE_SKILL_KEYS)).toEqual(c.expected);
    });
  }
});

describe(`${CONTRACT_FILE} messageReadCases`, () => {
  for (const c of CONTRACT.messageReadCases) {
    it(c.id, () => {
      const msg = messageFromFirestore('msg-1', { text: '', ...c.input })!;
      expect({
        attachedSkillIds: msg.attachedSkillIds ?? [],
        usedSkills: msg.usedSkills ?? [],
      }).toEqual(c.expected);
    });
  }
});

describe('legacy skillId rollback', () => {
  it('old local conversation carrying only skillId reads as [skillId]', () => {
    const old = makeConversation({ skillId: '1F0A2B3C-0000-4000-8000-000000000001' });
    expect(conversationSkillIds(old)).toEqual(['1F0A2B3C-0000-4000-8000-000000000001']);
    expect(conversationToFirestore(old)).toMatchObject({
      skillIds: ['1F0A2B3C-0000-4000-8000-000000000001'],
      skillId: '1F0A2B3C-0000-4000-8000-000000000001',
    });
  });

  it('two-skill conversation keeps the legacy skillId = first id', () => {
    const doc = conversationToFirestore(makeConversation({
      skillIds: ['1f0a2b3c-0000-4000-8000-000000000001', '0c9d8e7f-0000-4000-8000-000000000002'],
    }));
    expect(doc['skillId']).toBe('1F0A2B3C-0000-4000-8000-000000000001');
    const local = conversationFromFirestore('conv-1', { ...FS_CONVERSATION_BASE, ...doc })!;
    expect(local.skillIds).toEqual(['1F0A2B3C-0000-4000-8000-000000000001', '0C9D8E7F-0000-4000-8000-000000000002']);
    expect(local.skillId).toBe('1F0A2B3C-0000-4000-8000-000000000001');
  });

  it('sentinel merge clears empty skill keys with explicit null', () => {
    const data = conversationToFirestoreSentinelMerge(makeConversation({ createdAt: new Date(0).toISOString() }));
    expect(data['skillIds']).toBeNull();
    expect(data['disabledAutoSkillIds']).toBeNull();
  });
});

describe('disableAutoSkill', () => {
  function makeStore(conv: Conversation) {
    const state = {
      conversations: [conv],
      updateConversation: vi.fn((id: string, patch: Partial<Conversation>) => {
        state.conversations = state.conversations.map((c) => (c.id === id ? { ...c, ...patch } : c));
      }),
    };
    return { getState: () => state } as never;
  }

  it('appends once and merges the single key to the cloud', () => {
    const conv = makeConversation({ disabledAutoSkillIds: ['5A5A5A5A-0000-4000-8000-000000000003'] });
    const store = makeStore(conv);
    expect(disableAutoSkill(store, conv.id, '1f0a2b3c-0000-4000-8000-000000000001')).toBe(true);
    expect(disableAutoSkill(store, conv.id, '1F0A2B3C-0000-4000-8000-000000000001')).toBe(false);
    const next = ['5A5A5A5A-0000-4000-8000-000000000003', '1F0A2B3C-0000-4000-8000-000000000001'];
    expect((store as { getState: () => { conversations: Conversation[] } }).getState().conversations[0].disabledAutoSkillIds)
      .toEqual(next);
    expect(mockAdapter.didUpdateConversationDisabledAutoSkills).toHaveBeenCalledTimes(1);
    expect(mockAdapter.didUpdateConversationDisabledAutoSkills).toHaveBeenCalledWith(conv.id, next);
  });

  it('writer merges only disabledAutoSkillIds and deletes the key when empty', () => {
    const ctx = { db: {}, conversationsCol: 'users/u1/conversations' } as never;
    writeUpdateConversationDisabledAutoSkills(ctx, 'conv-1', ['77777777-0000-4000-8000-000000000004']);
    writeUpdateConversationDisabledAutoSkills(ctx, 'conv-1', []);
    expect(mockSetDoc.mock.calls[0][1]).toEqual({
      disabledAutoSkillIds: ['77777777-0000-4000-8000-000000000004'],
      metadataUpdatedAt: { _sentinel: 'serverTimestamp' },
    });
    expect(mockSetDoc.mock.calls[0][2]).toEqual({ merge: true });
    expect(mockSetDoc.mock.calls[1][1]['disabledAutoSkillIds']).toEqual({ _sentinel: 'deleteField' });
  });
});
