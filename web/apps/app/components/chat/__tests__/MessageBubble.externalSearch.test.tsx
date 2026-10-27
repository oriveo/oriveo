// @vitest-environment jsdom
//
// External web search presentation in the bubble: activity line + capsule, sources card, error card, rejected-switch notice,
// and the "regenerate and search again" menu item. Message state comes from the production search-turn chain + externalSearchMessagePatch (same as the sample-screen host).

import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';

import { MessageBubble } from '../MessageBubble';
import { SearchServicesOverride } from '../SearchErrorCard';
import { applyExternalSearchActivity, clearExternalSearchActivity } from '../../../lib/core/chat/external-search-activity';
import { webSearchShotPlan } from '../../../app/dev/webSearch-shots/webSearch-shots-data';
import { webSearchChatMessages } from '../../../app/dev/webSearch-shots/WebSearchChatHost';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

// Only the streaming dictionaries are inputs for these cases; the rest of the state is an empty shell.
const storeState = {
  streamingTexts: {} as Record<string, string>,
  streamingReasoningTexts: {} as Record<string, string>,
  streamingReasoningActive: {} as Record<string, boolean>,
  streamingActivities: {} as Record<string, 'web_search' | 'mcp_tool' | 'external_search' | null>,
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
vi.mock('../ResearchProgressBlock', () => ({ ResearchProgressBlock: () => null }));
vi.mock('../CrosscheckSheet', () => ({ CrosscheckSheet: () => null }));
vi.mock('../SavedNoteRefs', () => ({ SavedNoteRefs: () => null }));
vi.mock('../QuoteContextChip', () => ({ QuoteContextChip: () => null }));
vi.mock('../MessageAttachments', () => ({
  UserImageAttachments: () => null,
  UserFileChips: () => null,
  GeneratedImages: () => null,
}));
const contextMenu = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock('../../ContextMenu', () => ({
  ContextMenu: () => null,
  useContextMenu: () => ({ menu: null, handleContextMenu: contextMenu.open, closeMenu: vi.fn() }),
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


function loadFixture(...parts: string[]) {
  for (let dir = resolve(import.meta.dirname); ; dir = dirname(dir)) {
    try {
      return JSON.parse(readFileSync(join(dir, ...parts), 'utf8'));
    } catch (error) {
      if (dirname(dir) === dir) throw error;
    }
  }
}
const manifest = loadFixture('shared', 'test-fixtures', 'shots', 'webSearch.v1.json');
const searchTurn = loadFixture('shared', 'search-contracts', 'search-turn.v1.json');

function shot(page: string) {
  return webSearchShotPlan(page as never, manifest, searchTurn).chat!;
}

function renderReply(page: string, props: { isLastMessage?: boolean; onRegenerateWithSearch?: () => void; message?: Partial<ChatMessage> } = {}) {
  const chat = shot(page);
  const [, assistant] = webSearchChatMessages(chat);
  return render(
    <SearchServicesOverride.Provider value={chat.local}>
      <MessageBubble
        message={{ ...assistant, ...props.message }}
        isLastMessage={props.isLastMessage ?? true}
        onRegenerateWithSearch={props.onRegenerateWithSearch ?? vi.fn()}
      />
    </SearchServicesOverride.Provider>,
  );
}

afterEach(() => {
  cleanup();
  clearExternalSearchActivity('conv-1');
  storeState.streamingActivities = {};
  storeState.streamingMessageIds = {};
  storeState.streamingTexts = {};
  contextMenu.open.mockReset();
});

describe('MessageBubble external web search presentation', () => {
  it('searching: "Searching with {name}…" + a capsule for the query being searched replaces the dot wait', () => {
    const chat = shot('webSearchChatSearching');
    storeState.streamingTexts = { 'conv-1': '' };
    storeState.streamingMessageIds = { 'conv-1': 'assistant-1' };
    storeState.streamingActivities = { 'conv-1': 'external_search' };
    applyExternalSearchActivity('conv-1', chat.activity);
    render(<MessageBubble message={{ id: 'assistant-1', role: 'assistant', text: '', state: 'generating' } as ChatMessage} streamingText="" conversationId="conv-1" />);
    expect(screen.getByRole('status').textContent).toBe('chat.searching');
    expect(screen.getByText(chat.activity!.query)).toBeTruthy();
    expect(screen.queryByLabelText('generating')).toBeNull();
  });

  it('after all deliver events and before the first text: "Answering from search results…"; collapses once reasoning content streams in', () => {
    const chat = shot('webSearchChatSearching');
    storeState.streamingTexts = { 'conv-1': '' };
    storeState.streamingMessageIds = { 'conv-1': 'assistant-1' };
    storeState.streamingActivities = { 'conv-1': null };
    applyExternalSearchActivity('conv-1', chat.activity);
    applyExternalSearchActivity('conv-1', null);
    const generating = { id: 'assistant-1', role: 'assistant', text: '', state: 'generating' } as ChatMessage;
    const { rerender } = render(<MessageBubble message={generating} streamingText="" conversationId="conv-1" />);
    expect(screen.getByRole('status').textContent).toBe('chat.answeringFromResults');
    storeState.streamingReasoningTexts = { 'conv-1': 'thinking…' };
    rerender(<MessageBubble message={{ ...generating }} streamingText="" conversationId="conv-1" />);
    expect(screen.queryByText('chat.answeringFromResults')).toBeNull();
    storeState.streamingReasoningTexts = {};
  });

  it('sources card: three-part title, collapsed by default, expands to numbered rows (domain always shown); menu gains "regenerate and search again"', () => {
    const onRegenerateWithSearch = vi.fn();
    renderReply('webSearchChatAnswer', { onRegenerateWithSearch });
    const card = screen.getByTestId('search-sources-card');
    expect(card.textContent).toContain('chat.searchedTimes');
    expect(card.textContent).toContain('DeepSeek');
    expect(card.textContent).toContain('chat.sourcesCount');
    expect(card.querySelectorAll('a')).toHaveLength(0);
    fireEvent.click(screen.getByRole('button', { expanded: false }));
    expect(card.querySelectorAll('a').length).toBe(3);

    fireEvent.contextMenu(screen.getByRole('article'));
    const items = contextMenu.open.mock.calls[0]?.[1] as Array<{ label: string; onAction: () => void }>;
    const item = items.find((entry) => entry.label === 'chat.regenerateWithSearch');
    expect(item).toBeTruthy();
    item!.onAction();
    expect(onRegenerateWithSearch).toHaveBeenCalledTimes(1);
  });

  it('error card: the last message gets a "Top up" external link + "Answer with Tavily"; older messages keep only link-type actions', () => {
    renderReply('webSearchChatError');
    const card = screen.getByTestId('search-error-card');
    expect(card.textContent).toContain('chatError.insufficientBalance');
    expect(card.textContent).toContain('chat.errorDetail');
    const topUp = screen.getByRole('link', { name: /action.topUp/ }) as HTMLAnchorElement;
    expect(topUp.target).toBe('_blank');
    expect(topUp.href.startsWith('https://')).toBe(true);
    expect(screen.getByRole('button', { name: 'action.answerWith' })).toBeTruthy();
    expect(screen.queryByTestId('search-sources-card')).toBeNull();
    cleanup();

    renderReply('webSearchChatError', { isLastMessage: false });
    expect(screen.getByRole('link', { name: /action.topUp/ })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'action.answerWith' })).toBeNull();
  });

  it('sources card title row wraps and is not truncated (source count stays visible at narrow widths)', () => {
    const css = readFileSync(join(import.meta.dirname, '..', 'SearchSourcesCard.module.css'), 'utf8');
    const rule = css.match(/\.titleText\s*\{([^}]*)\}/)?.[1] ?? '';
    expect(rule).not.toMatch(/text-overflow\s*:\s*ellipsis/);
    expect(rule).not.toMatch(/white-space\s*:\s*nowrap/);
  });

  it('reuse: the sources card first segment says "Reusing the previous search"; rejected-switch: reply notice row', () => {
    renderReply('webSearchChatReused', { message: { searchNotice: 'tools_rejected' } });
    expect(screen.getByTestId('search-sources-card').textContent).toContain('chat.reusedSearch');
    expect(screen.getByText('chat.toolsRejectedNotice')).toBeTruthy();
  });
});
