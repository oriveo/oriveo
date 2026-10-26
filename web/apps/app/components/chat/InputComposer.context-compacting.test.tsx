import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * While an AI summary is running for this conversation, the composer shows inProgress + cancel; cancelling ends the compaction through the production coordinator.
 */
import React from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations: (namespace?: string) => (key: string) => `${namespace ?? ''}.${key}`,
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: unknown) => unknown) => selector({
    preferences: { sendShortcut: 'enter' }, conversations: [], providers: [], activeConversationId: null,
  }),
  tryGetVanillaStore: () => null,
  getVanillaStore: () => null,
}));
vi.mock('../../lib/core/entitlement', () => {
  const getState = () => ({ entitlement: { storage: undefined }, isPro: false });
  const useEntitlementStore = (selector: (state: ReturnType<typeof getState>) => unknown) => selector(getState());
  useEntitlementStore.getState = getState;
  return {
    useEntitlementStore,
    selectIsPro: () => false,
    selectSingleFileBytesLimit: () => 25 * 1024 * 1024,
    selectStorageUploadsBlocked: () => false,
  };
});

import { InputComposer } from './InputComposer';
import {
  createCompactionCoordinator,
  isAICompacting,
  type CompactionContext,
} from '../../lib/core/chat/context-pipeline/compaction-coordinator';
import { resolveAttachmentCapabilities } from '../../lib/core/chat/attachment-policy';

/** Mirrors ChatView by passing attachment capabilities: this case has no connection. */
const NO_CONNECTION_CAPABILITIES = resolveAttachmentCapabilities(undefined, undefined, null);

const ctx = (): CompactionContext => ({
  messages: Array.from({ length: 6 }, (_, i) => ({
    id: `m${i + 1}`, role: i % 2 === 0 ? 'user' as const : 'assistant' as const, text: `turn ${i + 1}`, estTokens: 5000,
  })),
  B: 40000, U: 100000, prefixTokens: 500, rhoHi: 0.5, fixedTokens: 0, model: 'gpt-x',
});

afterEach(() => cleanup());

describe('context compacting status', () => {
  it('shows in-progress with cancel only for the compacting conversation', async () => {
    const coordinator = createCompactionCoordinator({
      context: () => ctx(),
      summarize: (_req, signal) => new Promise<string | null>((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(new Error('aborted')));
      }),
      remoteEnabled: () => true,
    });
    const { rerender } = render(
      <InputComposer attachmentCapabilities={NO_CONNECTION_CAPABILITIES} value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming generationParameterConversationId="conv-a" />,
    );
    expect(screen.queryByTestId('context-compacting-status')).toBeNull();

    const pending = coordinator.compact('conv-a', 'manual');
    const status = await screen.findByTestId('context-compacting-status');
    expect(status.textContent).toContain('pages.chat.contextCompaction.inProgress');

    rerender(<InputComposer attachmentCapabilities={NO_CONNECTION_CAPABILITIES} value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming generationParameterConversationId="conv-b" />);
    expect(screen.queryByTestId('context-compacting-status')).toBeNull();
    rerender(<InputComposer attachmentCapabilities={NO_CONNECTION_CAPABILITIES} value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming generationParameterConversationId="conv-a" />);

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'pages.chat.contextCompaction.cancel' }));
      expect(await pending).toEqual({ outcome: 'noop', failures: [], cancelled: true });
    });
    expect(isAICompacting('conv-a')).toBe(false);
    await waitFor(() => expect(screen.queryByTestId('context-compacting-status')).toBeNull());
  });
});
