// @vitest-environment jsdom

import { renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Conversation } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  partitionUID: 'user-A',
  syncAdapterActive: false,
  syncAdapterSubscribers: [] as Array<() => void>,
  warmConversationInStore: vi.fn<(conversationId: string) => Promise<Conversation | undefined>>(
    async () => undefined,
  ),
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: { hydrationPhase: string }) => unknown) =>
    selector({ hydrationPhase: 'ready' }),
}));

vi.mock('../../../../lib/infra/storage/partition', () => ({
  getActiveUIDSync: () => mocks.partitionUID,
}));

vi.mock('../../../../lib/core/chat/conversation-bootstrap', () => ({
  warmConversationInStore: (conversationId: string) =>
    mocks.warmConversationInStore(conversationId),
}));

vi.mock('../../../../lib/core/sync-lazy', () => ({
  loadSyncCore: async () => ({
    getSyncAdapter: () => (mocks.syncAdapterActive ? {} : null),
    subscribeSyncAdapter: (subscriber: () => void) => {
      mocks.syncAdapterSubscribers.push(subscriber);
      return () => {
        mocks.syncAdapterSubscribers = mocks.syncAdapterSubscribers.filter((item) => item !== subscriber);
      };
    },
  }),
}));

import { useConversationHydration } from '../useConversationHydration';

function conversationWith(messageCount: number): Conversation {
  return {
    id: 'c1',
    title: 'Conversation',
    messages: Array.from({ length: messageCount }, (_, index) => ({
      id: `m${index}`,
      role: 'user' as const,
      text: 'hello',
      state: 'delivered' as const,
      createdAt: new Date(1700000000000 + index).toISOString(),
    })),
  } as unknown as Conversation;
}

describe('useConversationHydration', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.partitionUID = 'user-A';
    mocks.syncAdapterActive = false;
    mocks.syncAdapterSubscribers = [];
  });

  it('warms the conversation out of local storage when one is requested', async () => {
    mocks.warmConversationInStore.mockResolvedValue(conversationWith(2));

    renderHook(() => useConversationHydration('c1', conversationWith(2)));

    await waitFor(() => {
      expect(mocks.warmConversationInStore).toHaveBeenCalledWith('c1');
    });
  });

  it('does not touch storage when no conversation is requested', async () => {
    renderHook(() => useConversationHydration(null, undefined));

    await Promise.resolve();
    expect(mocks.warmConversationInStore).not.toHaveBeenCalled();
  });

  it('reports a conversation whose messages are not on this device rather than holding the skeleton', async () => {
    // The warm returns metadata with no messages: nothing restored the bodies, so the load has to
    // settle instead of leaving the user on a skeleton until the watchdog fires.
    mocks.warmConversationInStore.mockResolvedValue(conversationWith(0));

    const { result } = renderHook(() =>
      useConversationHydration('c1', conversationWith(0)),
    );

    await waitFor(() => {
      expect(result.current.shouldShowConversationBootstrap).toBe(false);
    });
    expect(result.current.isComposerBlocked).toBe(false);
  });

  it('surfaces a failed local read as a stalled load with the composer blocked', async () => {
    mocks.warmConversationInStore.mockRejectedValue(new Error('indexeddb unavailable'));

    const { result } = renderHook(() =>
      useConversationHydration('c1', conversationWith(0)),
    );

    await waitFor(() => {
      expect(result.current.isComposerBlocked).toBe(true);
    });
  });

  it('subscribes to the sync adapter lifecycle so a backend installed later re-runs the load', async () => {
    renderHook(() => useConversationHydration('c1', conversationWith(0)));

    await waitFor(() => {
      expect(mocks.syncAdapterSubscribers.length).toBe(1);
    });
  });

  it('re-reads local storage when retried', async () => {
    mocks.warmConversationInStore.mockResolvedValue(conversationWith(0));

    const { result } = renderHook(() =>
      useConversationHydration('c1', conversationWith(0)),
    );
    await waitFor(() => expect(mocks.warmConversationInStore).toHaveBeenCalledTimes(1));

    result.current.retryHydration();

    await waitFor(() => expect(mocks.warmConversationInStore).toHaveBeenCalledTimes(2));
  });
});
