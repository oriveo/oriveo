import { describe, expect, it } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import {
  resolveChatLoadState,
  isChatLoadSkeleton,
  isChatComposerBlocked,
  CHAT_LOAD_STALL_TIMEOUT_MS,
  type ChatLoadStateInput,
} from '../chat-load-state';

const CONV_ID = 'E89683FC-24C2-4FEC-9CA6-BBBFFB8F8652';

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: CONV_ID,
    title: 'Existing conversation',
    hasCustomTitle: false,
    providerID: '22222222-2222-4222-8222-222222222222',
    providerKind: 'anthropic',
    modelID: 'claude-opus-4-7',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    remoteMessageCount: 0,
    messages: [],
    draftText: '',
    updatedAt: '2026-06-04T00:00:00.000Z',
    createdAt: '2026-06-04T00:00:00.000Z',
    ...overrides,
  } as Conversation;
}

function makeInput(overrides: Partial<ChatLoadStateInput> = {}): ChatLoadStateInput {
  return {
    requestedConversationId: CONV_ID,
    conversation: makeConversation(),
    hasLoadedSummary: true,
    localLoadFailed: false,
    backfillPhase: 'idle',
    elapsedSinceEnterMs: 0,
    ...overrides,
  };
}

describe('resolveChatLoadState priority chain', () => {
  it('a local read failure outranks everything else', () => {
    expect(
      resolveChatLoadState(
        makeInput({ localLoadFailed: true, backfillPhase: 'running', elapsedSinceEnterMs: 99_999 }),
      ),
    ).toBe('localFailure');
  });

  it('returns empty when there is no target conversation', () => {
    expect(resolveChatLoadState(makeInput({ requestedConversationId: null }))).toBe('empty');
  });

  it('returns deleted when metadata has loaded and the conversation is gone', () => {
    expect(
      resolveChatLoadState(makeInput({ conversation: undefined, hasLoadedSummary: true })),
    ).toBe('deleted');
  });

  it('does not report deleted before metadata has been read', () => {
    expect(
      resolveChatLoadState(makeInput({ conversation: undefined, hasLoadedSummary: false })),
    ).toBe('bootstrapping');
  });

  //   6 
  it('local content outweighs backfilling, timed out and backfill failed', () => {
    const withMessages = makeConversation({
      messages: [{ id: 'm1', role: 'user', text: 'hi', content: 'hi', state: 'delivered', createdAt: '2026-06-04T00:00:00.000Z' }],
    } as Partial<Conversation>);

    for (const overrides of [
      { backfillPhase: 'running' as const },
      { backfillPhase: 'failed' as const },
      { elapsedSinceEnterMs: CHAT_LOAD_STALL_TIMEOUT_MS },
    ]) {
      expect(resolveChatLoadState(makeInput({ conversation: withMessages, ...overrides }))).toBe(
        'content',
      );
    }
  });

  it('a draft conversation has no remote history to wait for, so it goes to empty', () => {
    expect(
      resolveChatLoadState(makeInput({ conversation: makeConversation({ isDraft: true }) })),
    ).toBe('empty');
    expect(
      resolveChatLoadState(makeInput({ conversation: makeConversation({ draftText: 'half written' }) })),
    ).toBe('empty');
  });

  it('a failed backfill goes to stalled', () => {
    expect(resolveChatLoadState(makeInput({ backfillPhase: 'failed' }))).toBe('stalled');
  });

  it('a backfill still running and not timed out goes to backfilling', () => {
    expect(resolveChatLoadState(makeInput({ backfillPhase: 'running' }))).toBe('backfilling');
  });

  it('a backfill that actually observed 0 remote messages is the only path that lets an existing conversation go to empty', () => {
    expect(resolveChatLoadState(makeInput({ backfillPhase: 'succeededEmpty' }))).toBe('empty');
    // In contrast: with no backfill run yet, "the remote copy is empty too" must not be guessed.
    expect(resolveChatLoadState(makeInput({ backfillPhase: 'idle' }))).toBe('bootstrapping');
  });

  it('an observed 0 that contradicts signs of history in the metadata goes to stalled rather than empty', () => {
    // Zero messages only means "no remote history" when the answer really came from the server.
    // A remote read that tries the backend once and falls back to the local cache on
    // failure, and backfill runs exactly on conversations whose cache is empty, so the fallback
    // snapshot is indistinguishable from a genuine zero. Going to empty would render a
    // conversation with complete remote history as an empty one that is ready to chat in.
    const withCount = makeConversation({ remoteMessageCount: 12 });
    expect(
      resolveChatLoadState(makeInput({ conversation: withCount, backfillPhase: 'succeededEmpty' })),
    ).toBe('stalled');

    const withPreview = makeConversation({ previewText: 'we were halfway through last time' });
    expect(
      resolveChatLoadState(makeInput({ conversation: withPreview, backfillPhase: 'succeededEmpty' })),
    ).toBe('stalled');
  });

  it('previewText and remoteMessageCount take no part in the decision', () => {
    const noisy = makeConversation({ previewText: 'the previous message', remoteMessageCount: 66 });
    expect(resolveChatLoadState(makeInput({ conversation: noisy }))).toBe('bootstrapping');
  });
});

//   8 
describe('12s timeout threshold', () => {
  it('the threshold is exactly 12 seconds', () => {
    expect(CHAT_LOAD_STALL_TIMEOUT_MS).toBe(12_000);
  });

  it('a request that was never sent goes stalled at the threshold, while a running backfill keeps showing', () => {
    expect(
      resolveChatLoadState(
        makeInput({ backfillPhase: 'running', elapsedSinceEnterMs: CHAT_LOAD_STALL_TIMEOUT_MS - 1 }),
      ),
    ).toBe('backfilling');
    expect(
      resolveChatLoadState(
        makeInput({ backfillPhase: 'running', elapsedSinceEnterMs: CHAT_LOAD_STALL_TIMEOUT_MS }),
      ),
    ).toBe('backfilling');
  });

  it('stalled is mutually exclusive with bootstrapping and backfilling', () => {
    const stalled = resolveChatLoadState(
      makeInput({ backfillPhase: 'idle', elapsedSinceEnterMs: CHAT_LOAD_STALL_TIMEOUT_MS }),
    );
    expect(stalled).toBe('stalled');
    expect(isChatLoadSkeleton(stalled)).toBe(false);
  });
});

//   5 stalled  
describe('composer gate', () => {
  it('blocks input for stalled, skeleton and local failure alike', () => {
    expect(isChatComposerBlocked('stalled')).toBe(true);
    expect(isChatComposerBlocked('bootstrapping')).toBe(true);
    expect(isChatComposerBlocked('backfilling')).toBe(true);
    expect(isChatComposerBlocked('localFailure')).toBe(true);
  });

  it('restores sending after a successful backfill', () => {
    expect(isChatComposerBlocked('content')).toBe(false);
    expect(isChatComposerBlocked('empty')).toBe(false);
    expect(isChatComposerBlocked('deleted')).toBe(false);
  });

  it('only backfilling and bootstrapping render as a skeleton', () => {
    expect(isChatLoadSkeleton('backfilling')).toBe(true);
    expect(isChatLoadSkeleton('bootstrapping')).toBe(true);
    expect(isChatLoadSkeleton('content')).toBe(false);
    expect(isChatLoadSkeleton('empty')).toBe(false);
  });
});

/**
 * Regression: a non-draft empty conversation was misjudged as stalled (12s of skeleton, then an
 * error card and a permanently disabled composer that retrying could not clear).
 *
 * The triggers are common: Pro users (whose listener is running) and guests never start a
 * backfill, so backfillPhase stays 'idle' and the chain runs all the way to the timeout. Such
 * conversations really exist: deleting the last message through operations-delete leaves
 * isDraft:false / messages:[] / remoteMessageCount:0, and conversations pulled down from the
 * cloud are all marked isDraft:false. The correct behavior is the writable welcome state after 3s.
 */
describe('empty conversation when backfill is skipped (stalled misjudgement regression)', () => {
  it('skipped with no sign of history goes to empty, not to a skeleton and not to stalled', () => {
    const state = resolveChatLoadState(makeInput({ backfillPhase: 'skipped' }));
    expect(state).toBe('empty');
    expect(isChatLoadSkeleton(state)).toBe(false);
    expect(isChatComposerBlocked(state)).toBe(false);
  });

  it('skipped with a non-empty previewText keeps waiting and never falls to an empty state', () => {
    expect(
      resolveChatLoadState(
        makeInput({
          backfillPhase: 'skipped',
          conversation: makeConversation({ previewText: 'we were halfway through last time' }),
        }),
      ),
    ).toBe('bootstrapping');
  });

  it('skipped with remoteMessageCount > 0 keeps waiting and still goes to stalled on timeout', () => {
    const input = makeInput({
      backfillPhase: 'skipped',
      conversation: makeConversation({ remoteMessageCount: 66 }),
    });
    expect(resolveChatLoadState(input)).toBe('bootstrapping');
    expect(
      resolveChatLoadState({ ...input, elapsedSinceEnterMs: CHAT_LOAD_STALL_TIMEOUT_MS }),
    ).toBe('stalled');
  });

  it("idle ", () => {
    expect(resolveChatLoadState(makeInput({ backfillPhase: 'idle' }))).toBe('bootstrapping');
  });
});
