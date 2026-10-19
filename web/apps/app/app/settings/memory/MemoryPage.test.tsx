import 'fake-indexeddb/auto';
import type { ReactNode } from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createStore, type StoreApi } from 'zustand';
import { MemoryItems, type MemoryItem, type MemoryItemInput } from '@oriveo/core/context/memory-items';
import type { MemoryItemRow } from '../../../lib/infra/storage/memory-item-store';
import type { MemoryItemRowStore } from '../../../lib/core/memory/memory-item-row-store';
import { memoryItemsForSlice } from '../../../lib/core/memory/memory-items-slice';
import { createMemoryItemRepository } from '../../../lib/core/memory/memory-item-repository';
import { createMemoryCandidateRepository } from '../../../lib/core/memory/memory-candidate-repository';
import { resetDBConnection } from '../../../lib/infra/storage/idb';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { MemoryPage } from './MemoryPage';
import { todayDate } from './MemoryItemEditor';

type TestState = {
  preferences: Record<string, unknown>;
  providers: unknown[];
  conversations: unknown[];
  lastUsedModelRef: null;
  memoryItems: MemoryItem[];
  folders: Array<{ id: string; name: string }>;
  setPreferences: (patch: Record<string, unknown>) => void;
  setMemoryItems: (items: MemoryItem[]) => void;
};

const LOCAL_DEVICE = 'device-local';

// The store and local rows in the test: mock factories read them only when called, and they are rebuilt for every case.
let appStore: StoreApi<TestState>;
let rows: MemoryItemRowStore & { map: Map<string, MemoryItemRow> };
// Arguments the page hands to repository resolveL3Conflict, in call order.
let l3Calls: Array<[string, string, string]> = [];

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) => (
    values ? `${key}:${JSON.stringify(values)}` : key
  ),
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

// Real repositories, with only the local rows swapped for an in-memory implementation and the sync engine disconnected.
vi.mock('../../../lib/core/memory/memory-item-repository', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/memory/memory-item-repository')>();
  return {
    ...actual,
    createMemoryItemRepository: (options: Parameters<typeof actual.createMemoryItemRepository>[0]) => {
      const repository = actual.createMemoryItemRepository({ ...options, rows, sync: () => null, onLocalChange: () => undefined });
      return {
        ...repository,
        resolveL3Conflict: (newerId: string, olderId: string, resolution: Parameters<typeof repository.resolveL3Conflict>[2]) => {
          l3Calls.push([newerId, olderId, resolution]);
          return repository.resolveL3Conflict(newerId, olderId, resolution);
        },
      };
    },
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

function memoryRows(seed: MemoryItem[]): MemoryItemRowStore & { map: Map<string, MemoryItemRow> } {
  const map = new Map<string, MemoryItemRow>(seed.map((item) => [item.id, { id: item.id, item, syncState: 'synced' }]));
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

let createdSeq = 0;
function item(id: string, kind: MemoryItemInput['kind'], content: string, extra: Partial<MemoryItemInput> = {}): MemoryItem {
  createdSeq += 1;
  return MemoryItems.canonical({
    id,
    kind,
    content,
    mutationId: `mutation-${id}`,
    deviceId: 'device-other',
    revision: 1,
    createdAt: `2026-10-${String(createdSeq).padStart(2, '0')}T00:00:00Z`,
    ...extra,
  });
}

function seed(items: MemoryItem[]): void {
  rows = memoryRows(items);
  appStore.getState().setMemoryItems(memoryItemsForSlice(items));
}

function stored(id: string): MemoryItem | undefined {
  return rows.map.get(id)?.item;
}

function rowOf(content: string): HTMLElement {
  const row = screen.getByText(content).closest('li');
  if (!row) throw new Error(`no row for ${content}`);
  return row as HTMLElement;
}

function openMenu(content: string) {
  fireEvent.click(within(rowOf(content)).getByRole('button', { name: 'more' }));
  return screen.getByRole('menu');
}

function groupTitles(): string[] {
  return screen.getAllByRole('heading', { level: 3 }).map((h) => h.textContent ?? '');
}

function groupContents(title: string): string[] {
  const heading = screen.getByRole('heading', { level: 3, name: title });
  const section = heading.closest('section') as HTMLElement;
  return within(section).getAllByTestId('memory-item-content').map((el) => el.textContent ?? '');
}

async function clearAllDatabases() {
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('MemoryPage', () => {
  beforeEach(async () => {
    // The entry row reads the candidate repository (fake-indexeddb): the database is cleared for every case, with no candidates by default.
    resetDBConnection();
    await clearAllDatabases();
    createdSeq = 0;
    appStore = createStore<TestState>()((set) => ({
      preferences: {},
      providers: [],
      conversations: [],
      lastUsedModelRef: null,
      memoryItems: [],
      folders: [],
      setPreferences: (patch) => set((s) => ({ preferences: { ...s.preferences, ...patch } })),
      setMemoryItems: (items) => set({ memoryItems: items }),
    }));
    rows = memoryRows([]);
    l3Calls = [];
  });

  afterEach(async () => {
    window.history.replaceState(null, '', '/');
    // Unmount first (effect cancellation no longer calls setState); the pending() that the entry row fetches the count with is still running after unmount:
    // the same uid shares one lock, so queue one pending() and wait for it to settle before the next case clears the database.
    cleanup();
    const uid = getActiveUIDSync();
    await createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store: appStore as never, uid, deviceId: LOCAL_DEVICE }),
    }).pending();
  });

  it('entry_row_shows_pending_count', async () => {
    // 0 items: the entry row is there (also in the empty state) and shows no count
    const empty = render(<MemoryPage />);
    expect(screen.getByText('emptyTitle')).toBeTruthy();
    const entry = screen.getByTestId('memory-inbox-entry');
    expect(within(entry).getByText('inboxTitle')).toBeTruthy();
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 30));
    });
    expect(screen.queryByTestId('memory-inbox-count')).toBeNull();
    empty.unmount();

    // Two pending: the value = the repository pending() count; the list state also has the entry row
    seed([item('a1', 'identity', 'I write historical novels')]);
    const uid = getActiveUIDSync();
    const candidates = createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store: appStore as never, uid, deviceId: LOCAL_DEVICE }),
    });
    const base = Date.now() - 10_000;
    for (const [index, text] of ['\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54', '\u8bb0\u4f4f\u6211\u4f4f\u5728\u4e0a\u6d77'].entries()) {
      const created = await candidates.generate({
        text, messageId: `m-${index}`, conversationId: 'conv-1', folderId: null, useMemory: true, nowMs: base + index,
      });
      expect(created?.status).toBe('pending');
    }
    const pending = await candidates.pending();
    expect(pending).toHaveLength(2);

    render(<MemoryPage />);
    expect(screen.getByText('I write historical novels')).toBeTruthy();
    expect((await screen.findByTestId('memory-inbox-count')).textContent).toBe(String(pending.length));
    expect(within(screen.getByTestId('memory-inbox-entry')).getByText('inboxTitle')).toBeTruthy();
  });

  it('shows the starter card with the add action when there is no memory', () => {
    render(<MemoryPage />);

    expect(screen.getByText('emptyTitle')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'addItem' }));
    expect(screen.getByRole('heading', { name: 'editorTitleNew' })).toBeTruthy();
  });

  it('groups_in_list_order', () => {
    seed([
      item('a1', 'identity', 'I write historical novels'),
      item('p1', 'preference', 'Prefers short answers'),
      item('i1', 'instruction', 'Always answer in Arabic'),
      item('a2', 'fact', 'Lives in Cairo'),
      item('i2', 'constraint', 'Never use emoji'),
      item('a3', 'identity', 'Pinned identity', { pinned: true }),
      item('c1', 'preference', 'Keep it brief', { status: 'conflicted', conflictGroupId: 'g1', deviceId: LOCAL_DEVICE }),
      item('c2', 'preference', 'Keep it brief, code when needed', { status: 'conflicted', conflictGroupId: 'g1' }),
    ]);
    render(<MemoryPage />);

    // The conflict group is at the very top; an empty "Projects" group shows no title; the L3 group is always last
    expect(groupTitles()).toEqual(['groupConflicts', 'groupAbout', 'groupPreferences', 'groupInstructions', 'groupEpisodic']);
    expect(groupContents('groupAbout')).toEqual(['Pinned identity', 'I write historical novels', 'Lives in Cairo']);
    expect(groupContents('groupInstructions')).toEqual(['Always answer in Arabic', 'Never use emoji']);
    expect(groupContents('groupPreferences')).toEqual(['Prefers short answers']);
  });

  it('hides_deleted', () => {
    const removed = MemoryItems.tombstone({
      item: item('d1', 'identity', 'Deleted fact'),
      mutationId: 'mutation-del',
      deviceId: 'device-other',
      deletedAt: '2026-10-10T00:00:00Z',
    });
    // The repository list does not include tombstones, but the slice the page reads must filter them itself: put the tombstones straight into the slice.
    rows = memoryRows([removed]);
    appStore.getState().setMemoryItems([
      removed,
      item('e1', 'event', 'Went to the market'),
      item('a1', 'identity', 'Visible identity'),
    ]);
    render(<MemoryPage />);

    expect(screen.getByText('Visible identity')).toBeTruthy();
    expect(screen.queryByText('Went to the market')).toBeNull();
    expect(screen.getAllByTestId('memory-item-content')).toHaveLength(1);
  });

  it('paused_badge', async () => {
    seed([item('i1', 'instruction', 'Always answer in Arabic', { status: 'paused' }), item('i2', 'instruction', 'Be concise')]);
    render(<MemoryPage />);

    expect(within(rowOf('Always answer in Arabic')).getByText('itemPausedBadge')).toBeTruthy();
    expect(within(rowOf('Be concise')).queryByText('itemPausedBadge')).toBeNull();

    fireEvent.click(within(openMenu('Always answer in Arabic')).getByRole('menuitem', { name: 'actionResume' }));

    await waitFor(() => expect(stored('i1')?.status).toBe('active'));
    await waitFor(() => expect(within(rowOf('Always answer in Arabic')).queryByText('itemPausedBadge')).toBeNull());

    fireEvent.click(within(openMenu('Be concise')).getByRole('menuitem', { name: 'actionPause' }));
    await waitFor(() => expect(stored('i2')?.status).toBe('paused'));
  });

  it('pin_moves_to_top', async () => {
    seed([item('a1', 'identity', 'First identity'), item('a2', 'fact', 'Second fact')]);
    render(<MemoryPage />);
    expect(groupContents('groupAbout')).toEqual(['First identity', 'Second fact']);

    fireEvent.click(within(openMenu('Second fact')).getByRole('menuitem', { name: 'actionPin' }));

    await waitFor(() => expect(groupContents('groupAbout')).toEqual(['Second fact', 'First identity']));
    expect(stored('a2')?.pinned).toBe(true);
    expect(within(rowOf('Second fact')).getByLabelText('itemPinnedA11y')).toBeTruthy();
    expect(within(openMenu('Second fact')).getByRole('menuitem', { name: 'actionUnpin' })).toBeTruthy();
  });

  it('edit_dialog_saves_and_limits_2000', async () => {
    seed([item('p1', 'preference', 'Prefers short answers'), item('a1', 'fact', 'Lives in Cairo')]);
    render(<MemoryPage />);

    // Create: a category can be chosen even from a group that has no "Long-term instructions"
    fireEvent.click(screen.getAllByRole('button', { name: 'addItem' })[0]);
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'editorTitleNew' })).toBeTruthy();
    fireEvent.click(within(dialog).getByRole('radio', { name: 'groupInstructions' }));

    const textbox = within(dialog).getByRole('textbox');
    fireEvent.change(textbox, { target: { value: 'a'.repeat(2001) } });
    expect(within(dialog).getByText('2001 / 2000')).toBeTruthy();
    expect(within(dialog).getByText('editorTooLong')).toBeTruthy();
    expect((within(dialog).getByRole('button', { name: 'save' }) as HTMLButtonElement).disabled).toBe(true);

    // Counted by code point: 2000 emoji are 4000 UTF-16 units and can still be saved
    const emoji = '\u{1F600}'.repeat(2000);
    fireEvent.change(textbox, { target: { value: emoji } });
    expect(within(dialog).getByText('2000 / 2000')).toBeTruthy();
    expect(within(dialog).queryByText('editorTooLong')).toBeNull();

    fireEvent.change(textbox, { target: { value: 'Answer in Arabic' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'save' }));

    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    const created = [...rows.map.values()].map((r) => r.item).find((m) => m.content === 'Answer in Arabic');
    expect(created?.kind).toBe('instruction');
    expect(created?.source.type).toBe('manual');
    expect(groupContents('groupInstructions')).toEqual(['Answer in Arabic']);

    // Edit: when the category is untouched, fact stays fact
    fireEvent.click(within(openMenu('Lives in Cairo')).getByRole('menuitem', { name: 'actionEdit' }));
    const editDialog = screen.getByRole('dialog');
    expect(within(editDialog).getByRole('heading', { name: 'editorTitleEdit' })).toBeTruthy();
    expect((within(editDialog).getByRole('radio', { name: 'groupAbout' }) as HTMLElement).getAttribute('aria-checked')).toBe('true');
    fireEvent.change(within(editDialog).getByRole('textbox'), { target: { value: 'Lives in Alexandria' } });
    fireEvent.click(within(editDialog).getByRole('button', { name: 'save' }));
    await waitFor(() => expect(stored('a1')?.content).toBe('Lives in Alexandria'));
    expect(stored('a1')?.kind).toBe('fact');
    expect(stored('a1')?.baseRevision).toBe(1);

    // Edit with a category change: Preference -> About me writes identity
    fireEvent.click(within(openMenu('Prefers short answers')).getByRole('menuitem', { name: 'actionEdit' }));
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('radio', { name: 'groupAbout' }));
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'save' }));
    await waitFor(() => expect(stored('p1')?.kind).toBe('identity'));
  });

  it('delete_confirms_then_tombstones', async () => {
    seed([item('a1', 'identity', 'Delete me'), item('a2', 'identity', 'Keep me')]);
    render(<MemoryPage />);

    fireEvent.click(within(openMenu('Delete me')).getByRole('menuitem', { name: 'actionDelete' }));
    let dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText('deleteConfirmTitle')).toBeTruthy();
    expect(within(dialog).getByText('deleteConfirmBody')).toBeTruthy();

    fireEvent.click(within(dialog).getByRole('button', { name: 'cancel' }));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(stored('a1')?.status).toBe('active');

    fireEvent.click(within(openMenu('Delete me')).getByRole('menuitem', { name: 'actionDelete' }));
    dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: 'actionDelete' }));

    await waitFor(() => expect(stored('a1')?.status).toBe('deleted'));
    expect(stored('a1')?.content).toBe('');
    expect(rows.map.get('a1')?.syncState).toBe('pending');
    await waitFor(() => expect(screen.queryByText('Delete me')).toBeNull());
    expect(screen.getByText('Keep me')).toBeTruthy();
  });

  it('conflict_keep_one', async () => {
    // Real shape: the original item has id = conflictGroupId and takes the remote body and is pushed as a local edit (deviceId is this device);
    // the copy has id != conflictGroupId and carries the deviceId of this device's pending-push edit
    seed([
      item('c1', 'preference', 'Keep it brief', { status: 'conflicted', conflictGroupId: 'c2', deviceId: LOCAL_DEVICE }),
      item('c2', 'preference', 'Keep it brief, code when needed', { status: 'conflicted', conflictGroupId: 'c2', deviceId: LOCAL_DEVICE }),
    ]);
    render(<MemoryPage />);

    // The copy is this device's: this device's version comes first (same as iOS / Android)
    expect(groupContents('groupConflicts')).toEqual(['Keep it brief', 'Keep it brief, code when needed']);
    expect(within(rowOf('Keep it brief')).getByText('conflictThisDevice')).toBeTruthy();
    const other = rowOf('Keep it brief, code when needed');
    expect(within(other).getByText('conflictOtherDevice')).toBeTruthy();

    fireEvent.click(within(other).getByRole('button', { name: 'conflictKeep' }));

    await waitFor(() => expect(stored('c2')?.status).toBe('active'));
    expect(stored('c2')?.conflictGroupId).toBeNull();
    expect(stored('c1')?.status).toBe('deleted');
    await waitFor(() => expect(screen.queryByRole('heading', { level: 3, name: 'groupConflicts' })).toBeNull());
    expect(groupContents('groupPreferences')).toEqual(['Keep it brief, code when needed']);
  });

  it('conflict_label_by_copy_device', async () => {
    // The copy comes from another device: the original item (this device's deviceId, only because this device pushed it as an edit) is "this device's version"
    seed([
      item('c3', 'preference', 'Remote wording', { status: 'conflicted', conflictGroupId: 'c4', deviceId: 'device-remote' }),
      item('c4', 'preference', 'My wording', { status: 'conflicted', conflictGroupId: 'c4', deviceId: 'device-remote' }),
    ]);
    render(<MemoryPage />);
    // The original item is this device's: it comes later in list order but is still placed first
    expect(groupContents('groupConflicts')).toEqual(['My wording', 'Remote wording']);
    expect(within(rowOf('My wording')).getByText('conflictThisDevice')).toBeTruthy();
    expect(within(rowOf('Remote wording')).getByText('conflictOtherDevice')).toBeTruthy();
  });

  it('hides_superseded_and_expired', async () => {
    seed([
      item('s1', 'preference', 'Superseded one', { status: 'superseded' }),
      item('s2', 'preference', 'Expired one', { status: 'expired' }),
      item('s3', 'preference', 'Live one'),
    ]);
    render(<MemoryPage />);
    await waitFor(() => expect(groupContents('groupPreferences')).toEqual(['Live one']));
  });

  it('edit_query_opens_item', async () => {
    seed([item('a1', 'identity', 'I write historical novels'), item('i1', 'instruction', 'Always answer in Arabic')]);
    window.history.replaceState(null, '', '/settings/memory?edit=i1');
    render(<MemoryPage />);

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'editorTitleEdit' })).toBeTruthy();
    expect((within(dialog).getByRole('textbox') as HTMLTextAreaElement).value).toBe('Always answer in Arabic');
    expect(within(dialog).getByRole('radio', { name: 'groupInstructions' }).getAttribute('aria-checked')).toBe('true');
  });
  it('episodic_group_filters_and_sorts', () => {
    appStore.setState({ folders: [{ id: 'f1', name: 'Thesis' }] });
    seed([
      item('a1', 'identity', 'I write historical novels'),
      item('j1', 'decision', 'Semantic decision stays in projects'),
      item('e1', 'decision', 'Chose Postgres', { layer: 'episodic', occurredAt: '2026-10-05T00:00:00Z' }),
      item('e2', 'event', 'Moved to Cairo', { layer: 'episodic', occurredAt: '2026-10-09T00:00:00Z', status: 'paused' }),
      item('e3', 'event', 'Started the draft', {
        layer: 'episodic', occurredAt: null, createdAt: '2026-10-07T08:00:00Z', scope: { type: 'folder', id: 'f1' },
      }),
      item('e4', 'event', 'Unknown folder trip', {
        layer: 'episodic', occurredAt: '2026-10-01T00:00:00Z', scope: { type: 'folder', id: 'gone' },
      }),
      item('e5', 'decision', 'Per chat call', {
        layer: 'episodic', occurredAt: '2026-10-02T00:00:00Z', scope: { type: 'conversation', id: 'conv-1' },
      }),
      item('e6', 'event', 'Old superseded event', { layer: 'episodic', occurredAt: '2026-10-08T00:00:00Z', status: 'superseded' }),
    ]);
    render(<MemoryPage />);

    // The L2 group has no episodic; the new group comes after the four groups
    expect(groupTitles()).toEqual(['groupAbout', 'groupProjects', 'groupEpisodic']);
    expect(groupContents('groupProjects')).toEqual(['Semantic decision stays in projects']);
    // occurredAt (createdAt if absent) newest to oldest; superseded is not shown
    expect(groupContents('groupEpisodic')).toEqual([
      'Moved to Cairo', 'Started the draft', 'Chose Postgres', 'Per chat call', 'Unknown folder trip',
    ]);
    const section = screen.getByRole('heading', { level: 3, name: 'groupEpisodic' }).closest('section') as HTMLElement;
    // The date is in the left date column and the second row keeps only the scope tag; assert "date · scope" paired by row
    const dates = within(section).getAllByTestId('memory-item-date').map((el) => el.getAttribute('datetime'));
    const scopes = within(section).getAllByTestId('memory-item-scope').map((el) => el.textContent);
    expect(dates.map((date, index) => `${date} · ${scopes[index]}`)).toEqual([
      '2026-10-09 · scopeAll',
      '2026-10-07 · scopeFolderNamed:{"name":"Thesis"}',
      '2026-10-05 · scopeAll',
      '2026-10-02 · scopeConversation',
      '2026-10-01 · scopeFolder',
    ]);
    expect(within(rowOf('Moved to Cairo')).getByText('itemPausedBadge')).toBeTruthy();
    expect(within(rowOf('Chose Postgres')).queryByText('itemPausedBadge')).toBeNull();
    expect(within(section).getByText('episodicLocalOnly')).toBeTruthy();
  });

  it('episodic_group_collapses_after_20', () => {
    const events = (count: number) => Array.from({ length: count }, (_, index) => item(
      `e${String(index).padStart(2, '0')}`,
      'event',
      `Event ${index}`,
      { layer: 'episodic', occurredAt: `2026-09-${String(index + 1).padStart(2, '0')}T00:00:00Z` },
    ));
    seed(events(20));
    const twenty = render(<MemoryPage />);
    expect(groupContents('groupEpisodic')).toHaveLength(20);
    expect(screen.queryByRole('button', { name: /^showAll/ })).toBeNull();
    twenty.unmount();

    seed(events(21));
    render(<MemoryPage />);
    const shown = groupContents('groupEpisodic');
    expect(shown).toHaveLength(20);
    expect(shown[0]).toBe('Event 20');
    expect(shown).not.toContain('Event 0');
    fireEvent.click(screen.getByRole('button', { name: 'showAll:{"count":21}' }));
    expect(groupContents('groupEpisodic')).toHaveLength(21);
    expect(groupContents('groupEpisodic')[20]).toBe('Event 0');
    expect(screen.queryByRole('button', { name: /^showAll/ })).toBeNull();
  });

  it('l3_conflict_pair_actions', async () => {
    const conflicted = (id: string, content: string, occurredAt: string, group: string) => item(id, 'decision', content, {
      layer: 'episodic', status: 'conflicted', conflictGroupId: group, occurredAt,
    });
    seed([
      conflicted('n1', 'Use Postgres', '2026-10-06T00:00:00Z', 'o1'),
      conflicted('o1', 'Use MySQL', '2026-10-02T00:00:00Z', 'o1'),
      conflicted('o2', 'Fly on Monday', '2026-10-08T00:00:00Z', 'o2'),
      conflicted('n2', 'Fly on Friday', '2026-10-03T00:00:00Z', 'o2'),
      // Same day: the larger id is the newer one
      conflicted('x3a', 'Blue cover', '2026-10-04T00:00:00Z', 'x3a'),
      conflicted('x3b', 'Red cover', '2026-10-04T00:00:00Z', 'x3a'),
    ]);
    render(<MemoryPage />);

    expect(groupTitles()).toEqual(['groupConflicts', 'groupEpisodic']);
    expect(within(rowOf('Use Postgres')).getByText('conflictNewer · 2026-10-06')).toBeTruthy();
    expect(within(rowOf('Use MySQL')).getByText('conflictOlder · 2026-10-02')).toBeTruthy();
    expect(within(rowOf('Fly on Monday')).getByText('conflictNewer · 2026-10-08')).toBeTruthy();
    expect(within(rowOf('Red cover')).getByText('conflictNewer · 2026-10-04')).toBeTruthy();
    expect(within(rowOf('Blue cover')).getByText('conflictOlder · 2026-10-04')).toBeTruthy();

    // Keep the newer -> useNew
    fireEvent.click(within(rowOf('Use Postgres')).getByRole('button', { name: 'conflictKeep' }));
    await waitFor(() => expect(l3Calls).toEqual([['n1', 'o1', 'useNew']]));
    await waitFor(() => expect(stored('n1')?.status).toBe('active'));
    expect(stored('o1')?.status).not.toBe('conflicted');

    // Keep the older -> useOld (the newer one is o2, with the later occurredAt)
    fireEvent.click(within(rowOf('Fly on Friday')).getByRole('button', { name: 'conflictKeep' }));
    await waitFor(() => expect(l3Calls[1]).toEqual(['o2', 'n2', 'useOld']));

    // Keep both -> keepBoth
    const pair = rowOf('Red cover').closest('ul') as HTMLElement;
    fireEvent.click(within(pair).getByRole('button', { name: 'conflictKeepBoth' }));
    await waitFor(() => expect(l3Calls[2]).toEqual(['x3b', 'x3a', 'keepBoth']));
    await waitFor(() => expect(stored('x3a')?.status).toBe('active'));
    expect(stored('x3b')?.status).toBe('active');
  });

  it('episodic_group_shown_when_empty', () => {
    seed([item('a1', 'identity', 'I write historical novels')]);
    render(<MemoryPage />);

    expect(groupTitles()).toEqual(['groupAbout', 'groupEpisodic']);
    const section = screen.getByRole('heading', { level: 3, name: 'groupEpisodic' }).closest('section') as HTMLElement;
    expect(within(section).queryAllByTestId('memory-item-content')).toHaveLength(0);
    expect(within(section).getByText('episodicLocalOnly')).toBeTruthy();
    fireEvent.click(within(section).getByRole('button', { name: 'addItem' }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'editorTitleNew' })).toBeTruthy();
    expect(within(dialog).getAllByRole('radio').map((r) => r.textContent)).toEqual(['kindDecision', 'kindEvent']);
    expect(within(dialog).getByRole('radio', { name: 'kindDecision' }).getAttribute('aria-checked')).toBe('true');
    expect((within(dialog).getByLabelText('itemDate') as HTMLInputElement).value).toBe(todayDate());
  });

  it('editor_kind_options_by_layer', async () => {
    seed([
      item('p1', 'preference', 'Prefers short answers'),
      item('e1', 'event', 'Moved to Cairo', { layer: 'episodic', occurredAt: '2026-10-09T00:00:00Z' }),
    ]);
    render(<MemoryPage />);

    // L3 group header "+ Add": only decision / event, decision by default; the date defaults to today
    const section = screen.getByRole('heading', { level: 3, name: 'groupEpisodic' }).closest('section') as HTMLElement;
    fireEvent.click(within(section).getByRole('button', { name: 'addItem' }));
    let dialog = screen.getByRole('dialog');
    expect(within(dialog).getAllByRole('radio').map((r) => r.textContent)).toEqual(['kindDecision', 'kindEvent']);
    expect(within(dialog).getByRole('radio', { name: 'kindDecision' }).getAttribute('aria-checked')).toBe('true');
    const date = within(dialog).getByLabelText('itemDate') as HTMLInputElement;
    expect(date.value).toBe(todayDate());
    fireEvent.change(date, { target: { value: '2026-10-03' } });
    fireEvent.click(within(dialog).getByRole('radio', { name: 'kindEvent' }));
    fireEvent.change(within(dialog).getByRole('textbox'), { target: { value: 'Signed the lease' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'save' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    const created = [...rows.map.values()].map((r) => r.item).find((m) => m.content === 'Signed the lease');
    expect(created?.layer).toBe('episodic');
    expect(created?.kind).toBe('event');
    expect(created?.occurredAt).toBe('2026-10-03T00:00:00Z');

    // Edit L3: the date backfills occurredAt, change to decision
    fireEvent.click(within(openMenu('Moved to Cairo')).getByRole('menuitem', { name: 'actionEdit' }));
    dialog = screen.getByRole('dialog');
    expect(within(dialog).getByRole('radio', { name: 'kindEvent' }).getAttribute('aria-checked')).toBe('true');
    expect((within(dialog).getByLabelText('itemDate') as HTMLInputElement).value).toBe('2026-10-09');
    expect(within(dialog).queryByRole('radio', { name: 'groupAbout' })).toBeNull();
    fireEvent.click(within(dialog).getByRole('radio', { name: 'kindDecision' }));
    fireEvent.click(within(dialog).getByRole('button', { name: 'save' }));
    await waitFor(() => expect(stored('e1')?.kind).toBe('decision'));
    expect(stored('e1')?.layer).toBe('episodic');
    expect(stored('e1')?.occurredAt).toBe('2026-10-09T00:00:00Z');

    // Edit L2: four categories, no decision / event and no date
    fireEvent.click(within(openMenu('Prefers short answers')).getByRole('menuitem', { name: 'actionEdit' }));
    dialog = screen.getByRole('dialog');
    expect(within(dialog).getAllByRole('radio').map((r) => r.textContent)).toEqual([
      'groupAbout', 'groupPreferences', 'groupInstructions', 'groupProjects',
    ]);
    expect(within(dialog).queryByRole('radio', { name: 'kindDecision' })).toBeNull();
    expect(within(dialog).queryByLabelText('itemDate')).toBeNull();
  });
});
