// @vitest-environment jsdom
//
// Locks the last hop of "the message goes into a wait after body text and shows nothing".
// The parser-to-store stretch is covered by lib/core/chat/__tests__/stream-activity-pipeline.test.ts;
// this file uses the real TypingIndicator and StreamActivityLine and asserts what the user sees.

import { act, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';

import { MessageBubble } from '../MessageBubble';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

// Only the streaming dictionaries are inputs here; the rest of the state is an empty shell.
const storeState = {
  streamingTexts: {} as Record<string, string>,
  streamingReasoningTexts: {} as Record<string, string>,
  streamingReasoningActive: {} as Record<string, boolean>,
  streamingActivities: {} as Record<string, 'web_search' | 'mcp_tool' | null>,
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
const PREAMBLE = 'Let me search this repository.';

function message(state: ChatMessage['state'], text = ''): ChatMessage {
  return {
    id: MSG_ID,
    role: 'assistant',
    text,
    state,
    createdAt: '2026-10-01T00:00:00.000Z',
  } as unknown as ChatMessage;
}

function beginStreaming(activity: 'web_search' | 'mcp_tool' | null) {
  storeState.streamingTexts = { [CONV_ID]: '' };
  storeState.streamingReasoningTexts = { [CONV_ID]: '' };
  storeState.streamingReasoningActive = { [CONV_ID]: false };
  storeState.streamingActivities = { [CONV_ID]: activity };
  storeState.streamingMessageIds = { [CONV_ID]: MSG_ID };
  storeState.streamingConversationIds = [CONV_ID];
}

function bubble(streamingText: string | undefined, state: ChatMessage['state'] = 'generating') {
  return <MessageBubble message={message(state, state === 'generating' ? '' : PREAMBLE)} streamingText={streamingText} conversationId={CONV_ID} />;
}

// next-intl is mocked to echo the key, so 'activityWebSearch' and 'generating' in the assertions are message keys.
describe('MessageBubble waiting feedback (stream activity line)', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('body text plus an observed web search: the line shows under the body at once, without waiting for a pause', () => {
    beginStreaming('web_search');
    render(bubble(PREAMBLE));

    const line = screen.getByRole('status');
    expect(line.textContent).toBe('activityWebSearch');
    expect(screen.queryByLabelText('generating')).toBeNull();
  });

  it('no body text plus an observed web search: the typing indicator swaps its label and no line is stacked', () => {
    beginStreaming('web_search');
    render(bubble(''));

    expect(screen.queryByLabelText('activityWebSearch')).not.toBeNull();
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('body text and no upstream signal: the neutral line shows after a 1.5 second pause and goes away once text resumes', () => {
    beginStreaming(null);
    const view = render(bubble(PREAMBLE));
    expect(
      screen.queryByRole('status'),
      'There should be no line while body text is still arriving',
    ).toBeNull();

    act(() => {
      vi.advanceTimersByTime(1499);
    });
    expect(screen.queryByRole('status')).toBeNull();

    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(
      screen.queryByRole('status')?.textContent,
      'The body text has been still for more than 1.5 seconds and there is no waiting hint: the text ends and the message just goes silent.',
    ).toBe('generating');

    view.rerender(bubble(`${PREAMBLE} The search results show`));
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('a pause with no body text shows no line, because the typing indicator is already moving', () => {
    beginStreaming(null);
    render(bubble(''));
    act(() => {
      vi.advanceTimersByTime(5000);
    });

    expect(screen.queryByLabelText('generating')).not.toBeNull();
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('leaves no line behind once generation has finished', () => {
    beginStreaming('web_search');
    render(bubble(undefined, 'delivered'));
    act(() => {
      vi.advanceTimersByTime(5000);
    });

    expect(screen.queryByRole('status')).toBeNull();
  });
});

// MCP tools: the signal comes from the local tool loop, and the display context is read from the
// running step in the message's toolSteps.
describe('MessageBubble waiting feedback: mcp_tool activity', () => {
  function toolMessage(status: 'running' | 'done'): ChatMessage {
    return {
      ...message('generating'),
      toolSteps: [{
        id: '1:c1', scope: 'mcp', serverId: 's1', serverName: 'Notion', toolName: 'find_page', title: 'Find page',
        argsSummary: 'Weekly report', status, step: 1,
      }],
    } as unknown as ChatMessage;
  }

  it('with a step running, the waiting text becomes the MCP tool line (carried by the dot indicator when it is shown)', () => {
    beginStreaming('mcp_tool');
    render(<MessageBubble message={toolMessage('running')} streamingText="" conversationId={CONV_ID} />);
    expect(screen.queryByLabelText('activityMcpTool')).not.toBeNull();
    // The steps block is shown too: the running step is where the server name and tool title in the text come from
    expect(document.querySelector('[data-mcp-steps]')?.textContent).toContain('Notion · Find page');
  });

  it('with the activity set but no running step in the message, falls back to the neutral text instead of half a sentence', () => {
    beginStreaming('mcp_tool');
    render(<MessageBubble message={toolMessage('done')} streamingText="" conversationId={CONV_ID} />);
    expect(screen.queryByLabelText('activityMcpTool')).toBeNull();
    expect(screen.queryByLabelText('generating')).not.toBeNull();
  });
});
