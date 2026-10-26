// @vitest-environment jsdom
/**
 * With both web search and reasoning turned on in a new-conversation draft, both are still on after the first
 * turn is sent (reported: enabling web search and reasoning on the web, then reasoning was switched off
 * automatically once the AI finished answering).
 *
 * The production chain has three stages: the input box writes the draft slot (composer-web-preference, the same
 * entry ChatView uses) -> on the first send, when the conversation is created,
 * `migrateDraftScopedModelControls` moves the draft slot to the conversation layer (it is what the
 * new-conversation creation point in operations-send calls) -> once the conversation id is settled, ChatView's
 * restore reads the switches back through `readComposerCapabilityPreferences`.
 * On an official connection, web search and reasoning write the same draft slot of the same identity, so
 * writing one must preserve the other.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../../infra/storage/partition')>(),
  getActiveUIDSync: () => 'guest',
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => ({ revision: 'runtime-r7' }),
  resolveCatalogModel: () => ({ canonicalModelId: 'gpt-5', transport: 'openai_responses' }),
}));

import {
  readComposerCapabilityPreferences,
  writeComposerReasoningIntent,
  writeComposerWebPreference,
} from '../composer-web-preference';
import { migrateDraftScopedModelControls } from '../draft-scope-migration';

const provider = { id: 'a0000000-0000-0000-0000-000000000001', kind: 'openAI', name: 'OpenAI', models: [] } as unknown as Provider;
const model = { id: 'gpt-5', name: 'GPT-5' } as unknown as AIModel;
const DRAFT = 'draft-session-1';
const CONVERSATION = 'b0000000-0000-0000-0000-000000000009';
const draftScope = { provider, model, conversationId: undefined, draftSessionId: DRAFT };

/** First send: the one migration at the new-conversation creation point in operations-send, after which ChatView restores the switches by conversation id. */
function firstSendThenRestore() {
  migrateDraftScopedModelControls({ provider, model, conversation: undefined, draftSessionId: DRAFT, conversationId: CONVERSATION });
  return readComposerCapabilityPreferences({ provider, model, conversationId: CONVERSATION, draftSessionId: DRAFT });
}

describe('draft state web search + reasoning: both survive the first send', () => {
  beforeEach(() => localStorage.clear());

  it('reasoning first, then web search: after the first send reasoning is still the tier the user picked', () => {
    expect(writeComposerReasoningIntent(draftScope, 'deep')).toBe(true);
    expect(writeComposerWebPreference(draftScope, 'automatic')).toBe(true);
    // Before sending, what the panel reads is both on
    expect(readComposerCapabilityPreferences(draftScope)).toEqual({ web: 'automatic', reasoningIntent: 'deep' });

    expect(firstSendThenRestore()).toEqual({ web: 'automatic', reasoningIntent: 'deep' });
  });

  it('web search first, then reasoning: after the first send web search is still on', () => {
    expect(writeComposerWebPreference(draftScope, 'automatic')).toBe(true);
    expect(writeComposerReasoningIntent(draftScope, 'deep')).toBe(true);
    expect(readComposerCapabilityPreferences(draftScope)).toEqual({ web: 'automatic', reasoningIntent: 'deep' });

    expect(firstSendThenRestore()).toEqual({ web: 'automatic', reasoningIntent: 'deep' });
  });

  it('explicitly turning reasoning off in the draft state only changes the reasoning entry', () => {
    writeComposerWebPreference(draftScope, 'automatic');
    writeComposerReasoningIntent(draftScope, 'off');
    expect(firstSendThenRestore()).toEqual({ web: 'automatic', reasoningIntent: 'off' });
  });

  it('changing one entry in an existing conversation likewise preserves the other', () => {
    const scope = { ...draftScope, conversationId: CONVERSATION };
    writeComposerReasoningIntent(scope, 'deep');
    writeComposerWebPreference(scope, 'automatic');
    expect(readComposerCapabilityPreferences(scope)).toEqual({ web: 'automatic', reasoningIntent: 'deep' });
    writeComposerReasoningIntent(scope, undefined);
    expect(readComposerCapabilityPreferences(scope)).toEqual({ web: 'automatic' });
  });
});
