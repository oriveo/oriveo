// @vitest-environment jsdom
//
// UI gate: MessageBubble must render the reasoning block during a long reasoning phase that
// consists only of heartbeats.
//
// `lib/core/chat/__tests__/reasoning-heartbeat.test.ts` already covers the parse layer through to
// the store; this covers the last hop. A test on `effectiveReasoningText.trim()` would not work,
// because that text is the empty string throughout a heartbeat-only window, so the reasoning
// block would not render at all and the screen would stay blank. The condition has to be an
// explicit "reasoning has started" boolean.

import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';

import { MessageBubble } from '../MessageBubble';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

// Only the streaming tuple is input for this case; the remaining state is a shell.
const storeState = {
  streamingTexts: {} as Record<string, string>,
  streamingReasoningTexts: {} as Record<string, string>,
  streamingReasoningActive: {} as Record<string, boolean>,
  streamingMessageIds: {} as Record<string, string>,
  streamingConversationIds: [] as string[],
  account: null,
  preferences: {},
  setPreferences: vi.fn(),
  providers: [],
  notes: [],
  conversations: [] as unknown[],
  folders: [],
  catalogSkills: [],
  userSkills: [],
};

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (s: unknown) => unknown) => selector(storeState),
  getVanillaStore: () => ({ getState: () => storeState, setState: vi.fn() }),
}));

vi.mock('../MarkdownRenderer', () => ({
  MarkdownRenderer: ({ content }: { content: string }) => <div>{content}</div>,
}));
vi.mock('../MessageActions', () => ({ MessageActions: () => null }));
vi.mock('../TypingIndicator', () => ({
  TypingIndicator: () => <div data-testid="typing-indicator" />,
}));
vi.mock('../MessageRecoveryCard', () => ({ MessageRecoveryCard: () => null }));
vi.mock('../MessageMeta', () => ({ MessageMeta: () => null }));
vi.mock('../CitationsBlock', () => ({ CitationsBlock: () => null }));
vi.mock('../ResearchProgressBlock', () => ({ ResearchProgressBlock: () => null }));
vi.mock('../CrosscheckSheet', () => ({ CrosscheckSheet: () => null }));
vi.mock('../SavedNoteRefs', () => ({ SavedNoteRefs: () => null }));
vi.mock('../QuoteContextChip', () => ({ QuoteContextChip: () => null }));
vi.mock('../MessageAttachments', () => ({
  UserImageAttachments: () => null,
  UserFileChips: () => null,
  GeneratedImages: () => null,
}));
vi.mock('../../ContextMenu', () => ({
  ContextMenu: () => null,
  useContextMenu: () => ({ menu: null, handleContextMenu: vi.fn(), closeMenu: vi.fn() }),
}));
vi.mock('../../ProviderIcon', () => ({ ProviderIcon: () => null }));
vi.mock('../../common/UserAvatar', () => ({ UserAvatar: () => null }));
vi.mock('../../Toast', () => ({ showToast: vi.fn() }));
vi.mock('../../notes/note-toast', () => ({ showSavedNoteToast: vi.fn() }));
vi.mock('../../../lib/core/library/feature-flag', () => ({
  isLibraryFeatureEnabled: () => false,
}));
vi.mock('../../../lib/core/providers/model-display-lookup', () => ({
  createModelDisplayLookup: () => ({ resolve: () => null }),
}));

const CONV_ID = 'conv-1';
const MSG_ID = 'assistant-1';

function generatingMessage(): ChatMessage {
  return {
    id: MSG_ID,
    role: 'assistant',
    text: '',
    state: 'generating',
    createdAt: '2026-08-07T00:00:00.000Z',
  } as unknown as ChatMessage;
}

function beginStreaming(reasoningActive: boolean) {
  storeState.streamingTexts = { [CONV_ID]: '' };
  storeState.streamingReasoningTexts = { [CONV_ID]: '' };
  storeState.streamingReasoningActive = { [CONV_ID]: reasoningActive };
  storeState.streamingMessageIds = { [CONV_ID]: MSG_ID };
  storeState.streamingConversationIds = [CONV_ID];
}

describe('MessageBubble feedback during a heartbeat-only reasoning window', () => {
  it('renders the Thinking block once reasoning has started, even before a single character arrives', () => {
    beginStreaming(true);

    render(
      <MessageBubble
        message={generatingMessage()}
        streamingText=""
        conversationId={CONV_ID}
      />,
    );

    expect(
      screen.queryByText('thinking'),
      'MessageBubble did not render the reasoning block during a heartbeat-only window, so the '
        + 'condition fell back to "reasoning text is non-empty". During a long reasoning phase the '
        + 'upstream only sends empty-string heartbeats, so the text is always "" and '
        + 'streamingReasoningActive is what must be used.',
    ).not.toBeNull();
  });

  it('renders no reasoning block when no reasoning event ever arrives, so a non-reasoning model gets no empty block', () => {
    beginStreaming(false);

    render(
      <MessageBubble
        message={generatingMessage()}
        streamingText=""
        conversationId={CONV_ID}
      />,
    );

    expect(screen.queryByText('thinking')).toBeNull();
    expect(screen.queryByTestId('typing-indicator')).not.toBeNull();
  });
});
