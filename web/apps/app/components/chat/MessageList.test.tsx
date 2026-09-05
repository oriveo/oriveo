import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fireEvent, render } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MessageList } from './MessageList';

const {
  mockCreateNote,
  mockGetVanillaStore,
  mockReplaceNote,
  mockRouterPush,
  mockShowSavedNoteToast,
  mockShowToast,
  mockCopyToClipboard,
  mockUseTextSelectionAnchor,
  mockAppState,
} = vi.hoisted(() => ({
  mockCreateNote: vi.fn(),
  mockGetVanillaStore: vi.fn(),
  mockReplaceNote: vi.fn(),
  mockRouterPush: vi.fn(),
  mockShowSavedNoteToast: vi.fn(),
  mockShowToast: vi.fn(),
  mockCopyToClipboard: vi.fn(),
  mockUseTextSelectionAnchor: vi.fn(),
  // MessageList subscribes to the store itself and passes the conversation object down to every
  // bubble, so the mock points the selector at this mutable snapshot: change a field in a test and rerender to see the new value.
  mockAppState: {
    conversations: [] as Array<{ id: string }>,
    streamingTexts: {} as Record<string, string>,
  },
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mockRouterPush }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => {
    const messages: Record<string, string> = {
      addSelectionToNote: 'Save as Note',
      copied: 'Copied',
      copy: 'Copy',
      copyFailed: 'Copy failed',
      newMessages: 'New messages',
      replaceCurrentNote: 'Update note with selection',
      saveAsNote: 'Save as Note',
      selectionAsk: 'Ask',
      savedNoteUntitled: 'Untitled note',
      viewNote: 'View',
    };
    return messages[key] ?? key;
  },
}));

vi.mock('../../lib/hooks/useTextSelectionAnchor', () => ({
  useTextSelectionAnchor: () => mockUseTextSelectionAnchor(),
}));

vi.mock('../../providers/StoreProvider', () => ({
  getVanillaStore: () => mockGetVanillaStore(),
  useAppStore: (selector: (state: typeof mockAppState) => unknown) => selector(mockAppState),
}));

vi.mock('../../lib/core/note-ops', () => ({
  createNote: (...args: unknown[]) => mockCreateNote(...args),
  replaceNote: (...args: unknown[]) => mockReplaceNote(...args),
}));

vi.mock('../notes/note-toast', () => ({
  showSavedNoteToast: (...args: unknown[]) => mockShowSavedNoteToast(...args),
}));

vi.mock('../Toast', () => ({
  showToast: (...args: unknown[]) => mockShowToast(...args),
}));

vi.mock('../../lib/utils/clipboard', () => ({
  copyToClipboard: (...args: unknown[]) => mockCopyToClipboard(...args),
}));

vi.mock('./MessageBubble', () => ({
  MessageBubble: ({
    message,
    streamingText,
    conversation,
    savedNoteRefs = [],
  }: {
    message: { content: string };
    streamingText?: string;
    conversation?: { id: string };
    savedNoteRefs?: Array<{ id: string; title: string }>;
  }) => (
    <div>
      {message.content}
      {streamingText}
      {conversation ? (
        <span data-testid="bubble-conversation">{conversation.id}</span>
      ) : null}
      {savedNoteRefs.map((note) => (
        <span key={note.id} data-testid="saved-note-ref">{note.title}</span>
      ))}
    </div>
  ),
}));

const userMsg = {
  id: 'u1',
  role: 'user',
  content: 'question',
  text: 'question',
  state: 'delivered',
  providerID: 'provider-1',
};
const genAssistant = {
  id: 'a1',
  role: 'assistant',
  content: '',
  text: '',
  state: 'generating',
  providerID: 'provider-1',
};
const deliveredAssistant = {
  ...genAssistant,
  state: 'delivered',
  content: 'answer',
  text: 'answer',
};

describe('MessageList (pin-to-top behavior)', () => {
  const scrollTo = vi.fn();
  const scrollIntoView = vi.fn();

  beforeEach(() => {
    scrollTo.mockClear();
    scrollIntoView.mockClear();
    mockCreateNote.mockReset();
    mockGetVanillaStore.mockReset();
    mockReplaceNote.mockReset();
    mockRouterPush.mockReset();
    mockShowSavedNoteToast.mockReset();
    mockShowToast.mockReset();
    mockCopyToClipboard.mockReset();
    mockUseTextSelectionAnchor.mockReset();
    mockUseTextSelectionAnchor.mockReturnValue(null);
    mockAppState.conversations = [];
    mockAppState.streamingTexts = {};
    mockGetVanillaStore.mockReturnValue({ kind: 'vanilla-store' });
    mockCopyToClipboard.mockResolvedValue(true);
    Element.prototype.scrollTo = scrollTo as never;
    Element.prototype.scrollIntoView = scrollIntoView;
  });

  it('a new generating assistant at the tail pins the question bubble to the top by calling scrollTo', () => {
    const { rerender } = render(
      <MessageList messages={[userMsg as never]} providers={[]} isStreaming={false} />,
    );
    // Only a user message and no stream, so nothing is pinned
    scrollTo.mockClear();

    rerender(
      <MessageList
        messages={[userMsg as never, genAssistant as never]}
        providers={[]}
        isStreaming
      />,
    );

    expect(scrollTo).toHaveBeenCalled();
    // Smooth scroll, or instant under reduced-motion
    expect(scrollTo.mock.calls[0][0]).toMatchObject({
      behavior: expect.stringMatching(/smooth|auto/),
    });
  });

  it('the first message of a new conversation also pins to the top when the tail is already generating at mount', () => {
    // First message in an empty conversation: the list branch mounts with a generating tail already present and must not be skipped as already pinned
    render(
      <MessageList
        messages={[userMsg as never, genAssistant as never]}
        providers={[]}
        isStreaming
        conversationId="conv-new"
      />,
    );
    expect(scrollTo).toHaveBeenCalled();
  });

  it('hydrating an existing conversation (delivered tail, no stream) does not trigger the pinning scrollTo', () => {
    render(
      <MessageList
        messages={[userMsg as never, deliveredAssistant as never]}
        providers={[]}
        isStreaming={false}
      />,
    );
    expect(scrollTo).not.toHaveBeenCalled();
  });

  // Regression: the conversation object is subscribed once by MessageList and passed down to each
  // bubble. Moving it back to a per-bubble `useAppStore(s => s.conversations.find(...))` would make
  // zustand run an O(conversations) scan per bubble on every store write, turning the per-frame streaming cost into O(messages x conversations).
  it('the conversation object is subscribed once and passed down to every bubble', () => {
    mockAppState.conversations = [{ id: 'conv-1' }, { id: 'conv-2' }];
    const { getAllByTestId } = render(
      <MessageList
        messages={[userMsg as never, deliveredAssistant as never]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-2"
      />,
    );
    const seen = getAllByTestId('bubble-conversation');
    expect(seen).toHaveLength(2);
    expect(seen.every((node) => node.textContent === 'conv-2')).toBe(true);
  });

  it('conversation ids differing only in case do not match', () => {
    mockAppState.conversations = [{ id: 'CONV-2' }];
    const { queryAllByTestId } = render(
      <MessageList
        messages={[userMsg as never]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-2"
      />,
    );
    expect(queryAllByTestId('bubble-conversation')).toHaveLength(0);
  });

  // streamingText is read from the store by MessageList itself rather than passed down, so this
  // drives the store snapshot instead of a prop.
  it('streaming text always renders live and is never frozen', () => {
    mockAppState.streamingTexts = { 'conv-1': 'hello' };
    const { container, rerender } = render(
      <MessageList
        messages={[userMsg as never, genAssistant as never]}
        providers={[]}
        isStreaming
        conversationId="conv-1"
      />,
    );
    expect(container.textContent).toContain('hello');

    mockAppState.streamingTexts = { 'conv-1': 'hello world' };
    rerender(
      <MessageList
        messages={[userMsg as never, genAssistant as never]}
        providers={[]}
        isStreaming
        conversationId="conv-1"
      />,
    );
    expect(container.textContent).toContain('hello world');
  });

  // Multi-conversation dictionary: switching to B while it streams and back to A must not show B's partial in A.
  it('only the current conversation streaming partial is used', () => {
    mockAppState.streamingTexts = { 'conv-other': 'other partial' };
    const { container } = render(
      <MessageList
        messages={[userMsg as never, genAssistant as never]}
        providers={[]}
        isStreaming
        conversationId="conv-1"
      />,
    );
    expect(container.textContent).not.toContain('other partial');
  });

  it('more than 80px from the bottom shows the back-to-bottom affordance, and clicking it scrolls to the latest message', () => {
    const { container } = render(
      <MessageList
        messages={[userMsg as never, deliveredAssistant as never]}
        providers={[]}
        isStreaming={false}
      />,
    );
    const area = container.querySelector('[role="log"]') as HTMLDivElement;
    // 500px from the bottom, above the 80px threshold
    setScrollMetrics(area, { scrollTop: 0, scrollHeight: 1000, clientHeight: 500 });
    fireEvent.scroll(area);

    // Round icon in the bottom right corner: no visible text, so the semantics come from aria-label
    const btn = container.querySelector('button') as HTMLButtonElement;
    expect(btn).toBeTruthy();
    expect(btn.getAttribute('aria-label')).toContain('New messages');

    scrollTo.mockClear();
    fireEvent.click(btn);
    expect(scrollTo).toHaveBeenCalledWith({
      top: 1000,
      behavior: expect.stringMatching(/smooth|auto/),
    });
  });

  it('less than 80px from the bottom hides the affordance', () => {
    const { container } = render(
      <MessageList
        messages={[userMsg as never, deliveredAssistant as never]}
        providers={[]}
        isStreaming={false}
      />,
    );
    const area = container.querySelector('[role="log"]') as HTMLDivElement;
    setScrollMetrics(area, { scrollTop: 470, scrollHeight: 1000, clientHeight: 500 }); // 30px from the bottom
    fireEvent.scroll(area);
    expect(container.querySelector('button')).toBeNull();
  });

  it('a search scrolls to the first matching message rather than to the bottom', () => {
    const target = { ...deliveredAssistant, id: 'm2', text: 'needle is here', content: 'needle is here' };

    render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'first', content: 'first' } as never,
          target as never,
          { ...deliveredAssistant, id: 'm3', text: 'last', content: 'last' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        searchQuery="needle"
      />,
    );

    expect(scrollIntoView).toHaveBeenCalledWith({ block: 'start', behavior: 'auto' });
  });

  it('passes single and multiple saved-note refs to the matching message bubbles', () => {
    const { container } = render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'first', content: 'first' } as never,
          { ...deliveredAssistant, id: 'm2', text: 'answer', content: 'answer' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        savedNoteRefsByMessageId={{
          m1: [{ id: 'note-user', title: 'User note' }],
          m2: [
            { id: 'note-a', title: 'Answer note A' },
            { id: 'note-b', title: 'Answer note B' },
          ],
        }}
      />,
    );

    const refs = Array.from(container.querySelectorAll('[data-testid="saved-note-ref"]'))
      .map((node) => node.textContent);
    expect(refs).toEqual(['User note', 'Answer note A', 'Answer note B']);
  });

  it('puts Copy before Save as Note in the selected-text toolbar', () => {
    mockUseTextSelectionAnchor.mockReturnValue({
      messageId: 'm2',
      text: 'answer',
      x: 120,
      y: 48,
    });

    const { getAllByRole } = render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'question', content: 'question' } as never,
          { ...deliveredAssistant, id: 'm2', text: 'answer', content: 'answer' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-1"
      />,
    );

    expect(getAllByRole('button').map((button) => button.textContent)).toEqual([
      'Copy',
      'Save as Note',
    ]);
  });

  it('adds Ask alongside existing actions and emits the exact QuoteContext snapshot', () => {
    const onAskSelection = vi.fn();
    mockUseTextSelectionAnchor.mockReturnValue({
      messageId: 'm2',
      text: 'selected answer',
      contentKind: 'prose',
      leadingText: 'before ',
      trailingText: ' after',
      contextReliable: true,
      x: 120,
      y: 48,
    });

    const { getByRole } = render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'question', content: 'question' } as never,
          { ...deliveredAssistant, id: 'm2', text: 'answer', content: 'answer' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-1"
        onAskSelection={onAskSelection}
      />,
    );

    fireEvent.click(getByRole('button', { name: 'Ask' }));
    expect(onAskSelection).toHaveBeenCalledWith({
      schemaVersion: 1,
      sourceMessageId: 'm2',
      sourceRole: 'assistant',
      contentKind: 'prose',
      leadingText: 'before ',
      selectedText: 'selected answer',
      trailingText: ' after',
      contextTruncated: false,
    });
  });

  it('copies selected text from the selected-text toolbar without saving a note', () => {
    mockUseTextSelectionAnchor.mockReturnValue({
      messageId: 'm2',
      text: 'selected answer',
      x: 120,
      y: 48,
    });

    const { getByRole } = render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'question', content: 'question' } as never,
          { ...deliveredAssistant, id: 'm2', text: 'answer', content: 'answer' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-1"
      />,
    );

    fireEvent.click(getByRole('button', { name: 'Copy' }));

    expect(mockCopyToClipboard).toHaveBeenCalledWith(
      'selected answer',
      { successToast: 'Copied', failureToast: 'Copy failed' },
    );
    expect(mockCreateNote).not.toHaveBeenCalled();
  });

  it('replaces a saved note from the selected assistant message reference without return-note context', () => {
    mockUseTextSelectionAnchor.mockReturnValue({
      messageId: 'm2',
      text: 'answer',
      x: 120,
      y: 48,
    });
    mockReplaceNote.mockReturnValue({
      id: 'note-a',
      title: 'Answer note',
      titleSource: 'manual',
      body: 'answer',
      tags: [],
      captureKind: 'selection',
      createdAt: '2026-06-27T00:00:00.000Z',
      updatedAt: '2026-06-27T00:00:00.000Z',
    });

    const { getByRole, getAllByRole } = render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'question', content: 'question' } as never,
          { ...deliveredAssistant, id: 'm2', text: 'answer', content: 'answer', modelID: 'gpt-4.1' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-1"
        savedNoteRefsByMessageId={{
          m2: [{ id: 'note-a', title: 'Answer note' }],
        }}
      />,
    );

    expect(getAllByRole('button').map((button) => button.textContent)).toEqual([
      'Copy',
      'Save as Note',
      'Update note with selection',
    ]);
    fireEvent.click(getByRole('button', { name: 'Update note with selection' }));

    expect(mockReplaceNote).toHaveBeenCalledTimes(1);
    expect(mockReplaceNote.mock.calls[0][1]).toBe('note-a');
    expect(mockReplaceNote.mock.calls[0][2]).toMatchObject({
      body: 'answer',
      sourceConversationId: 'conv-1',
      sourceMessageId: 'm2',
    });
  });

  it('replaces the current note from selected assistant text when returning from a note', () => {
    mockUseTextSelectionAnchor.mockReturnValue({
      messageId: 'm2',
      text: 'answer',
      x: 120,
      y: 48,
    });
    mockReplaceNote.mockReturnValue({
      id: 'note-1',
      title: 'Existing note',
      titleSource: 'manual',
      body: 'answer',
      tags: [],
      captureKind: 'selection',
      createdAt: '2026-06-27T00:00:00.000Z',
      updatedAt: '2026-06-27T00:00:00.000Z',
    });

    const { getByRole } = render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'question', content: 'question' } as never,
          { ...deliveredAssistant, id: 'm2', text: 'answer', content: 'answer', modelID: 'gpt-4.1' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-1"
        replaceCurrentNoteId="note-1"
      />,
    );

    expect(getByRole('button', { name: 'Save as Note' })).toBeTruthy();
    fireEvent.click(getByRole('button', { name: 'Update note with selection' }));

    expect(mockReplaceNote).toHaveBeenCalledTimes(1);
    expect(mockReplaceNote.mock.calls[0][0]).toEqual({ kind: 'vanilla-store' });
    expect(mockReplaceNote.mock.calls[0][1]).toBe('note-1');
    expect(mockReplaceNote.mock.calls[0][2]).toMatchObject({
      body: 'answer',
      bodySnapshot: 'answer',
      captureKind: 'selection',
      sourceConversationId: 'conv-1',
      sourceMessageId: 'm2',
      sourceModelID: 'gpt-4.1',
      sourcePrompt: 'question',
    });
  });

  it('does not show replace-current-note for selected user text', () => {
    mockUseTextSelectionAnchor.mockReturnValue({
      messageId: 'm1',
      text: 'question',
      x: 120,
      y: 48,
    });

    const { queryByRole } = render(
      <MessageList
        messages={[
          { ...userMsg, id: 'm1', text: 'question', content: 'question' } as never,
          { ...deliveredAssistant, id: 'm2', text: 'answer', content: 'answer' } as never,
        ]}
        providers={[]}
        isStreaming={false}
        conversationId="conv-1"
        replaceCurrentNoteId="note-1"
      />,
    );

    expect(queryByRole('button', { name: 'Save as Note' })).toBeTruthy();
    expect(queryByRole('button', { name: 'Update note with selection' })).toBeNull();
  });

  it('scopes the focus-message global animation under a local CSS module class', () => {
    const css = readFileSync(join(process.cwd(), 'components/chat/MessageList.module.css'), 'utf8');

    expect(css).toContain('.area :global(.o-focus-message)');
    expect(css).not.toMatch(/(^|\n):global\(\.o-focus-message\)\s*\{/);
  });
});

function setScrollMetrics(
  element: HTMLElement,
  metrics: { scrollTop: number; scrollHeight: number; clientHeight: number },
) {
  Object.defineProperty(element, 'scrollTop', {
    configurable: true,
    writable: true,
    value: metrics.scrollTop,
  });
  Object.defineProperty(element, 'scrollHeight', {
    configurable: true,
    value: metrics.scrollHeight,
  });
  Object.defineProperty(element, 'clientHeight', {
    configurable: true,
    value: metrics.clientHeight,
  });
}
