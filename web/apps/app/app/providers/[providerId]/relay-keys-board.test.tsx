import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useStore, type StoreApi } from 'zustand';
import type { AIModel, Provider } from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import { createAppStore, type AppStore } from '../../../lib/core/store/app-store';
import { useState } from 'react';
import { RelayKeysPage } from './components/RelayKeysPage';
import {
  RELAY_KEY_NOTICE_TEXT,
  relayKeyInputSheet,
  relayKeyNotice,
  relayKeyNoticeView,
  relayKeyOpFetchedKeyID,
  relayKeysBoard,
} from './relay-keys-board';
import {
  beginRelayKeyOp,
  finishRelayKeyOp,
  initialRelayKeysPageState,
  relayKeyOpFetchingIDs,
  relayKeysPageFetchingIDs,
  type RelayKeysPageState,
} from './relay-keys-page-state';
import { applyRelayKeyOperation } from '../../../lib/core/relay-model-probe-ops';
import type { RelayKeyOp } from '@oriveo/shared/relay/relay-keys';
import enMessages from '../../../messages/en.json';
import zhHansMessages from '../../../messages/zh-Hans.json';

/**
 * Keys page: BOARD-KEYS-01 to 07. 01 / 02 assert the read model and rendering;
 * 03 to 07 write the real store through production applyRelayKeyOperation and then assert the store state.
 */

const mocks = vi.hoisted(() => ({
  store: null as unknown,
}));

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

vi.mock('../../../providers/StoreProvider', () => ({
  getVanillaStore: () => mocks.store,
}));

const KEY = 'sk-relay-secret-0123456789';
const SECOND = 'sk-second-secret-0123456789';
const THIRD = 'sk-third-secret-0123456789';

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...extra,
  };
}

function baseProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    customName: 'Relay 1',
    status: { kind: 'connected' },
    models: [model('m-a')],
    catalogModels: [model('m-a'), model('m-b')],
    apiKey: KEY,
    apiKeyPreview: formatApiKeyPreview(KEY),
    baseURLText: 'https://relay.example.com/v1',
    relayKind: 'openai_compatible',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    ...overrides,
  };
}

function threeKeyProvider(): Provider {
  return baseProvider({
    relayKeys: [
      { id: 'initial', apiKey: '', name: 'Main', status: { state: 'ok', httpStatus: 200 } },
      {
        id: 'k2',
        apiKey: SECOND,
        status: { state: 'invalid', httpStatus: 401, checkedAt: '2026-10-11T06:00:00.000Z' },
      },
      { id: 'k3', apiKey: THIRD, name: 'Spare' },
    ],
    models: [model('m-a', { relayKeyID: 'initial' }), model('m-b', { relayKeyID: 'k2', name: 'Model B' }), model('m-c', { relayKeyID: 'k2' })],
    catalogModels: [
      model('m-a', { relayListedByKeyIDs: ['initial'] }),
      model('m-b', { relayListedByKeyIDs: ['initial', 'k2'] }),
      model('m-c', { relayListedByKeyIDs: ['k2'] }),
    ],
  });
}

function seedStore(provider: Provider): StoreApi<AppStore> {
  const store = createAppStore();
  store.getState().addProvider(provider);
  mocks.store = store;
  return store;
}

function saved(store: StoreApi<AppStore>): Provider {
  return store.getState().providers.find((item) => item.id === 'relay-1')!;
}

const onReplaceImplicitKey = vi.fn();
const onBack = vi.fn();
const onOpenLibrary = vi.fn();

/** Mirrors RelayDetail: keys page state is held by the parent; `shown` false simulates leaving for the model library (keys page unmounted). */
function Harness({ store, shown = true }: { store: StoreApi<AppStore>; shown?: boolean }) {
  const provider = useStore(store, (state) => state.providers.find((item) => item.id === 'relay-1'));
  const [pageState, setPageState] = useState<RelayKeysPageState>(initialRelayKeysPageState);
  if (!provider || !shown) return null;
  return (
    <RelayKeysPage
      provider={provider}
      pageState={pageState}
      onPageStateChange={setPageState}
      backLabel="back"
      onBack={onBack}
      onReplaceImplicitKey={onReplaceImplicitKey}
      onOpenLibrary={onOpenLibrary}
      validateKey={() => ({ ok: true })}
      disabled={false}
    />
  );
}

function catalogResponse(ids: string[]) {
  return new Response(JSON.stringify({ object: 'list', data: ids.map((id) => ({ id, object: 'model' })) }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

/** Which key this catalog request carried: whether via the direct-connect header or the server proxy body, only look at which value appears in the request. */
function secretsIn(call: unknown[]): string[] {
  const [input, init] = call as [RequestInfo | URL, RequestInit | undefined];
  const headers = init?.headers ? [...new Headers(init.headers).values()] : [];
  const raw = [String(input instanceof Request ? input.url : input), ...headers, typeof init?.body === 'string' ? init.body : ''].join('\n');
  return [KEY, SECOND, THIRD, 'sk-rotated-0123456789'].filter((secret) => raw.includes(secret));
}

function openKey(name: string) {
  fireEvent.click(screen.getByRole('button', { name }));
  return screen.getByRole('dialog');
}

beforeEach(() => {
  mocks.store = null;
  onReplaceImplicitKey.mockReset();
  onBack.mockReset();
  onOpenLibrary.mockReset();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('BOARD-KEYS-01 row content and status words', () => {
  it('BOARD-KEYS-01 read model: name or mask, primary badge, mask, status word, catalog count, in-use model count, last status when not ok', () => {
    const board = relayKeysBoard(threeKeyProvider());
    expect(board).toMatchObject({
      host: 'relay.example.com',
      count: 3,
      implicit: false,
      showsPrimaryHint: true,
      canAdd: true,
      footnoteKeys: ['pages.relayDetail.keyAppliesNow', 'pages.relayDetail.keysFootnote'],
    });
    expect(board.rows.map(({ actions: _actions, usingModelIDs: _using, ...row }) => row)).toEqual([
      {
        id: 'initial',
        title: 'Main',
        primaryBadge: true,
        preview: formatApiKeyPreview(KEY),
        statusKey: 'pages.relayDetail.keyStatusOk',
        statusMark: 'dot',
        catalog: { key: 'pages.relayDetail.keyCatalogCount', values: { count: 2 } },
        catalogCount: 2,
        enabledUsing: { key: 'pages.relayDetail.keyEnabledUsing', values: { count: 1 } },
        deleteBlocked: true,
        panelNoteKey: 'pages.relayDetail.keyPrimaryNotDeletable',
      },
      {
        id: 'k2',
        title: formatApiKeyPreview(SECOND),
        primaryBadge: false,
        preview: formatApiKeyPreview(SECOND),
        statusKey: 'pages.relayDetail.keyStatusInvalid',
        statusMark: 'warning',
        catalog: { key: 'pages.relayDetail.keyCatalogCount', values: { count: 2 } },
        catalogCount: 2,
        enabledUsing: { key: 'pages.relayDetail.keyEnabledUsing', values: { count: 2 } },
        lastStatus: { httpStatus: 401, statusKey: 'pages.relayDetail.keyStatusInvalid', checkedAt: '2026-10-11T06:00:00.000Z' },
        deleteBlocked: false,
        panelNoteKey: null,
      },
      {
        id: 'k3',
        title: 'Spare',
        primaryBadge: false,
        preview: formatApiKeyPreview(THIRD),
        statusKey: null,
        statusMark: null,
        catalog: { key: 'pages.relayDetail.keyCatalogNone' },
        catalogCount: 0,
        enabledUsing: { key: 'pages.relayDetail.keyEnabledNone' },
        deleteBlocked: false,
        panelNoteKey: null,
      },
    ]);
    const statuses = (['denied', 'limited', 'failed'] as const).map((state) => relayKeysBoard(baseProvider({
      relayKeys: [{ id: 'initial', apiKey: '', status: { state } }, { id: 'k2', apiKey: SECOND }],
    })).rows[0]!.statusKey);
    expect(statuses).toEqual([
      'pages.relayDetail.keyStatusDenied',
      'pages.relayDetail.keyStatusLimited',
      'pages.relayDetail.keyStatusFailed',
    ]);
  });

  it('BOARD-KEYS-01 production component: title, subtitle host · N keys, primary hint, badge once, last-status row, footer, no plaintext leak', () => {
    const store = seedStore(threeKeyProvider());
    const { container } = render(<Harness store={store} />);

    expect(screen.getByRole('heading', { name: 'pages.relayDetail.keysTitle' })).toBeTruthy();
    expect(screen.getByText('relay.example.com · pages.relayDetail.keysCount({"count":3})')).toBeTruthy();
    expect(screen.getByText('pages.relayDetail.keysPrimaryHint')).toBeTruthy();
    expect(screen.getAllByText('pages.relayDetail.keyPrimaryBadge')).toHaveLength(1);
    const last = screen.getByText(/pages\.relayDetail\.keyLastStatus/);
    expect(last.textContent).toContain('"status":"401 pages.relayDetail.keyStatusInvalid"');
    expect(screen.getAllByText(/pages\.relayDetail\.keyLastStatus/)).toHaveLength(1);
    expect(screen.getByText('pages.relayDetail.keysFootnote')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'pages.relayDetail.keysAdd' })).toBeTruthy();
    for (const secret of [KEY, SECOND, THIRD]) expect(container.innerHTML).not.toContain(secret);
  });
});

describe('BOARD-KEYS-02 implicit single key', () => {
  it('BOARD-KEYS-02 one row, no name, no badge, no ordering; the only action is replace key, via the existing single-key change-Key path', () => {
    const provider = baseProvider();
    const board = relayKeysBoard(provider);
    expect(board).toMatchObject({ implicit: true, count: 1, showsPrimaryHint: false });
    expect(board.rows).toHaveLength(1);
    expect(board.rows[0]).toMatchObject({
      title: formatApiKeyPreview(KEY),
      primaryBadge: false,
      // When the catalog is non-empty the first panel item is View models (single key too).
      actions: ['viewModels', 'replace'],
      deleteBlocked: false,
    });

    const store = seedStore(provider);
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    render(<Harness store={store} />);
    expect(screen.queryByText('pages.relayDetail.keysPrimaryHint')).toBeNull();
    expect(screen.queryByText('pages.relayDetail.keyPrimaryBadge')).toBeNull();
    const panel = openKey(formatApiKeyPreview(KEY));
    const actions = within(panel).getAllByRole('button').map((button) => button.getAttribute('aria-label') ?? button.textContent);
    expect(actions).toEqual(['pages.relayDetail.keyActionViewModels({"count":2})', 'pages.relayDetail.keyReplace', 'common.cancel']);
    expect(within(panel).queryByText('pages.relayDetail.keyPrimaryNotDeletable')).toBeNull();

    fireEvent.click(within(panel).getByRole('button', { name: 'pages.relayDetail.keyReplace' }));
    expect(onReplaceImplicitKey).toHaveBeenCalledTimes(1);
    expect(saved(store).relayKeys).toBeUndefined();
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

describe('BOARD-KEYS-03 add', () => {
  it('BOARD-KEYS-03 name (optional) + key -> RK-2 add -> all keys re-fetch the catalog, the primary key also gets a status and listed entries', async () => {
    const store = seedStore(baseProvider());
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (...call) => (
      secretsIn(call).includes(SECOND) ? catalogResponse(['m-c']) : catalogResponse(['m-a', 'm-b'])
    ));
    render(<Harness store={store} />);

    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.keysAdd' }));
    const dialog = screen.getByRole('dialog');
    fireEvent.change(within(dialog).getByLabelText('pages.relaySetup.twoStep.keyName'), { target: { value: 'Backup' } });
    fireEvent.change(within(dialog).getByLabelText('pages.relayDetail.keyFieldApiKey'), { target: { value: SECOND } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.save' }));

    await waitFor(() => expect(saved(store).catalogModels.some((item) => item.id === 'm-c')).toBe(true));
    const provider = saved(store);
    expect(provider.relayKeys).toHaveLength(2);
    const added = provider.relayKeys![1]!;
    expect(added).toMatchObject({ name: 'Backup', apiKey: SECOND });
    expect(provider.apiKey).toBe(KEY);
    expect(fetchSpy).toHaveBeenCalledTimes(2);
    expect(fetchSpy.mock.calls.map((call) => secretsIn(call))).toEqual([[KEY], [SECOND]]);
    const listed = Object.fromEntries(provider.catalogModels.map((item) => [item.id, item.relayListedByKeyIDs]));
    expect(listed).toEqual({ 'm-a': ['initial'], 'm-b': ['initial'], 'm-c': [added.id] });
    expect(provider.relayKeys!.map((key) => key.status?.state ?? null)).toEqual(['ok', 'ok']);
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  });
});

describe('BOARD-KEYS-04 replace key', () => {
  it('BOARD-KEYS-04 RK-2 replaceSecret -> re-fetch only this key, model library is not cleared, this key\'s no-access marks are cleared', async () => {
    const provider = threeKeyProvider();
    const store = seedStore({
      ...provider,
      models: provider.models.map((item) => (item.id === 'm-b' ? { ...item, relayDeniedKeyID: 'k2' } : item)),
    });
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => catalogResponse(['m-c', 'm-d']));
    render(<Harness store={store} />);

    const panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getByRole('button', { name: 'pages.relayDetail.keyReplace' }));
    const dialog = screen.getByRole('dialog');
    fireEvent.change(within(dialog).getByLabelText('pages.relayDetail.keyFieldApiKey'), { target: { value: 'sk-rotated-0123456789' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.save' }));

    await waitFor(() => expect(saved(store).catalogModels.some((item) => item.id === 'm-d')).toBe(true));
    const next = saved(store);
    expect(next.relayKeys!.map((key) => key.id)).toEqual(['initial', 'k2', 'k3']);
    expect(next.relayKeys![1]!.apiKey).toBe('sk-rotated-0123456789');
    expect(next.apiKey).toBe(KEY);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(secretsIn(fetchSpy.mock.calls[0]!)).toEqual(['sk-rotated-0123456789']);
    // Catalog entries listed only by the primary key are still there (model library is not cleared).
    expect(next.catalogModels.find((item) => item.id === 'm-a')?.relayListedByKeyIDs).toEqual(['initial']);
    expect(next.models.find((item) => item.id === 'm-b')?.relayDeniedKeyID).toBeUndefined();
  });
});

describe('BOARD-KEYS-05 delete', () => {
  it('BOARD-KEYS-05 the primary key cannot be deleted and gives a hint; other keys confirm first, list the models in use and fall back to the primary key, RK-2 delete after confirming', async () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);

    const primaryPanel = openKey('Main');
    expect(within(primaryPanel).getByText('pages.relayDetail.keyPrimaryNotDeletable')).toBeTruthy();
    expect(within(primaryPanel).queryByRole('button', { name: 'common.delete' })).toBeNull();
    fireEvent.click(within(primaryPanel).getByRole('button', { name: 'common.cancel' }));

    // The consequences of deleting are explained in the "Actions for each key" card (BOARD-KEYS-10); the panel no longer repeats them per button.
    expect(within(screen.getByRole('region', { name: 'pages.relayDetail.keyActionsTitle' })).getByText('pages.relayDetail.keyDeleteHint')).toBeTruthy();
    const panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getByRole('button', { name: 'common.delete' }));
    const confirm = screen.getByRole('alertdialog');
    expect(within(confirm).getByText('pages.relayDetail.keyDeleteTitle')).toBeTruthy();
    expect(within(confirm).getByText('pages.relayDetail.keyDeleteMessage({"count":2,"primary":"Main"})')).toBeTruthy();
    // Show display names (model name, or id if none).
    expect(within(confirm).getAllByRole('listitem').map((item) => item.textContent)).toEqual(['Model B', 'm-c']);
    // Nothing is written before deletion.
    expect(saved(store).relayKeys).toHaveLength(3);

    fireEvent.click(within(confirm).getByRole('button', { name: 'common.delete' }));
    await waitFor(() => expect(saved(store).relayKeys!.map((key) => key.id)).toEqual(['initial', 'k3']));
    expect(saved(store).models.map((item) => [item.id, item.relayKeyID])).toEqual([
      ['m-a', 'initial'],
      ['m-b', 'initial'],
      ['m-c', 'initial'],
    ]);
  });

  it('BOARD-KEYS-05 when no model uses it the confirm dialog says No models use it', () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);
    const panel = openKey('Spare');
    fireEvent.click(within(panel).getByRole('button', { name: 'common.delete' }));
    expect(within(screen.getByRole('alertdialog')).getByText('pages.relayDetail.keyDeleteMessageNone')).toBeTruthy();
  });
});

describe('BOARD-KEYS-06 ordering', () => {
  it('BOARD-KEYS-06 the first key has no move up, the last has no move down; move up goes through RK-2 move, and the first key becomes the primary key', async () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);

    const first = openKey('Main');
    expect(within(first).queryByRole('button', { name: 'pages.relayDetail.keyMoveUp' })).toBeNull();
    expect(within(first).getByRole('button', { name: 'pages.relayDetail.keyMoveDown' })).toBeTruthy();
    fireEvent.click(within(first).getByRole('button', { name: 'common.cancel' }));
    const last = openKey('Spare');
    expect(within(last).getByRole('button', { name: 'pages.relayDetail.keyMoveUp' })).toBeTruthy();
    expect(within(last).queryByRole('button', { name: 'pages.relayDetail.keyMoveDown' })).toBeNull();
    fireEvent.click(within(last).getByRole('button', { name: 'common.cancel' }));

    const middle = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(middle).getByRole('button', { name: 'pages.relayDetail.keyMoveUp' }));
    await waitFor(() => expect(saved(store).relayKeys!.map((key) => key.id)).toEqual(['k2', 'initial', 'k3']));
    expect(saved(store).apiKey).toBe(SECOND);
    expect(relayKeysBoard(saved(store)).rows.map((row) => row.primaryBadge)).toEqual([true, false, false]);
  });
});

describe('BOARD-KEYS-07 rename', () => {
  it('BOARD-KEYS-07 with >=2 keys rename is allowed -> RK-2 rename, changes only the display name', async () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);

    expect(within(screen.getByRole('region', { name: 'pages.relayDetail.keyActionsTitle' })).getByText('pages.relayDetail.keyRenameHint')).toBeTruthy();
    const panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getByRole('button', { name: 'pages.providerDetail.renameProviderTitle' }));
    fireEvent.change(within(screen.getByRole('dialog')).getByLabelText('pages.relaySetup.twoStep.keyName'), { target: { value: 'Backup' } });
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'common.save' }));

    await waitFor(() => expect(saved(store).relayKeys![1]!.name).toBe('Backup'));
    expect(saved(store).relayKeys![1]!.apiKey).toBe(SECOND);
    expect(saved(store).models.find((item) => item.id === 'm-b')?.relayKeyID).toBe('k2');
  });
});

/* ── BOARD-KEYS-08 to 15 ── */

const BAD = 'sk-bad-secret-0123456789';
const GOOD = 'sk-good-secret-0123456789';

function unauthorized() {
  return new Response(JSON.stringify({ error: { message: 'invalid api key' } }), {
    status: 401,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Fake upstream: a catalog request carrying a bad Key gets 401, others get a catalog (a value registered in `catalogs` returns its own catalog, default m-a / m-b);
 * a value registered in `gate` is held until the test releases it.
 */
function fakeUpstream(gates: Map<string, Promise<void>> = new Map(), catalogs: Map<string, string[]> = new Map()) {
  return vi.spyOn(globalThis, 'fetch').mockImplementation(async (...call) => {
    const raw = (() => {
      const [input, init] = call as [RequestInfo | URL, RequestInit | undefined];
      const headers = init?.headers ? [...new Headers(init.headers).values()] : [];
      return [String(input instanceof Request ? input.url : input), ...headers, typeof init?.body === 'string' ? init.body : ''].join('\n');
    })();
    for (const [secret, gate] of gates) if (raw.includes(secret)) await gate;
    if (raw.includes(BAD)) return unauthorized();
    for (const [secret, ids] of catalogs) if (raw.includes(secret)) return catalogResponse(ids);
    return catalogResponse(['m-a', 'm-b']);
  });
}

function deferred() {
  let release: () => void = () => {};
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

describe('BOARD-KEYS-08 status mark and primary badge', () => {
  it('BOARD-KEYS-08 Active = dot, never detected draws nothing, the rest = warning; Primary only on the first key and only with >=2 keys', () => {
    const board = relayKeysBoard(threeKeyProvider());
    expect(board.rows.map((row) => row.statusMark)).toEqual(['dot', 'warning', null]);
    const others = (['denied', 'limited', 'failed'] as const).map((state) => relayKeysBoard(baseProvider({
      relayKeys: [{ id: 'initial', apiKey: '', status: { state } }, { id: 'k2', apiKey: SECOND }],
    })).rows[0]!.statusMark);
    expect(others).toEqual(['warning', 'warning', 'warning']);
    expect(board.rows.map((row) => row.primaryBadge)).toEqual([true, false, false]);
    expect(relayKeysBoard(baseProvider()).rows.map((row) => row.primaryBadge)).toEqual([false]);
  });

  it('BOARD-KEYS-08 production component: the matching mark is drawn before the status word', () => {
    const store = seedStore(threeKeyProvider());
    const { container } = render(<Harness store={store} />);
    const marks = [...container.querySelectorAll('[data-key-row] [data-status-mark]')].map((node) => node.getAttribute('data-status-mark'));
    expect(marks).toEqual(['dot', 'warning']);
  });
});

describe('RL2-KEYSTATUS-10 default status draws no status word or mark; a single key is judged as <2 keys', () => {
  it('RL2-KEYSTATUS-10 never detected: the read model has no status word or mark; the production component draws no mark and no status text for that row (including accessibility)', () => {
    const board = relayKeysBoard(threeKeyProvider());
    expect(board.rows[2]).toMatchObject({ statusKey: null, statusMark: null });
    const implicit = relayKeysBoard(baseProvider());
    expect(implicit.rows[0]).toMatchObject({ statusKey: null, statusMark: null });

    const store = seedStore(threeKeyProvider());
    const { container } = render(<Harness store={store} />);
    const spare = container.querySelector('[data-key-row="k3"]')!;
    expect(spare.querySelector('[data-status-mark]')).toBeNull();
    expect(spare.querySelector('[data-row-status]')).toBeNull();
    expect(spare.textContent).not.toContain('keyStatus');
    expect(container.innerHTML).not.toContain('keyStatusUnchecked');
  });

  it('RL2-KEYSTATUS-10 an unrecognized decoded status value -> treated as default, no word and no mark', () => {
    const board = relayKeysBoard(baseProvider({
      relayKeys: [
        { id: 'initial', apiKey: '', status: { state: 'mystery' as never } },
        { id: 'k2', apiKey: SECOND, status: { state: 'ok' } },
      ],
    }));
    expect(board.rows[0]).toMatchObject({ statusKey: null, statusMark: null });
  });

  it('RL2-KEYSTATUS-10 single-entry list ok -> normal word and dot; still judged as a single key (implicit) with only replace key', () => {
    const board = relayKeysBoard(baseProvider({
      relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: '2026-10-13T00:00:00.000Z' } }],
    }));
    expect(board).toMatchObject({ implicit: true, count: 1, showsPrimaryHint: false });
    expect(board.rows[0]).toMatchObject({
      statusKey: 'pages.relayDetail.keyStatusOk',
      statusMark: 'dot',
      primaryBadge: false,
      actions: ['viewModels', 'replace'],
    });
  });
});

describe('BOARD-KEYS-09 Add key is the last row in the card', () => {
  it('BOARD-KEYS-09 the last listItems entry is add, row identifiers are not duplicated; not shown when no credentials are needed', () => {
    const board = relayKeysBoard(threeKeyProvider());
    expect(board.listItems.map((item) => item.kind)).toEqual(['key', 'key', 'key', 'add']);
    expect(new Set(board.listItems.map((item) => item.id)).size).toBe(board.listItems.length);
    const none = relayKeysBoard(baseProvider({ relayRequested: { transport: 'openai_chat_completions', authMode: 'none' } }));
    expect(none.listItems.map((item) => item.kind)).toEqual(['key']);
  });

  it('BOARD-KEYS-09 production component: Add key is the last row of the keys card', () => {
    const store = seedStore(threeKeyProvider());
    const { container } = render(<Harness store={store} />);
    const card = container.querySelector('[data-keys-card]')!;
    const last = card.lastElementChild!;
    expect(last.getAttribute('data-key-row')).toBe('add');
    expect(last.textContent).toContain('pages.relayDetail.keysAdd');
  });

  it('BOARD-KEYS-09 two footer sentences: first "Changes apply right away." (no save button on this page), then the status source', () => {
    expect(relayKeysBoard(threeKeyProvider()).footnoteKeys)
      .toEqual(['pages.relayDetail.keyAppliesNow', 'pages.relayDetail.keysFootnote']);
    const store = seedStore(threeKeyProvider());
    const { container } = render(<Harness store={store} />);
    expect([...container.querySelectorAll('[data-keys-footnote]')].map((node) => node.textContent))
      .toEqual(['pages.relayDetail.keyAppliesNow', 'pages.relayDetail.keysFootnote']);
  });
});

describe('BOARD-KEYS-10 actions and consequence notes', () => {
  it('BOARD-KEYS-10 primary / middle / last key actions, primary-key panel note; with >=2 keys the note card shows three items, a single key shows none', () => {
    const board = relayKeysBoard(threeKeyProvider());
    expect(board.rows.map((row) => row.actions)).toEqual([
      ['viewModels', 'rename', 'replace', 'moveDown'],
      ['viewModels', 'rename', 'replace', 'moveUp', 'moveDown', 'delete'],
      ['rename', 'replace', 'moveUp', 'delete'],
    ]);
    expect(board.rows.map((row) => row.panelNoteKey)).toEqual([
      'pages.relayDetail.keyPrimaryNotDeletable',
      null,
      null,
    ]);
    expect(board.actionNotes).toEqual([
      { action: 'rename', noteKey: 'pages.relayDetail.keyRenameHint' },
      { action: 'replace', noteKey: 'pages.relayDetail.keyReplaceHint' },
      { action: 'delete', noteKey: 'pages.relayDetail.keyDeleteHint' },
    ]);
    expect(relayKeysBoard(baseProvider()).actionNotes).toEqual([]);
  });

  it('BOARD-KEYS-10 production component: note card title and three items; the panel no longer repeats the note per button', () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);
    const notes = screen.getByRole('region', { name: 'pages.relayDetail.keyActionsTitle' });
    expect(within(notes).getByText('pages.relayDetail.keyRenameHint')).toBeTruthy();
    expect(within(notes).getByText('pages.relayDetail.keyReplaceHint')).toBeTruthy();
    expect(within(notes).getByText('pages.relayDetail.keyDeleteHint')).toBeTruthy();
    const panel = openKey(formatApiKeyPreview(SECOND));
    expect(within(panel).queryByText('pages.relayDetail.keyRenameHint')).toBeNull();
    expect(within(panel).queryByText('pages.relayDetail.keyDeleteHint')).toBeNull();
  });

  it('BOARD-KEYS-10 a single key shows no note card', () => {
    const store = seedStore(baseProvider());
    render(<Harness store={store} />);
    expect(screen.queryByRole('region', { name: 'pages.relayDetail.keyActionsTitle' })).toBeNull();
  });
});

describe('BOARD-KEYS-11 the row being fetched', () => {
  it('BOARD-KEYS-11 the in-flight key shows progress + Loading model list..., no last status code; other rows unchanged; only add / replaceSecret fetch the catalog', () => {
    const provider = threeKeyProvider();
    const idle = relayKeysBoard(provider);
    const busy = relayKeysBoard(provider, new Set(['k2']));
    expect(busy.rows[1]).toMatchObject({ statusMark: 'progress', statusKey: 'pages.relayDetail.keyStatusLoading' });
    expect(busy.rows[1]!.lastStatus).toBeUndefined();
    expect([busy.rows[0], busy.rows[2]]).toEqual([idle.rows[0], idle.rows[2]]);
    const ops: RelayKeyOp[] = [
      { type: 'add', id: 'k9', apiKey: GOOD },
      { type: 'replaceSecret', id: 'k2', apiKey: GOOD },
      { type: 'rename', id: 'k2', name: 'x' },
      { type: 'move', id: 'k2', toIndex: 0 },
      { type: 'delete', id: 'k2' },
    ];
    expect(ops.map(relayKeyOpFetchedKeyID)).toEqual(['k9', 'k2', null, null, null]);
  });
});

describe('BOARD-KEYS-12 replacing with a bad Key / good Key / rename / rejected (production path + fake upstream)', () => {
  it('BOARD-KEYS-12 a bad Key is stored as is and that row is invalid + 401 -> fetchFailed; a good Key returns to Active with no hint; rename has no hint; rejected gives rejected', async () => {
    const store = seedStore(threeKeyProvider());
    fakeUpstream();
    const apply = async (op: RelayKeyOp) => {
      const accepted = await applyRelayKeyOperation(store, saved(store), op);
      return { accepted, notice: relayKeyNotice(saved(store), op, accepted) };
    };

    const bad = await apply({ type: 'replaceSecret', id: 'k2', apiKey: BAD });
    expect(bad).toEqual({ accepted: true, notice: 'fetchFailed' });
    const badRow = relayKeysBoard(saved(store)).rows[1]!;
    expect(badRow).toMatchObject({
      preview: formatApiKeyPreview(BAD),
      statusMark: 'warning',
      statusKey: 'pages.relayDetail.keyStatusInvalid',
      lastStatus: { httpStatus: 401 },
    });
    expect(RELAY_KEY_NOTICE_TEXT.fetchFailed).toBe('pages.relayDetail.keyNoticeFetchFailed');

    const good = await apply({ type: 'replaceSecret', id: 'k2', apiKey: GOOD });
    expect(good).toEqual({ accepted: true, notice: null });
    expect(relayKeysBoard(saved(store)).rows[1]).toMatchObject({ statusMark: 'dot', statusKey: 'pages.relayDetail.keyStatusOk' });

    expect(await apply({ type: 'rename', id: 'k2', name: 'Renamed' })).toEqual({ accepted: true, notice: null });
    expect(await apply({ type: 'replaceSecret', id: 'missing', apiKey: GOOD })).toEqual({ accepted: false, notice: 'rejected' });
    expect(RELAY_KEY_NOTICE_TEXT.rejected).toBe('pages.relayDetail.keyNoticeRejected');
  });

  it('BOARD-KEYS-12 replacing with a good Key in an explicit list of one key: back to Active, no hint; replacing with a bad Key gives fetchFailed (a single-key refresh also persists status)', async () => {
    const store = seedStore(baseProvider({ relayKeys: [{ id: 'initial', apiKey: '' }] }));
    fakeUpstream();
    const apply = async (op: RelayKeyOp) => {
      const accepted = await applyRelayKeyOperation(store, saved(store), op);
      return relayKeyNotice(saved(store), op, accepted);
    };

    expect(await apply({ type: 'replaceSecret', id: 'initial', apiKey: GOOD })).toBeNull();
    expect(relayKeysBoard(saved(store)).rows[0]).toMatchObject({ statusMark: 'dot', statusKey: 'pages.relayDetail.keyStatusOk' });
    expect(saved(store).relayKeys![0]!.status?.state).toBe('ok');

    expect(await apply({ type: 'replaceSecret', id: 'initial', apiKey: BAD })).toBe('fetchFailed');
    expect(saved(store).apiKey).toBe(BAD);
    expect(relayKeysBoard(saved(store)).rows[0]).toMatchObject({
      statusMark: 'warning',
      statusKey: 'pages.relayDetail.keyStatusInvalid',
      lastStatus: { httpStatus: 401 },
    });
  });

  it('BOARD-KEYS-12 criterion: fetched key has empty status -> fetchInterrupted; that key no longer exists -> none', () => {
    const provider = threeKeyProvider();
    expect(relayKeyNotice(provider, { type: 'replaceSecret', id: 'k3', apiKey: GOOD }, true)).toBe('fetchInterrupted');
    expect(relayKeyNotice(provider, { type: 'add', id: 'gone', apiKey: GOOD }, true)).toBeNull();
    expect(RELAY_KEY_NOTICE_TEXT.fetchInterrupted).toBe('pages.relayDetail.keyNoticeFetchInterrupted');
  });

  it('BOARD-KEYS-12 production component: replacing with a bad Key in the UI -> that row warns + the page shows fetchFailed', async () => {
    const store = seedStore(threeKeyProvider());
    fakeUpstream();
    const { container } = render(<Harness store={store} />);
    const panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getByRole('button', { name: 'pages.relayDetail.keyReplace' }));
    const dialog = screen.getByRole('dialog');
    fireEvent.change(within(dialog).getByLabelText('pages.relayDetail.keyFieldApiKey'), { target: { value: BAD } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.save' }));

    await screen.findByText('pages.relayDetail.keyNoticeFetchFailed');
    expect(container.querySelector('[data-key-row="k2"] [data-status-mark]')?.getAttribute('data-status-mark')).toBe('warning');
  });
});

/** The field title is drawn as a visible <label> and is the input's accessible name (not just an aria-label). */
function expectVisibleLabel(dialog: HTMLElement, titleKey: string): HTMLInputElement {
  const label = within(dialog).getByText(titleKey);
  expect(label.tagName).toBe('LABEL');
  const input = within(dialog).getByLabelText(titleKey) as HTMLInputElement;
  expect(input.getAttribute('aria-label')).toBeNull();
  expect(label.getAttribute('for')).toBe(input.id);
  return input;
}

describe('BOARD-KEYS-13 three input dialogs', () => {
  it('BOARD-KEYS-13 title, field, placeholder and note of add / replace / rename', () => {
    const row = relayKeysBoard(threeKeyProvider()).rows[1]!;
    const add = relayKeyInputSheet('add');
    const replace = relayKeyInputSheet('replace', row);
    const rename = relayKeyInputSheet('rename', row);
    expect(add.titleKey).toBe('pages.relayDetail.keysAdd');
    expect(add.fields.map((field) => field.titleKey)).toEqual(['pages.relaySetup.twoStep.keyName', 'pages.relayDetail.keyFieldApiKey']);
    expect(add.noteKey).toBeNull();
    expect(replace.titleKey).toBe('pages.relayDetail.keyReplace');
    expect(replace.fields.map((field) => field.id)).toEqual(['secret']);
    expect(replace.noteKey).toBe('pages.relayDetail.keyReplaceHint');
    expect(rename.titleKey).toBe('pages.providerDetail.renameProviderTitle');
    expect(rename.fields.map((field) => field.id)).toEqual(['name']);
    // Same as iOS: the rename field title is exactly the "Name (optional)" string.
    expect(rename.fields[0]!.titleKey).toBe('pages.relaySetup.twoStep.keyName');
    expect(rename.fields[0]!.placeholder).toEqual({ literal: row.preview });
    expect(rename.noteKey).toBe('pages.relayDetail.keyRenameHint');
    for (const sheet of [add, replace, rename]) {
      for (const field of sheet.fields) {
        expect(field.titleKey).not.toBe(sheet.titleKey);
        if (field.placeholder && 'key' in field.placeholder) expect(field.placeholder.key).not.toBe(field.titleKey);
      }
    }
  });

  it('BOARD-KEYS-13 production component: replace-key dialog title Replace key, field placeholder differs from the field title; rename placeholder = mask', () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);
    let panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getByRole('button', { name: 'pages.relayDetail.keyReplace' }));
    let dialog = screen.getByRole('dialog', { name: 'pages.relayDetail.keyReplace' });
    const secret = within(dialog).getByLabelText('pages.relayDetail.keyFieldApiKey') as HTMLInputElement;
    expect(secret.placeholder).toBe('pages.relaySetup.apiKeyPlaceholder');
    expect(within(dialog).getByText('pages.relayDetail.keyReplaceHint')).toBeTruthy();
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.close' }));

    panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getByRole('button', { name: 'pages.providerDetail.renameProviderTitle' }));
    dialog = screen.getByRole('dialog', { name: 'pages.providerDetail.renameProviderTitle' });
    expect((within(dialog).getByLabelText('pages.relaySetup.twoStep.keyName') as HTMLInputElement).placeholder).toBe(formatApiKeyPreview(SECOND));
    expectVisibleLabel(dialog, 'pages.relaySetup.twoStep.keyName');
  });

  it('BOARD-KEYS-13 production component: all three dialogs have visible labels as field titles, associated with the input, placeholders per the model', () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);

    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.keysAdd' }));
    let dialog = screen.getByRole('dialog', { name: 'pages.relayDetail.keysAdd' });
    expect(expectVisibleLabel(dialog, 'pages.relaySetup.twoStep.keyName').placeholder).toBe('');
    expect(expectVisibleLabel(dialog, 'pages.relayDetail.keyFieldApiKey').placeholder).toBe('pages.relaySetup.apiKeyPlaceholder');
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.close' }));

    const panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getByRole('button', { name: 'pages.relayDetail.keyReplace' }));
    dialog = screen.getByRole('dialog', { name: 'pages.relayDetail.keyReplace' });
    expect(expectVisibleLabel(dialog, 'pages.relayDetail.keyFieldApiKey').placeholder).toBe('pages.relaySetup.apiKeyPlaceholder');
  });
});

describe('BOARD-KEYS-14 page state begin / finish (production path + fake upstream)', () => {
  it('BOARD-KEYS-14 a single success: fetching while in flight, no hint after completion; a single rejection: no residue, hint [rejected]', async () => {
    const store = seedStore(threeKeyProvider());
    const gate = deferred();
    fakeUpstream(new Map([[GOOD, gate.promise]]));
    const op: RelayKeyOp = { type: 'replaceSecret', id: 'k2', apiKey: GOOD };
    let state = beginRelayKeyOp(initialRelayKeysPageState, op);
    const pending = applyRelayKeyOperation(store, saved(store), op);
    expect([...relayKeysPageFetchingIDs(state)]).toEqual(['k2']);
    expect(relayKeysBoard(saved(store), relayKeysPageFetchingIDs(state)).rows[1]!.statusKey).toBe('pages.relayDetail.keyStatusLoading');
    gate.release();
    state = finishRelayKeyOp(state, op, await pending, saved(store));
    expect(state).toEqual(initialRelayKeysPageState);

    const refused: RelayKeyOp = { type: 'replaceSecret', id: 'missing', apiKey: GOOD };
    state = beginRelayKeyOp(state, refused);
    state = finishRelayKeyOp(state, refused, await applyRelayKeyOperation(store, saved(store), refused), saved(store));
    expect(relayKeysPageFetchingIDs(state).size).toBe(0);
    expect(state.notices).toEqual(['rejected']);
  });

  it('BOARD-KEYS-14 two in-flight operations on the same key: begin withdraws the old hint, the one that finishes first neither removes the fetching state nor reports, and the last one reports on completion [fetchFailed]', async () => {
    const store = seedStore(threeKeyProvider());
    const gate = deferred();
    fakeUpstream(new Map([[GOOD, gate.promise]]));
    const first: RelayKeyOp = { type: 'replaceSecret', id: 'k2', apiKey: GOOD };
    const second: RelayKeyOp = { type: 'replaceSecret', id: 'k2', apiKey: BAD };
    let state: RelayKeysPageState = { ...initialRelayKeysPageState, notices: ['rejected'] };
    state = beginRelayKeyOp(state, first);
    expect(state.notices).toEqual([]);
    const firstRun = applyRelayKeyOperation(store, saved(store), first);
    state = beginRelayKeyOp(state, second);
    const secondAccepted = await applyRelayKeyOperation(store, saved(store), second);
    state = finishRelayKeyOp(state, second, secondAccepted, saved(store));
    expect([...relayKeysPageFetchingIDs(state)]).toEqual(['k2']);
    expect(state.notices).toEqual([]);

    gate.release();
    state = finishRelayKeyOp(state, first, await firstRun, saved(store));
    expect(relayKeysPageFetchingIDs(state).size).toBe(0);
    expect(state.notices).toEqual(['fetchFailed']);
    expect(relayKeysBoard(saved(store)).rows[1]!.statusKey).toBe('pages.relayDetail.keyStatusInvalid');
  });
});

describe('BOARD-KEYS-15 two keys interleaved (production path + fake upstream)', () => {
  it('BOARD-KEYS-15 adding a second key while the primary key is replacing: the single-key refresh is overridden (stale, discarded), the add\'s full re-fetch writes back both keys; hints follow completion order [fetchFailed]', async () => {
    // On Web, "overridden" comes from the stale criterion of the single-key refresh path: while in flight, the connection object in the store is replaced by another change (here, adding the second key)
    // -> discard the write-back; after adding a key everything is re-fetched, and the primary key's new value is written back by that re-fetch rather than left empty.
    const store = seedStore(baseProvider({ relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'ok', httpStatus: 200 } }] }));
    const gate = deferred();
    fakeUpstream(new Map([[GOOD, gate.promise]]));
    const first: RelayKeyOp = { type: 'replaceSecret', id: 'initial', apiKey: GOOD };
    const second: RelayKeyOp = { type: 'add', id: 'k2', apiKey: BAD };

    let state = beginRelayKeyOp(initialRelayKeysPageState, first);
    const firstRun = applyRelayKeyOperation(store, saved(store), first);
    state = beginRelayKeyOp(state, second);
    expect([...relayKeysPageFetchingIDs(state)].sort()).toEqual(['initial', 'k2']);
    // The add's re-fetch also fetches the primary key (the new value is held by the gate too): release the gate first, then wait for both sides to finish.
    const secondRun = applyRelayKeyOperation(store, saved(store), second);
    gate.release();
    state = finishRelayKeyOp(state, second, await secondRun, saved(store));
    const firstAccepted = await firstRun;
    expect(firstAccepted).toBe(true);
    state = finishRelayKeyOp(state, first, firstAccepted, saved(store));

    const provider = saved(store);
    expect(provider.apiKey).toBe(GOOD);
    expect(provider.relayKeys!.map((key) => [key.id, key.status?.state ?? null])).toEqual([
      ['initial', 'ok'],
      ['k2', 'invalid'],
    ]);
    expect(state.notices).toEqual(['fetchFailed']);
    expect(relayKeysPageFetchingIDs(state).size).toBe(0);

    // Same-sentence dedupe: the same outcome again is not appended twice.
    const again = finishRelayKeyOp(beginRelayKeyOp(state, second), second, true, provider);
    expect(finishRelayKeyOp({ ...again, notices: ['fetchFailed'] }, second, true, provider).notices).toEqual(['fetchFailed']);
  });
});

describe('Add-key full re-fetch: every fetched row shows fetching, and the outcome hint looks only at the newly added key', () => {
  it('during add, the primary key and the new key are both fetching; at the end the hint follows only the new key\'s status', () => {
    const provider = baseProvider({ relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'invalid', httpStatus: 401 } }] });
    const op: RelayKeyOp = { type: 'add', id: 'k2', apiKey: SECOND };
    const fetched = relayKeyOpFetchingIDs(op, provider);
    expect(fetched).toEqual(['initial', 'k2']);
    let state = beginRelayKeyOp(initialRelayKeysPageState, op, fetched);
    expect([...relayKeysPageFetchingIDs(state)]).toEqual(['initial', 'k2']);
    const board = relayKeysBoard({ ...provider, relayKeys: [...provider.relayKeys!, { id: 'k2', apiKey: SECOND }] }, relayKeysPageFetchingIDs(state));
    expect(board.rows.map((row) => row.statusMark)).toEqual(['progress', 'progress']);

    // Primary key still invalid, new key fine: no hint (only the new key counts).
    const after = { ...provider, relayKeys: [provider.relayKeys![0]!, { id: 'k2', apiKey: SECOND, status: { state: 'ok' as const } }] };
    state = finishRelayKeyOp(state, op, true, after, fetched);
    expect(relayKeysPageFetchingIDs(state).size).toBe(0);
    expect(state.notices).toEqual([]);
  });
});

/* ── Keys panel entry and add-success hint (BOARD-KEYS-16 to 18) ── */

const VIEW_MODELS = 'pages.relayDetail.keyActionViewModels';

describe('BOARD-KEYS-16 panel viewModels', () => {
  it('BOARD-KEYS-16 panel viewModels comes first / not shown for an empty catalog / present for a single key too', () => {
    const board = relayKeysBoard(threeKeyProvider());
    // initial lists m-a, m-b; k2 lists m-b, m-c; k3 has 0 catalog entries.
    expect(board.rows.map((row) => row.catalogCount)).toEqual([2, 2, 0]);
    expect(board.rows.map((row) => row.actions[0])).toEqual(['viewModels', 'viewModels', 'rename']);
    expect(board.rows[2]!.actions).not.toContain('viewModels');

    const single = relayKeysBoard(baseProvider());
    expect(single.implicit).toBe(true);
    expect(single.rows[0]!.actions).toEqual(['viewModels', 'replace']);
    expect(relayKeysBoard(baseProvider({ catalogModels: [] })).rows[0]!.actions).toEqual(['replace']);
  });

  it('BOARD-KEYS-16 production component: the first panel item is View models (N); the key with 0 catalog entries has none in its panel', () => {
    const store = seedStore(threeKeyProvider());
    render(<Harness store={store} />);
    const panel = openKey(formatApiKeyPreview(SECOND));
    const first = within(panel).getAllByRole('button')[0]!;
    expect(first.textContent).toBe(`${VIEW_MODELS}({"count":2})`);
    fireEvent.click(within(panel).getByRole('button', { name: 'common.cancel' }));
    const spare = openKey('Spare');
    expect(within(spare).queryByText(new RegExp(VIEW_MODELS.replace(/\./g, '\\.')))).toBeNull();
  });
});

describe('BOARD-KEYS-17 add-success hint (production path + fake upstream)', () => {
  it('BOARD-KEYS-17 the add-success hint added(N,M) is mutually exclusive with the warning; replace success has no hint; page state dedupes the same sentence', async () => {
    const store = seedStore(baseProvider({ relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'ok', httpStatus: 200 } }] }));
    fakeUpstream(new Map(), new Map([[GOOD, ['m-a', 'm-x', 'm-y']], [SECOND, ['m-a']]]));
    const apply = async (op: RelayKeyOp) => {
      const accepted = await applyRelayKeyOperation(store, saved(store), op);
      return relayKeyNotice(saved(store), op, accepted);
    };

    const added = await apply({ type: 'add', id: 'k2', apiKey: GOOD });
    // N = this key's catalog count (same criterion as the count on the row); M = m-x, m-y listed only by it.
    expect(added).toEqual({ kind: 'added', keyID: 'k2', listed: 3, new: 2 });
    expect(relayKeysBoard(saved(store)).rows[1]!.catalogCount).toBe(3);
    expect(relayKeyNoticeView(added!)).toEqual({
      tone: 'success',
      parts: [
        { key: 'pages.relayDetail.keyNoticeAdded', values: { count: 3 } },
        { key: 'pages.relayDetail.keyNoticeAddedNew', values: { count: 2 } },
      ],
      link: { key: 'pages.relayDetail.keyNoticeViewModels', keyID: 'k2' },
    });

    const nothingNew = await apply({ type: 'add', id: 'k3', apiKey: SECOND });
    expect(nothingNew).toEqual({ kind: 'added', keyID: 'k3', listed: 1, new: 0 });
    expect(relayKeyNoticeView(nothingNew!).parts).toEqual([{ key: 'pages.relayDetail.keyNoticeAdded', values: { count: 1 } }]);

    // Mutually exclusive with the warning: the same notice function gives only one outcome.
    expect(await apply({ type: 'add', id: 'k4', apiKey: BAD })).toBe('fetchFailed');
    expect(relayKeyNoticeView('fetchFailed')).toEqual({
      tone: 'warning',
      parts: [{ key: 'pages.relayDetail.keyNoticeFetchFailed' }],
      link: null,
    });
    expect(await apply({ type: 'replaceSecret', id: 'k3', apiKey: THIRD })).toBeNull();

    // Page state: finish receives added, same-sentence dedupe.
    const op: RelayKeyOp = { type: 'add', id: 'k2', apiKey: GOOD };
    const once = finishRelayKeyOp(beginRelayKeyOp(initialRelayKeysPageState, op), op, true, saved(store));
    expect(once.notices).toEqual([{ kind: 'added', keyID: 'k2', listed: 3, new: 2 }]);
    const twice = finishRelayKeyOp(
      { ...beginRelayKeyOp(once, op), notices: [{ kind: 'added', keyID: 'k2', listed: 3, new: 2 }] },
      op,
      true,
      saved(store),
    );
    expect(twice.notices).toHaveLength(1);
  });

  it('BOARD-KEYS-17 criterion: add and ok but N == 0 -> no hint; empty status -> fetchInterrupted rather than added', () => {
    const op: RelayKeyOp = { type: 'add', id: 'k2', apiKey: SECOND };
    const base = baseProvider({ catalogModels: [model('m-a', { relayListedByKeyIDs: ['initial'] })] });
    const ok = { ...base, relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k2', apiKey: SECOND, status: { state: 'ok' as const } }] };
    expect(relayKeyNotice(ok, op, true)).toBeNull();
    const interrupted = { ...base, relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k2', apiKey: SECOND }] };
    expect(relayKeyNotice(interrupted, op, true)).toBe('fetchInterrupted');
  });
});

describe('BOARD-KEYS-18 opening the model library by key(id)', () => {
  it('BOARD-KEYS-18 both the panel item and the hint link open the model library by key(id)', async () => {
    const store = seedStore(threeKeyProvider());
    fakeUpstream(new Map(), new Map([[GOOD, ['m-a', 'm-x']]]));
    const { container } = render(<Harness store={store} />);

    const panel = openKey(formatApiKeyPreview(SECOND));
    fireEvent.click(within(panel).getAllByRole('button')[0]!);
    expect(onOpenLibrary).toHaveBeenLastCalledWith('k2');

    fireEvent.click(container.querySelector('[data-key-row="add"]')!);
    const dialog = screen.getByRole('dialog');
    fireEvent.change(within(dialog).getByLabelText('pages.relayDetail.keyFieldApiKey'), { target: { value: GOOD } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.save' }));

    const link = await screen.findByRole('button', { name: 'pages.relayDetail.keyNoticeViewModels' });
    const notice = link.closest('[data-key-notice]')!;
    expect(notice.getAttribute('data-key-notice')).toBe('added');
    expect(notice.getAttribute('data-tone')).toBe('success');
    expect(notice.textContent).toContain(
      'pages.relayDetail.keyNoticeAdded({"count":2}) · pages.relayDetail.keyNoticeAddedNew({"count":1})',
    );
    const newID = saved(store).relayKeys!.at(-1)!.id;
    fireEvent.click(link);
    expect(onOpenLibrary).toHaveBeenLastCalledWith(newID);
  });

  it('BOARD-KEYS-18 go to the model library and come back: the added hint is still there (page state is held by the parent, same as iOS / Android)', async () => {
    const store = seedStore(threeKeyProvider());
    fakeUpstream(new Map(), new Map([[GOOD, ['m-a', 'm-x']]]));
    const { container, rerender } = render(<Harness store={store} />);
    fireEvent.click(container.querySelector('[data-key-row="add"]')!);
    const dialog = screen.getByRole('dialog');
    fireEvent.change(within(dialog).getByLabelText('pages.relayDetail.keyFieldApiKey'), { target: { value: GOOD } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.save' }));
    fireEvent.click(await screen.findByRole('button', { name: 'pages.relayDetail.keyNoticeViewModels' }));

    rerender(<Harness store={store} shown={false} />);
    expect(container.querySelector('[data-key-notice]')).toBeNull();
    rerender(<Harness store={store} />);
    expect(container.querySelector('[data-key-notice]')?.getAttribute('data-key-notice')).toBe('added');
  });
});

/* ── Footer copy; the warning row and the success row are both inline hints without a backing plate (aligned with iOS noticeLine) ── */

describe('Keys footer and hint rows', () => {
  const css = readFileSync(join(import.meta.dirname, 'components', 'RelayDetailBoard.module.css'), 'utf8');
  /** Get the rule body of a selector (the first block with exactly that name). */
  const ruleOf = (selector: string) => {
    const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return css.match(new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`))?.[1] ?? '';
  };

  it('keys footer second sentence matches the agreed copy (en / zh-Hans verbatim), and no longer says no separate probe is sent', () => {
    expect(relayKeysBoard(threeKeyProvider()).footnoteKeys)
      .toEqual(['pages.relayDetail.keyAppliesNow', 'pages.relayDetail.keysFootnote']);
    expect(enMessages.pages.relayDetail.keysFootnote)
      .toBe('Key status comes from model list fetches and real requests, including capability tests.');
    expect(zhHansMessages.pages.relayDetail.keysFootnote).toBe('\u5bc6\u94a5\u72b6\u6001\u6765\u81ea\u62c9\u53d6\u76ee\u5f55\u548c\u771f\u5b9e\u8bf7\u6c42，\u5305\u62ec\u80fd\u529b\u6d4b\u8bd5。');
  });

  it('warning rows (fetchFailed / rejected / fetchInterrupted) are inline like the success row: the list always carries data-inline, and the warning row carries a warning icon', () => {
    const store = seedStore(threeKeyProvider());
    const provider = saved(store);
    const pageState: RelayKeysPageState = {
      ...initialRelayKeysPageState,
      notices: ['fetchFailed', { kind: 'added', keyID: 'k2', listed: 3, new: 1 }, 'rejected', 'fetchInterrupted'],
    };
    const { container } = render(
      <RelayKeysPage
        provider={provider}
        pageState={pageState}
        onPageStateChange={() => {}}
        backLabel="back"
        onBack={onBack}
        onReplaceImplicitKey={onReplaceImplicitKey}
        onOpenLibrary={onOpenLibrary}
        validateKey={() => ({ ok: true })}
        disabled={false}
      />,
    );
    const list = container.querySelector('[data-key-notice]')!.closest('ul')!;
    expect(list.getAttribute('data-inline')).toBe('true');
    const rows = [...container.querySelectorAll('[data-key-notice]')];
    expect(rows.map((row) => row.getAttribute('data-tone'))).toEqual(['warning', 'success', 'warning', 'warning']);
    for (const row of rows) expect(row.querySelector('svg')).toBeTruthy();
  });

  it('styles: hint rows always have no backing plate and no padding; a warning changes only the text color; when both appear the row gap = iOS VStack spacing sm (--o-space-sm)', () => {
    const base = ruleOf('.keyNotice');
    expect(base).toMatch(/padding:\s*0;/);
    expect(base).toMatch(/background:\s*none;/);
    expect(base).not.toMatch(/border-radius:\s*[1-9]/);
    expect(ruleOf('.keyNotices')).toMatch(/gap:\s*var\(--o-space-sm\);/);
    expect(ruleOf(".keyNotice[data-tone='warning']")).toMatch(/color:\s*var\(--o-warning-text\);/);
    expect(css).not.toMatch(/\.keyNotice[^{]*\{[^}]*var\(--o-warning-subtle\)/);
  });
});
