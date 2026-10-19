// @vitest-environment jsdom
/**
 * Compaction detail Dialog: each of the three buttons calls its action, then the Dialog closes and the matching toast appears;
 * the detail fields are computed from the row by the production compactionDetailOf.
 */
import { act, cleanup, fireEvent, render, renderHook, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  recompact: vi.fn(),
  clearCompaction: vi.fn(),
  showToast: vi.fn(),
}));

vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations:
    (namespace?: string) =>
    (key: string, values?: Record<string, unknown>) =>
      `${namespace ?? ''}.${key}${values ? JSON.stringify(values) : ''}`,
}));
vi.mock('../../../../../components/Toast', () => ({ showToast: mocks.showToast }));
vi.mock('../context-compaction-actions', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../context-compaction-actions')>()),
  recompact: mocks.recompact,
  clearCompaction: mocks.clearCompaction,
}));
// The hint after the 3rd compaction hangs inside the .composer of InputComposer: render the store / entitlement stubs the input card needs.
vi.mock('../../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: unknown) => unknown) => selector({
    preferences: { sendShortcut: 'enter' }, conversations: [], providers: [], activeConversationId: null,
  }),
  tryGetVanillaStore: () => null,
  getVanillaStore: () => null,
}));
vi.mock('../../../entitlement', () => {
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
vi.mock('../../../../../components/chat/MarkdownRenderer', () => ({
  MarkdownRenderer: ({ content }: { content: string }) => <div data-testid="summary-md">{content}</div>,
}));

import type { ContextCheckpointRow } from '../../../../infra/storage/context-checkpoint-store';
import type { QuoteContext } from '@oriveo/shared';
import { CompactionDetailDialog } from '../../../../../components/chat/CompactionDetailDialog';
import { InputComposer } from '../../../../../components/chat/InputComposer';
import {
  CompactionHintBanner,
  usePendingComposerQuote,
} from '../../../../../components/chat/CompactionHintBanner';
import {
  __resetCompactionHintForTest,
  noteCompactionSaved,
  pendingCompactionHint,
  setPendingComposerQuote,
  takePendingComposerQuote,
} from '../context-compaction-actions';

const NS = 'pages.chat.contextCompaction';
const CONV = 'conv-detail';

function row(overrides: Partial<ContextCheckpointRow> = {}): ContextCheckpointRow {
  return {
    conversationId: CONV,
    checkpointId: 'cp-1',
    kind: 'summary',
    coversFrom: 'm-0',
    coversTo: 'm-3',
    coversDigest: 'd',
    messagesCovered: 4,
    userMessageIds: ['m-0', 'm-2'],
    text: 'CONTEXT CHECKPOINT\n## Goal\ng',
    summary: '## Goal\ng',
    language: 'en',
    model: 'gpt-x',
    packerVersion: 'p1',
    createdAt: 1_700_000_000_000,
    cost: null,
    ...overrides,
  } as ContextCheckpointRow;
}

function renderDialog(r: ContextCheckpointRow, onNewChatWithSummary = vi.fn()) {
  const onClose = vi.fn();
  render(
    <CompactionDetailDialog
      open
      conversationId={CONV}
      row={r}
      onClose={onClose}
      onNewChatWithSummary={onNewChatWithSummary}
    />,
  );
  return { onClose, onNewChatWithSummary };
}

describe('CompactionDetailDialog', () => {
  afterEach(cleanup);
  beforeEach(() => {
    mocks.recompact.mockReset();
    mocks.clearCompaction.mockReset();
    mocks.showToast.mockReset();
  });

  it('detail_actions_wired', async () => {
    // Compact again -> fallback toast, close after running
    mocks.recompact.mockResolvedValue('fallback');
    let view = renderDialog(row());
    expect(screen.getByTestId('summary-md').textContent).toBe('## Goal\ng');
    expect(screen.getByText(`${NS}.detailCostUnavailable`)).toBeTruthy();
    expect(screen.getByText('gpt-x')).toBeTruthy();
    expect(screen.getByText(`${NS}.detailKept{"count":2}`)).toBeTruthy();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: `${NS}.actionRecompact` }));
    });
    await waitFor(() => expect(view.onClose).toHaveBeenCalledTimes(1));
    expect(mocks.recompact).toHaveBeenCalledWith(CONV, 'cp-1');
    expect(mocks.showToast).toHaveBeenCalledWith(`${NS}.toastFallback`);
    cleanup();

    // Compact again -> noop toast; a summary result has no toast
    mocks.recompact.mockResolvedValue('noop');
    view = renderDialog(row());
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: `${NS}.actionRecompact` }));
    });
    await waitFor(() => expect(view.onClose).toHaveBeenCalledTimes(1));
    expect(mocks.showToast).toHaveBeenLastCalledWith(`${NS}.toastNoop`);
    cleanup();
    mocks.showToast.mockReset();
    mocks.recompact.mockResolvedValue(null);
    view = renderDialog(row());
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: `${NS}.actionRecompact` }));
    });
    await waitFor(() => expect(view.onClose).toHaveBeenCalledTimes(1));
    expect(mocks.showToast).not.toHaveBeenCalled();
    cleanup();

    // Clear: no second confirmation, runs directly -> cleared toast, close; a fallback row has no summary and states that nothing extra was spent
    mocks.clearCompaction.mockResolvedValue(['cp-1']);
    view = renderDialog(row({ kind: 'fallback', summary: undefined, text: 'x' }));
    expect(screen.queryByTestId('summary-md')).toBeNull();
    expect(screen.getByText(`${NS}.detailNoExtraCost`)).toBeTruthy();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: `${NS}.actionClear` }));
    });
    await waitFor(() => expect(view.onClose).toHaveBeenCalledTimes(1));
    expect(mocks.clearCompaction).toHaveBeenCalledWith(CONV);
    expect(mocks.showToast).toHaveBeenLastCalledWith(`${NS}.toastCleared`);
    cleanup();

    // Start a new conversation carrying the summary: passes the callback through with the current row, then closes
    const r = row();
    view = renderDialog(r);
    fireEvent.click(screen.getByRole('button', { name: `${NS}.actionNewChatWithSummary` }));
    expect(view.onNewChatWithSummary).toHaveBeenCalledWith(r);
    expect(view.onClose).toHaveBeenCalledTimes(1);
  });

  it('detail_time_omits_year_when_same_year', () => {
    // Same as iOS / Android: the year is omitted within the same year and kept across years.
    const now = new Date();
    const sameYear = new Date(now.getFullYear(), 0, 2, 17, 31).getTime();
    renderDialog(row({ createdAt: sameYear }));
    const sameText = screen.getByText(`${NS}.detailTime`).nextElementSibling?.textContent ?? '';
    expect(sameText).toContain('Jan 2');
    expect(sameText).not.toContain(String(now.getFullYear()));
    cleanup();
    const lastYear = new Date(now.getFullYear() - 1, 0, 2, 17, 31).getTime();
    renderDialog(row({ createdAt: lastYear }));
    const crossText = screen.getByText(`${NS}.detailTime`).nextElementSibling?.textContent ?? '';
    expect(crossText).toContain(String(now.getFullYear() - 1));
  });

  it('recompact_disables_while_running', async () => {
    let resolve: (v: null) => void = () => {};
    mocks.recompact.mockReturnValue(new Promise((r) => { resolve = r; }));
    const view = renderDialog(row());
    const button = screen.getByRole('button', { name: `${NS}.actionRecompact` }) as HTMLButtonElement;
    await act(async () => {
      fireEvent.click(button);
    });
    expect(button.disabled).toBe(true);
    await act(async () => {
      resolve(null);
    });
    await waitFor(() => expect(view.onClose).toHaveBeenCalledTimes(1));
  });
  it('recompact_error_shows_toast', async () => {
    // The action throws: log it, show the generic error toast, close the Dialog as usual, and leave no unhandled rejection
    const errorLog = vi.spyOn(console, 'error').mockImplementation(() => {});
    mocks.recompact.mockRejectedValue(new Error('boom'));
    let view = renderDialog(row());
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: `${NS}.actionRecompact` }));
    });
    await waitFor(() => expect(view.onClose).toHaveBeenCalledTimes(1));
    expect(mocks.showToast).toHaveBeenLastCalledWith('common.error', 3000, undefined, 'error');
    cleanup();

    mocks.showToast.mockReset();
    mocks.clearCompaction.mockRejectedValue(new Error('boom'));
    view = renderDialog(row());
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: `${NS}.actionClear` }));
    });
    await waitFor(() => expect(view.onClose).toHaveBeenCalledTimes(1));
    expect(mocks.showToast).toHaveBeenCalledTimes(1);
    expect(mocks.showToast).toHaveBeenLastCalledWith('common.error', 3000, undefined, 'error');
    expect(errorLog).toHaveBeenCalledTimes(2);
    errorLog.mockRestore();
  });
});

describe('CompactionHintBanner', () => {
  afterEach(cleanup);
  beforeEach(() => {
    __resetCompactionHintForTest();
    takePendingComposerQuote(null);
  });

  it('third_hint_banner_actions', () => {
    const onNewChat = vi.fn();
    const other = render(<CompactionHintBanner conversationId="conv-other" onNewChat={vi.fn()} />);
    const view = render(<CompactionHintBanner conversationId={CONV} onNewChat={onNewChat} />);
    expect(screen.queryByText(`${NS}.thirdHint`)).toBeNull();

    // After the 3rd row is persisted, the hint bar shows only for this conversation.
    act(() => noteCompactionSaved(CONV, 3));
    expect(screen.getAllByText(`${NS}.thirdHint`)).toHaveLength(1);
    expect(view.container.textContent).toContain(`${NS}.thirdHint`);
    expect(other.container.textContent).toBe('');

    // New conversation: the callback fires once, and the hint is dismissed.
    fireEvent.click(screen.getByRole('button', { name: `${NS}.thirdHintNewChat` }));
    expect(onNewChat).toHaveBeenCalledTimes(1);
    expect(pendingCompactionHint()).toBeNull();
    expect(screen.queryByText(`${NS}.thirdHint`)).toBeNull();

    // Got it: dismiss, without opening a new conversation.
    __resetCompactionHintForTest();
    act(() => noteCompactionSaved(CONV, 3));
    fireEvent.click(screen.getByRole('button', { name: `${NS}.thirdHintDismiss` }));
    expect(pendingCompactionHint()).toBeNull();
    expect(screen.queryByText(`${NS}.thirdHint`)).toBeNull();
    expect(onNewChat).toHaveBeenCalledTimes(1);
  });

  it('third_hint_renders_inside_composer_card', () => {
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        composerNotices={<CompactionHintBanner conversationId={CONV} onNewChat={vi.fn()} />}
      />,
    );
    expect(screen.queryByText(`${NS}.thirdHint`)).toBeNull();

    // At phone width the input area is absolutely positioned over the bottom of the document flow: the hint bar must sit inside the input card's .composer to be visible.
    act(() => noteCompactionSaved(CONV, 3));
    const hint = screen.getByText(`${NS}.thirdHint`);
    expect(hint.closest('.composer')).not.toBeNull();
  });

  it('new_chat_consumes_pending_quote', () => {
    const quote: QuoteContext = {
      schemaVersion: 1,
      sourceMessageId: 'm-3',
      sourceRole: 'assistant',
      contentKind: 'prose',
      leadingText: 'Label',
      selectedText: '## Goal\ng',
      trailingText: '',
      contextTruncated: false,
    };
    setPendingComposerQuote(null, quote);

    // Mounting an existing conversation does not take the id-less slot.
    const onQuoteExisting = vi.fn();
    renderHook(() => usePendingComposerQuote('conv-existing', onQuoteExisting));
    expect(onQuoteExisting).not.toHaveBeenCalled();

    // Mounting a new conversation takes it once; re-rendering does not take it again.
    const setPendingQuoteContext = vi.fn();
    const hook = renderHook(() => usePendingComposerQuote(null, setPendingQuoteContext));
    expect(setPendingQuoteContext).toHaveBeenCalledTimes(1);
    expect(setPendingQuoteContext).toHaveBeenCalledWith(quote);
    hook.rerender();
    expect(setPendingQuoteContext).toHaveBeenCalledTimes(1);
    expect(takePendingComposerQuote(null)).toBeNull();
  });
});
