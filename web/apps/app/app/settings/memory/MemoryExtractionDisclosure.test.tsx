import 'fake-indexeddb/auto';
/**
 * Disclosure before AI drafting / organizing into items runs. Goes through the MemoryPage entry and asserts the request the production path hands to sendStream.
 */
import type { ReactNode } from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createStore, type StoreApi } from 'zustand';
import type { AIModel, Provider } from '@oriveo/shared';
import type { StreamEvent } from '@oriveo/core/providers/types';
import { MemoryItems, type MemoryItem } from '@oriveo/core/context/memory-items';
import type { MemoryItemRow } from '../../../lib/infra/storage/memory-item-store';
import type { MemoryItemRowStore } from '../../../lib/core/memory/memory-item-row-store';
import { createMemoryItemRepository } from '../../../lib/core/memory/memory-item-repository';
import { createMemoryCandidateRepository } from '../../../lib/core/memory/memory-candidate-repository';
import { resetDBConnection } from '../../../lib/infra/storage/idb';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { MemoryPage } from './MemoryPage';

type TestState = {
  preferences: Record<string, unknown>;
  providers: Provider[];
  conversations: unknown[];
  lastUsedModelRef: { providerID: string; modelID: string } | null;
  memoryItems: MemoryItem[];
  setPreferences: (patch: Record<string, unknown>) => void;
  setMemoryItems: (items: MemoryItem[]) => void;
};

type StoredMessage = { role: string; text: string; providerID?: string };

const LOCAL_DEVICE = 'device-local';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  storedMessages: new Map<string, Array<{ role: string; text: string; providerID?: string }>>(),
  // Gate for reading conversations: when non-empty, getConversationById waits for it to release, used to stop in the drafting preparation phase.
  hydrateGate: null as Promise<void> | null,
  hydrateCalls: 0,
}));

let appStore: StoreApi<TestState>;
let rows: MemoryItemRowStore & { map: Map<string, MemoryItemRow> };

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

// Parameterized strings append the parameter values after the key, so assertions can see the provider / model display name.
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}:${Object.values(values).join('|')}` : key,
}));

vi.mock('../../../providers/StoreProvider', async () => {
  const { useStore } = await import('zustand');
  return {
    useAppStore: (selector: (state: TestState) => unknown) => useStore(appStore, selector),
    getVanillaStore: () => appStore,
  };
});

vi.mock('../../../lib/core/bootstrap', () => ({
  getOrCreateStableWebDeviceId: () => LOCAL_DEVICE,
}));

vi.mock('../../../lib/core/providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

// Full conversation messages are read from IDB: swapped for an in-memory table, other idb functions stay as is.
vi.mock('../../../lib/infra/storage/idb', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/infra/storage/idb')>();
  return {
    ...actual,
    getConversationById: async (id: string) => {
      mocks.hydrateCalls += 1;
      if (mocks.hydrateGate) await mocks.hydrateGate;
      const messages = mocks.storedMessages.get(id);
      return messages ? { id, messages } : undefined;
    },
  };
});

vi.mock('../../../lib/core/memory/memory-item-repository', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/memory/memory-item-repository')>();
  return {
    ...actual,
    createMemoryItemRepository: (options: Parameters<typeof actual.createMemoryItemRepository>[0]) =>
      actual.createMemoryItemRepository({ ...options, rows, sync: () => null, onLocalChange: () => undefined }),
  };
});

vi.mock('@oriveo/ui', () => ({
  BackButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
  Button: ({
    children,
    onClick,
    disabled,
  }: {
    children: ReactNode;
    onClick?: () => void;
    disabled?: boolean;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  Dialog: ({ open, children }: { open: boolean; onClose?: () => void; children: ReactNode }) => (
    open ? <div role="dialog">{children}</div> : null
  ),
}));

function memoryRows(): MemoryItemRowStore & { map: Map<string, MemoryItemRow> } {
  const map = new Map<string, MemoryItemRow>();
  let tail: Promise<unknown> = Promise.resolve();
  return {
    map,
    all: async () => [...map.values()],
    get: async (id) => map.get(id),
    put: async (next) => {
      for (const row of next) map.set(row.id, row);
    },
    exclusive: <T,>(op: () => Promise<T>) => {
      const run = tail.then(op, op);
      tail = run.catch(() => undefined);
      return run;
    },
  };
}

function model(id: string, name: string): AIModel {
  return {
    id, name, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  } as AIModel;
}

function relay(id: string, customName: string, models: AIModel[]): Provider {
  return {
    id, kind: 'relay', customName, status: { kind: 'connected' }, models, catalogModels: [], apiKey: `sk-${id}`, apiKeyPreview: '••',
    baseURLText: `https://${id}.example/v1`,
    relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: `https://${id}.example/v1` },
    relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
  } as unknown as Provider;
}

const providerA = relay('prov-a', 'Relay A', [model('model-a', 'Model A Display')]);
const providerB = relay('prov-b', 'Relay B', [model('model-b', 'Model B Display')]);

function stream(events: StreamEvent[]): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    start(controller) {
      for (const event of events) controller.enqueue(event);
      controller.close();
    },
  });
}

function replyWith(text: string) {
  mocks.sendStream.mockImplementation(() => ({
    stream: stream([{ type: 'delta', content: text } as StreamEvent, { type: 'done' } as StreamEvent]),
  }));
}

function seedConversations(convs: Record<string, StoredMessage[]>) {
  const summaries = Object.keys(convs).map((id, index) => ({
    id,
    isDraft: false,
    remoteMessageCount: convs[id].length,
    updatedAt: `2026-10-${String(10 - index).padStart(2, '0')}T00:00:00Z`,
  }));
  for (const [id, messages] of Object.entries(convs)) mocks.storedMessages.set(id, messages);
  appStore.setState({ conversations: summaries });
}

async function clickGenerate() {
  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: /generateDraft/ }));
  });
}

function disclosure(): HTMLElement {
  return screen.getByText('extractionTitleDraft').closest('[role="dialog"]') as HTMLElement;
}

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 30));
  });
}

/** Body of the user message that sendStream received. */
function sentUserContent(call: unknown[]): string {
  const messages = call[3] as Array<{ role: string; content: unknown }>;
  const users = messages.filter((m) => m.role === 'user');
  expect(users).toHaveLength(1);
  return users[0].content as string;
}

async function clearAllDatabases() {
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('MemoryExtractionDisclosure (draft)', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    mocks.sendStream.mockReset();
    mocks.storedMessages.clear();
    mocks.hydrateGate = null;
    mocks.hydrateCalls = 0;
    appStore = createStore<TestState>()((set) => ({
      preferences: {},
      // Last used was B: B is the first candidate.
      providers: [providerA, providerB],
      conversations: [],
      lastUsedModelRef: { providerID: 'prov-b', modelID: 'model-b' },
      memoryItems: [],
      setPreferences: (patch) => set((s) => ({ preferences: { ...s.preferences, ...patch } })),
      setMemoryItems: (items) => set({ memoryItems: items }),
    }));
    rows = memoryRows();
  });

  afterEach(async () => {
    cleanup();
    const uid = getActiveUIDSync();
    await createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store: appStore as never, uid, deviceId: LOCAL_DEVICE }),
    }).pending();
  });

  it('draft_disclosure_shows_provider_model_and_scope', async () => {
    seedConversations({ c1: [{ role: 'user', text: 'I write Rust daily', providerID: 'prov-b' }] });
    render(<MemoryPage />);
    await clickGenerate();

    const dialog = await waitFor(() => disclosure());
    expect(within(dialog).getByText('extractionModel:Relay B|Model B Display')).toBeTruthy();
    expect(within(dialog).getByText('extractionScopeDraft')).toBeTruthy();
    expect(within(dialog).getByText('extractionNoFallback')).toBeTruthy();
    expect(within(dialog).getByRole('button', { name: 'cancel' })).toBeTruthy();
    expect(within(dialog).getByRole('button', { name: 'extractionSend' })).toBeTruthy();
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });

  it('draft_sends_nothing_until_confirmed', async () => {
    replyWith('I am a Rust developer.');
    seedConversations({ c1: [{ role: 'user', text: 'I write Rust daily', providerID: 'prov-b' }] });
    render(<MemoryPage />);
    await clickGenerate();
    const dialog = await waitFor(() => disclosure());
    await settle();
    expect(mocks.sendStream).not.toHaveBeenCalled();

    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'extractionSend' }));
    });
    await waitFor(() => expect(mocks.sendStream).toHaveBeenCalledTimes(1));
    // What is sent is exactly the provider + model written in the dialog.
    const call = mocks.sendStream.mock.calls[0];
    expect(call[0]).toBe('relay');
    expect(call[1]).toBe('sk-prov-b');
    expect(call[2]).toBe('model-b');
    expect(screen.queryByText('extractionTitleDraft')).toBeNull();
    // Where the result goes is unchanged: a new editor is opened pre-filled with the draft.
    await waitFor(() => expect(screen.getByDisplayValue('I am a Rust developer.')).toBeTruthy());
  });

  it('draft_cancel_sends_nothing', async () => {
    seedConversations({ c1: [{ role: 'user', text: 'I write Rust daily', providerID: 'prov-b' }] });
    render(<MemoryPage />);
    await clickGenerate();
    const dialog = await waitFor(() => disclosure());

    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'cancel' }));
    });
    await settle();
    expect(screen.queryByText('extractionTitleDraft')).toBeNull();
    expect(mocks.sendStream).not.toHaveBeenCalled();
    // State returns to before the click: the entry button can be tapped again and there is no error dialog.
    expect(screen.queryByRole('dialog')).toBeNull();
    expect((screen.getByRole('button', { name: /generateDraft/ }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('draft_sends_only_user_messages_of_chosen_provider', async () => {
    replyWith('draft');
    seedConversations({
      c1: [
        { role: 'user', text: 'B question one', providerID: 'prov-b' },
        { role: 'assistant', text: 'B answer one', providerID: 'prov-b' },
        { role: 'user', text: 'A question', providerID: 'prov-a' },
        { role: 'user', text: 'no provider question' },
        { role: 'user', text: 'B question two', providerID: 'prov-b' },
      ],
      // Only other providers' messages: drop the whole segment, leaving no empty separator.
      c2: [{ role: 'user', text: 'A only', providerID: 'prov-a' }],
      c3: [
        { role: 'user', text: 'x'.repeat(600), providerID: 'prov-b' },
      ],
    });
    render(<MemoryPage />);
    await clickGenerate();
    const dialog = await waitFor(() => disclosure());
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'extractionSend' }));
    });
    await waitFor(() => expect(mocks.sendStream).toHaveBeenCalledTimes(1));

    expect(sentUserContent(mocks.sendStream.mock.calls[0])).toBe(
      ['user: B question one\nuser: B question two', `user: ${'x'.repeat(600)}`.slice(0, 500)].join('\n---\n'),
    );
  });

  it('draft_failure_does_not_switch_provider', async () => {
    const rateLimited = 'You have exceeded the rate limit. Please wait a moment and try again.';
    mocks.sendStream.mockImplementation(() => ({
      stream: stream([{ type: 'error', error: rateLimited } as StreamEvent]),
    }));
    seedConversations({
      c1: [
        { role: 'user', text: 'B question', providerID: 'prov-b' },
        { role: 'user', text: 'A question', providerID: 'prov-a' },
      ],
    });
    render(<MemoryPage />);
    await clickGenerate();
    let dialog = await waitFor(() => disclosure());
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'extractionSend' }));
    });

    // A failure reports an error directly: the body = the localized text of that provider's error detail (not the English original), A is not retried, and the aggregated text is not used.
    await waitFor(() => expect(screen.getByText('rateLimited.message')).toBeTruthy());
    expect(screen.queryByText(rateLimited)).toBeNull();
    expect(screen.getByText('errorGenericTitle')).toBeTruthy();
    expect(screen.queryByText(/errorAggregated/)).toBeNull();
    await settle();
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(mocks.sendStream.mock.calls[0][1]).toBe('sk-prov-b');

    // Empty reply: the body is the localized empty-reply detail, the title is unchanged, and it is likewise sent only once.
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'OK' }));
    });
    replyWith('   ');
    await clickGenerate();
    dialog = await waitFor(() => disclosure());
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'extractionSend' }));
    });
    await waitFor(() => expect(screen.getByText('generateDraftEmpty')).toBeTruthy());
    expect(screen.getByText('errorGenericTitle')).toBeTruthy();
    await settle();
    expect(mocks.sendStream).toHaveBeenCalledTimes(2);
    expect(mocks.sendStream.mock.calls[1][1]).toBe('sk-prov-b');
  });

  it('draft_empty_reply_shows_empty_copy', async () => {
    replyWith('   ');
    seedConversations({ c1: [{ role: 'user', text: 'B question', providerID: 'prov-b' }] });
    render(<MemoryPage />);
    await clickGenerate();
    const dialog = await waitFor(() => disclosure());
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'extractionSend' }));
    });

    // The model returns an entirely empty reply: the body is generateDraftEmpty, not the generic generateDraftFailed.
    await waitFor(() => expect(screen.getByText('generateDraftEmpty')).toBeTruthy());
    expect(screen.queryByText('generateDraftFailed')).toBeNull();
    expect(screen.getByText('errorGenericTitle')).toBeTruthy();
    await settle();
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
  });

  it('draft_prepare_shows_loading_and_ignores_repeat_tap', async () => {
    seedConversations({ c1: [{ role: 'user', text: 'I write Rust daily', providerID: 'prov-b' }] });
    let release: () => void = () => undefined;
    mocks.hydrateGate = new Promise<void>((resolve) => {
      release = resolve;
    });
    render(<MemoryPage />);
    await clickGenerate();

    // While reading conversations: the button shows generateDraftLoading and cannot be tapped again, and the disclosure dialog has not appeared.
    const button = screen.getByRole('button', { name: /generateDraft/ }) as HTMLButtonElement;
    expect(button.textContent).toContain('generateDraftLoading');
    expect(button.disabled).toBe(true);
    expect(screen.queryByText('extractionTitleDraft')).toBeNull();
    expect(mocks.hydrateCalls).toBe(1);

    // Tapping again (including Cmd+Enter) does not start another round of reading conversations.
    await clickGenerate();
    await act(async () => {
      fireEvent.keyDown(window, { key: 'Enter', metaKey: true });
    });
    expect(mocks.hydrateCalls).toBe(1);

    await act(async () => {
      release();
    });
    const dialog = await waitFor(() => disclosure());
    // Loading is cleared before the dialog appears: the entry button returns to its original text.
    expect(screen.queryByText('generateDraftLoading')).toBeNull();
    expect(screen.getAllByText('extractionTitleDraft')).toHaveLength(1);
    expect(within(dialog).getByText('extractionModel:Relay B|Model B Display')).toBeTruthy();
    expect(mocks.hydrateCalls).toBe(1);
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });

  it('draft_not_enough_when_no_user_message_for_provider', async () => {
    seedConversations({
      c1: [
        { role: 'assistant', text: 'B answer', providerID: 'prov-b' },
        { role: 'user', text: 'A question', providerID: 'prov-a' },
        { role: 'user', text: 'no provider question' },
      ],
    });
    render(<MemoryPage />);
    await clickGenerate();

    await waitFor(() => expect(screen.getByText('errorNotEnoughTitle')).toBeTruthy());
    expect(screen.getByText('errorNotEnoughMessage')).toBeTruthy();
    expect(screen.queryByText('extractionTitleDraft')).toBeNull();
    await settle();
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });
});

const MIGRATED: MemoryItem = MemoryItems.canonical({
  id: 'migrated-1',
  kind: 'fact',
  content: 'I write historical novels.\nPrefer answers in Arabic.',
  mutationId: 'mutation-migrated-1',
  deviceId: 'device-other',
  revision: 1,
  source: { type: 'migration' },
});

const ORGANIZE_REPLY = '[{"kind":"identity","content":"I write historical novels."},'
  + '{"kind":"preference","content":"Prefer answers in Arabic."}]';

async function clickOrganize() {
  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: 'actionOrganize' }));
  });
}

function organizeDisclosure(): HTMLElement {
  return screen.getByText('extractionTitleOrganize').closest('[role="dialog"]') as HTMLElement;
}

describe('MemoryExtractionDisclosure (organize)', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    mocks.sendStream.mockReset();
    mocks.storedMessages.clear();
    appStore = createStore<TestState>()((set) => ({
      preferences: {},
      // Last used was B: B is the first candidate.
      providers: [providerA, providerB],
      conversations: [],
      lastUsedModelRef: { providerID: 'prov-b', modelID: 'model-b' },
      memoryItems: [MIGRATED],
      setPreferences: (patch) => set((s) => ({ preferences: { ...s.preferences, ...patch } })),
      setMemoryItems: (items) => set({ memoryItems: items }),
    }));
    rows = memoryRows();
  });

  afterEach(async () => {
    cleanup();
    const uid = getActiveUIDSync();
    await createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store: appStore as never, uid, deviceId: LOCAL_DEVICE }),
    }).pending();
  });

  it('organize_disclosure_shows_provider_model_and_scope', async () => {
    replyWith(ORGANIZE_REPLY);
    render(<MemoryPage />);
    await clickOrganize();

    const dialog = await waitFor(() => organizeDisclosure());
    expect(within(dialog).getByText('extractionModel:Relay B|Model B Display')).toBeTruthy();
    expect(within(dialog).getByText('extractionScopeOrganize')).toBeTruthy();
    expect(within(dialog).getByText('extractionNoFallback')).toBeTruthy();
    expect(within(dialog).getByRole('button', { name: 'cancel' })).toBeTruthy();
    // No request is sent before tapping [Send], and the organize dialog is not mounted.
    await settle();
    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(screen.queryByText('organizeLoading')).toBeNull();

    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'extractionSend' }));
    });
    await waitFor(() => expect(mocks.sendStream).toHaveBeenCalledTimes(1));
    // What is sent is exactly the provider + model written in the dialog, and the request body is the original text of this memory.
    const call = mocks.sendStream.mock.calls[0];
    expect(call[0]).toBe('relay');
    expect(call[1]).toBe('sk-prov-b');
    expect(call[2]).toBe('model-b');
    expect(sentUserContent(call)).toContain(MIGRATED.content);
    expect(screen.queryByText('extractionTitleOrganize')).toBeNull();
    // Only after sending is the existing organize dialog opened, and the results are listed as before.
    await waitFor(() => expect(screen.getByText('Prefer answers in Arabic.', { selector: 'span' })).toBeTruthy());
    expect(screen.getByRole('button', { name: 'organizeSave' })).toBeTruthy();
  });

  it('organize_cancel_sends_nothing', async () => {
    render(<MemoryPage />);
    await clickOrganize();
    const dialog = await waitFor(() => organizeDisclosure());

    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'cancel' }));
    });
    await settle();
    expect(screen.queryByText('extractionTitleOrganize')).toBeNull();
    expect(mocks.sendStream).not.toHaveBeenCalled();
    // State returns to before the click: no organize dialog, and the entry is still there.
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(screen.getByRole('button', { name: 'actionOrganize' })).toBeTruthy();
  });

  it('organize_failure_does_not_switch_provider', async () => {
    mocks.sendStream.mockImplementation(() => ({
      stream: stream([{ type: 'error', error: 'B quota exceeded' } as StreamEvent]),
    }));
    render(<MemoryPage />);
    await clickOrganize();
    const dialog = await waitFor(() => organizeDisclosure());
    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'extractionSend' }));
    });

    // A failure is the existing failed state, and A is not retried.
    await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('organizeFailed'));
    await settle();
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(mocks.sendStream.mock.calls[0][1]).toBe('sk-prov-b');
    expect(screen.queryByRole('button', { name: 'organizeSave' })).toBeNull();

    // An empty reply (empty after trim) is likewise the failed state, not organizeEmpty, and is also sent only once.
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'cancel' }));
    });
    replyWith('   ');
    await clickOrganize();
    const again = await waitFor(() => organizeDisclosure());
    await act(async () => {
      fireEvent.click(within(again).getByRole('button', { name: 'extractionSend' }));
    });
    await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('organizeFailed'));
    await settle();
    expect(mocks.sendStream).toHaveBeenCalledTimes(2);
    expect(mocks.sendStream.mock.calls[1][1]).toBe('sk-prov-b');
    expect(screen.queryByRole('button', { name: 'organizeSave' })).toBeNull();
  });
});
